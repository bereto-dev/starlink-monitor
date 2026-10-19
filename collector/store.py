"""SQLite storage for the collector."""
import os
import sqlite3
import threading
import time

DEFAULT_PATH = os.path.expanduser(
    "~/Library/Application Support/StarlinkMonitor/data.db")

RAW_KEEP_S = 7 * 86400  # after 7 days, samples are rolled up to 1 min

SCHEMA = """
CREATE TABLE IF NOT EXISTS samples (
    ts INTEGER PRIMARY KEY,          -- Unix, seconds
    latency_ms REAL,
    drop_rate REAL,
    down_bps REAL,
    up_bps REAL
);
CREATE TABLE IF NOT EXISTS outages (
    start_ts REAL PRIMARY KEY,       -- Unix, seconds
    duration_s REAL,
    cause TEXT
);
CREATE TABLE IF NOT EXISTS speedtests (
    ts INTEGER PRIMARY KEY,
    down_mbps REAL,
    up_mbps REAL,
    rpm INTEGER
);
CREATE TABLE IF NOT EXISTS daily (
    date TEXT PRIMARY KEY,           -- YYYY-MM-DD, local time
    avg_latency REAL,
    p95_latency REAL,
    outage_s REAL,
    avg_down REAL,
    max_down REAL
);
CREATE TABLE IF NOT EXISTS meta (
    key TEXT PRIMARY KEY,
    value TEXT
);
"""

# range -> (seconds, bucket size in seconds)
RANGES = {
    "15m": (900, 1),
    "1h": (3600, 5),
    "24h": (86400, 60),
    "7d": (7 * 86400, 600),
}


class Store:
    def __init__(self, path=DEFAULT_PATH):
        d = os.path.dirname(path)
        if d:
            os.makedirs(d, exist_ok=True)
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.executescript(SCHEMA)
        self.lock = threading.Lock()

    # --- meta ---
    def get_meta(self, key, default=None):
        with self.lock:
            r = self.db.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
        return r[0] if r else default

    def set_meta(self, key, value):
        with self.lock, self.db:
            self.db.execute("INSERT OR REPLACE INTO meta VALUES (?,?)", (key, str(value)))

    # --- writes ---
    def add_samples(self, rows):
        """rows: [(ts, latency_ms, drop_rate, down_bps, up_bps)]"""
        if not rows:
            return
        with self.lock, self.db:
            self.db.executemany(
                "INSERT OR REPLACE INTO samples VALUES (?,?,?,?,?)", rows)

    def add_outages(self, outages):
        if not outages:
            return
        with self.lock, self.db:
            self.db.executemany(
                "INSERT OR IGNORE INTO outages VALUES (?,?,?)",
                [(round(o["start_ts"], 3), o["duration_s"], o["cause"]) for o in outages])

    def downsample_old(self, now=None):
        """Rolls up 1-s samples older than RAW_KEEP_S into 1-min rows."""
        cutoff = int((now or time.time()) - RAW_KEEP_S)
        cutoff -= cutoff % 60
        with self.lock, self.db:
            old = self.db.execute(
                "SELECT ts/60*60, AVG(latency_ms), AVG(drop_rate), AVG(down_bps), AVG(up_bps),"
                " COUNT(*) FROM samples WHERE ts < ? GROUP BY ts/60", (cutoff,)).fetchall()
            pending = [r[:5] for r in old if r[5] > 1]
            if not pending:
                return 0
            self.db.execute("DELETE FROM samples WHERE ts < ? AND ts % 60 != 0", (cutoff,))
            self.db.executemany("INSERT OR REPLACE INTO samples VALUES (?,?,?,?,?)", pending)
        return len(pending)

    # --- reads ---
    def history(self, range_key="15m", now=None):
        span, step = RANGES.get(range_key, RANGES["15m"])
        now = int(now or time.time())
        since = now - span
        with self.lock:
            rows = self.db.execute(
                "SELECT ts/?*?, AVG(latency_ms), AVG(drop_rate), AVG(down_bps), AVG(up_bps)"
                " FROM samples WHERE ts >= ? GROUP BY ts/? ORDER BY 1",
                (step, step, since, step)).fetchall()
        out = {"range": range_key if range_key in RANGES else "15m", "step_s": step,
               "since": since, "now": now,
               "t": [], "latency_ms": [], "drop_rate": [], "down_bps": [], "up_bps": []}
        for ts, lat, drop, down, up in rows:
            out["t"].append(ts)
            out["latency_ms"].append(_r(lat, 1))
            out["drop_rate"].append(_r(drop, 4))
            out["down_bps"].append(_r(down, 0))
            out["up_bps"].append(_r(up, 0))
        return out

    def outages(self, since, min_s=0.0):
        with self.lock:
            rows = self.db.execute(
                "SELECT start_ts, duration_s, cause FROM outages"
                " WHERE start_ts >= ? AND duration_s >= ? ORDER BY start_ts DESC",
                (since, min_s)).fetchall()
        items = [{"start_ts": r[0], "duration_s": round(r[1], 1), "cause": r[2]} for r in rows]
        return {"since": since, "min_s": min_s, "count": len(items),
                "total_s": round(sum(i["duration_s"] for i in items), 1), "items": items}

    def last_speedtest(self):
        with self.lock:
            r = self.db.execute(
                "SELECT ts, down_mbps, up_mbps, rpm FROM speedtests ORDER BY ts DESC LIMIT 1"
            ).fetchone()
        return {"ts": r[0], "down_mbps": r[1], "up_mbps": r[2], "rpm": r[3]} if r else None


def _r(v, n):
    if v is None:
        return None
    return round(v, n) if n else int(round(v))
