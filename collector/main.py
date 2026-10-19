"""Starlink collector: polls the dish and serves the API on :8766.

    python3 main.py [--port 8766] [--db PATH]
"""
import argparse
import collections
import math
import threading
import time

import starlink
from server import make_server
from store import DEFAULT_PATH, Store

STATUS_EVERY_S = 2
HISTORY_EVERY_S = 60
DOWNSAMPLE_EVERY_S = 3600

DOWN_AFTER_S = 5        # dish silent, or drop >= 0.5, for longer than this
DOWN_DROP = 0.5
DEGRADED_LATENCY_MS = 80
DEGRADED_DROP = 0.02
LATENCY_WINDOW_S = 30


def _clean(v):
    if isinstance(v, float) and (math.isnan(v) or math.isinf(v)):
        return None
    return v


class State:
    """Latest status in memory + state rules (ok / degraded / down)."""

    def __init__(self, store):
        self.store = store
        self.lock = threading.Lock()
        self.status = None
        self.last_ok_ts = None
        self.last_error = None
        self.bad_since = None      # start of the stretch with drop >= 0.5
        self.down_since = None     # start of the current outage (for the TV counter)
        self.window = collections.deque()  # (ts, latency_ms)
        self.started = time.time()

    def update(self, status, err=None):
        now = time.time()
        with self.lock:
            if err is not None:
                self.last_error = str(err)
            else:
                self.status = status
                self.last_ok_ts = now
                self.last_error = None
                if status["drop_rate"] >= DOWN_DROP:
                    if self.bad_since is None:
                        self.bad_since = now
                else:
                    self.bad_since = None
                if status["latency_ms"] is not None and status["drop_rate"] < DOWN_DROP:
                    self.window.append((now, status["latency_ms"]))
            while self.window and self.window[0][0] < now - LATENCY_WINDOW_S:
                self.window.popleft()

            state = self._state(now)
            if state == "down":
                if self.down_since is None:
                    # no pings since bad_since, or dish silent since the last good status
                    self.down_since = self.bad_since or self.last_ok_ts or self.started
            else:
                self.down_since = None

    def _state(self, now):
        ref = self.last_ok_ts or self.started
        if now - ref > DOWN_AFTER_S:
            return "down"
        if self.bad_since is not None and now - self.bad_since > DOWN_AFTER_S:
            return "down"
        s = self.status
        if s is None:
            return "down"
        avg = self.avg_latency()
        if (avg is not None and avg > DEGRADED_LATENCY_MS) or s["drop_rate"] > DEGRADED_DROP \
                or s["currently_obstructed"]:
            return "degraded"
        return "ok"

    def avg_latency(self):
        if not self.window:
            return None
        return sum(v for _, v in self.window) / len(self.window)

    def now(self):
        now = time.time()
        with self.lock:
            s = dict(self.status or {})
            state = self._state(now)
            out = {
                "ts": now,
                "state": state,
                "online": state != "down",
                "dish_reachable": self.last_ok_ts is not None and now - self.last_ok_ts <= DOWN_AFTER_S,
                "age_s": round(now - self.last_ok_ts, 1) if self.last_ok_ts else None,
                "down_since": self.down_since,
                "error": self.last_error,
                "latency_avg_30s_ms": self.avg_latency(),
            }
        for k in ("latency_ms", "drop_rate", "down_bps", "up_bps", "obstruction_fraction",
                  "currently_obstructed", "alerts", "uptime_s", "azimuth_deg", "elevation_deg",
                  "gps_sats", "device"):
            out[k] = s.get(k)
        out["last_speedtest"] = self.store.last_speedtest()
        return {k: _clean(v) for k, v in out.items()}


def status_loop(state, stop):
    while not stop.is_set():
        t0 = time.time()
        try:
            state.update(starlink.get_status())
        except Exception as e:
            state.update(None, e)
        stop.wait(max(0.1, STATUS_EVERY_S - (time.time() - t0)))


def ingest_history(store, h, fetch_ts):
    """Stores only the new ring-buffer samples, plus outages."""
    current = h["current"]
    last = int(store.get_meta("last_counter", -1))
    offset = store.get_meta("ts_offset")
    new_offset = int(round(fetch_ts)) - current  # ts(c) = c + offset
    # Dish reboot (counter went backwards) or clock drift: re-anchor.
    if offset is None or current < last or abs(int(offset) - new_offset) > 3:
        offset = new_offset
        if current < last:
            last = -1
    offset = int(offset)

    rows = []
    for s in h["samples"]:
        c = s["counter"]
        if c <= last:
            continue
        rows.append((c + offset + 1, _clean(s["latency_ms"]), _clean(s["drop_rate"]),
                     _clean(s["down_bps"]), _clean(s["up_bps"])))
    store.add_samples(rows)
    store.add_outages(h["outages"])
    store.set_meta("last_counter", current - 1)
    store.set_meta("ts_offset", offset)
    return len(rows)


def history_loop(store, stop):
    last_ds = 0
    while not stop.is_set():
        t0 = time.time()
        try:
            n = ingest_history(store, starlink.get_history(), t0)
            print(time.strftime("%H:%M:%S"), "history: +%d samples" % n, flush=True)
        except Exception as e:
            print(time.strftime("%H:%M:%S"), "history: error:", e, flush=True)
        if t0 - last_ds > DOWNSAMPLE_EVERY_S:
            try:
                store.downsample_old()
            except Exception as e:
                print("downsample: error:", e, flush=True)
            last_ds = t0
        stop.wait(max(1, HISTORY_EVERY_S - (time.time() - t0)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8766)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--db", default=DEFAULT_PATH)
    args = ap.parse_args()

    store = Store(args.db)
    state = State(store)
    stop = threading.Event()
    for target, a in ((status_loop, (state, stop)), (history_loop, (store, stop))):
        threading.Thread(target=target, args=a, daemon=True).start()

    srv = make_server(state, store, args.host, args.port)
    print("Collector on http://%s:%d  (dashboard: /sl-dashboard/)  db=%s" % (args.host, args.port, args.db), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        srv.server_close()


if __name__ == "__main__":
    main()
