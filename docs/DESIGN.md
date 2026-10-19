# Design notes

Technical reference for the dish API, the collector, the TV dashboard and the menu bar app.

```
 Starlink dish ──gRPC-web──▶  StarlinkBar (menu bar app)            standalone
 192.168.100.1:9201     │
                        └──▶  Collector (Python)  ──HTTP :8766──▶  TV dashboard / any browser
                              SQLite + JSON API              └──▶  StarlinkBar (collector mode)
```

The menu bar app reads the dish directly by default. The collector is optional: it keeps long-term history in SQLite and serves the TV dashboard.

---

## 1. Network

| Device | Address | Notes |
|---|---|---|
| Starlink dish | `192.168.100.1` | gRPC on `:9200`, **gRPC-web on `:9201`**, no auth. Same address on every Starlink install. |
| Starlink router | `192.168.1.1` (default) | gRPC on `:9000` |

The dish is reachable from any device on the Starlink network, including through a third-party router as long as it routes `192.168.100.0/24` to the Starlink WAN.

---

## 2. Dish API

### Transport: gRPC-web over HTTP/1.1

```bash
printf '\x00\x00\x00\x00\x03\xe2\x3e\x00' > req.bin    # Request{ get_status {} }
curl -s -X POST \
  -H 'Content-Type: application/grpc-web+proto' -H 'X-Grpc-Web: 1' \
  --data-binary @req.bin \
  http://192.168.100.1:9201/SpaceX.API.Device.Device/Handle -o status.bin
```

- **Request frame** = `0x00` + length (4 bytes big-endian) + protobuf `Request`.
- **Response frame** = same format, followed by a trailers frame (`grpc-status: 0`).
- Service `SpaceX.API.Device.Device`, single method `Handle`.

| Request | Field in `Request` | Frame bytes | Response (field) |
|---|---|---|---|
| `get_status` | 1004 | `00 00 00 00 03 E2 3E 00` | `dish_get_status` (2004) |
| `get_history` | 1007 | `00 00 00 00 03 FA 3E 00` | `dish_get_history` (2006) |

The dish also exposes **gRPC reflection** (`grpcurl -plaintext 192.168.100.1:9200 describe`), and the open-source `starlink-grpc-tools` project documents the full schema.

**Read-only:** the same API accepts commands (`reboot`, `dish_stow`, ...). This project never sends them; both clients refuse any request other than `get_status` and `get_history`.

### `get_status` → `DishGetStatusResponse`

| Field | Name | Use |
|---|---|---|
| 1 | `device_info` (1 id, 2 hardware, 3 software, 4 country) | Footer |
| 2.1 | `device_state.uptime_s` | "Dish up for…" |
| 1003 | `pop_ping_drop_rate` (absent = 0) | Packet loss |
| 1004 | `obstruction_stats` → 1 `fraction_obstructed`, 5 `currently_obstructed` | Obstruction |
| 1005 | `alerts` (bool fields; empty = no alerts) | Alerts |
| 1007 / 1008 | `downlink_throughput_bps` / `uplink_throughput_bps` | **Current usage**, not capacity |
| 1009 | `pop_ping_latency_ms` | Latency |
| 1011 / 1012 | `boresight_azimuth_deg` / `boresight_elevation_deg` | Orientation |
| 1015 | `gps_stats` → 1 valid, 2 satellites | GPS |
| 1016 | `eth_speed_mbps` | Ethernet link |

### `get_history` → `DishGetHistoryResponse` (ring buffer of 900 samples = 15 min at 1 Hz)

| Field | Content |
|---|---|
| 1 | `current`: total sample counter (index = `current % 900`; newest sample = `current - 1`) |
| 1001 | `pop_ping_drop_rate[900]` (packed float32) |
| 1002 | `pop_ping_latency_ms[900]` |
| 1003 / 1004 | `downlink_throughput_bps[900]` / `uplink_throughput_bps[900]` |
| 1009 | `outages[]`: 1 cause (enum), 2 start (GPS-time ns), 3 duration (ns) |
| 1010 | `power_in[900]` (watts) |

Outage start → Unix seconds: `ns / 1e9 + 315964800 - 18` (GPS epoch minus current leap seconds).

Field numbers can change with a firmware update; the mapping lives in one place per client (`collector/starlink.py`, `menubar/StarlinkBar/Sources/DishClient.swift`).

---

## 3. State rules

Shared by the collector, the TV dashboard and the menu bar app:

- `down`: the dish does not respond, or `drop_rate ≥ 0.5` for more than 5 s.
- `degraded`: 30 s average latency > 80 ms, or `drop_rate > 0.02`, or currently obstructed.
- `ok`: everything else.

---

## 4. Collector (`collector/`)

Python 3, standard library only.

| Every | What |
|---|---|
| 2 s | `get_status` → live values in memory |
| 60 s | `get_history` → new 1 Hz samples and outages into SQLite |
| 1 h | Roll up samples older than 7 days to 1-minute rows |

**SQLite** (`~/Library/Application Support/StarlinkMonitor/data.db`): `samples(ts, latency_ms, drop_rate, down_bps, up_bps)`, `outages(start_ts, duration_s, cause)`, `speedtests(...)`, `daily(...)` (the last two are reserved for future use).

**HTTP API on `0.0.0.0:8766`** (CORS `*`):

| Route | Returns |
|---|---|
| `GET /api/now` | `state`, `online`, `dish_reachable`, `down_since`, latency, drop, down/up, obstruction, alerts, uptime, device |
| `GET /api/history?range=15m\|1h\|24h\|7d` | Columns `t[]`, `latency_ms[]`, `drop_rate[]`, `down_bps[]`, `up_bps[]` (1 / 5 / 60 / 600 s buckets) |
| `GET /api/outages?since=<unix>&min_s=<s>` | `count`, `total_s`, `items[]` (default: since local midnight) |
| `GET /tv/` | TV dashboard |

**Running at login:** `collector/install-agent.sh` installs a launchd agent (`RunAtLoad` + `KeepAlive`). launchd jobs can't read `~/Desktop` or `~/Documents`, so the script copies `collector/` and `tv/` to `~/Library/Application Support/StarlinkMonitor/app/` and the agent runs that copy; re-run it after changing the code.

```bash
collector/install-agent.sh                                              # install / update + restart
collector/install-agent.sh --remove                                     # stop and remove (keeps data)
launchctl kickstart -k gui/$(id -u)/io.github.bereto-dev.starlinkmonitor  # restart only
tail -f ~/Library/Logs/StarlinkMonitor/collector.log                    # logs
```

The Mac must stay awake for the collector to keep recording.

---

## 5. TV dashboard (`tv/`)

Built for old smart-TV browsers:

- **Pure ES5**: `var`, `function`, `XMLHttpRequest`; no `let`, `const`, `fetch`, Promises, arrow functions or template strings.
- **CSS without variables**, `display: table`, no `grid` or `gap`; system fonts only.
- Charts drawn by hand on a 2D `<canvas>`.
- Designed at 1920×1080 and scaled to the screen; content shifts a few pixels every 10 minutes to avoid burn-in.
- Polls `/api/now` every 3 s, `/api/history?range=15m` and `/api/outages` every 60 s.
- **Outage mode:** full red screen with "NO INTERNET" and a running counter. A separate screen shows when the collector stops answering.

---

## 6. Menu bar app (`menubar/StarlinkBar/`)

SwiftUI `MenuBarExtra` (macOS 13+), no Dock icon (`LSUIElement`). Built with `swiftc` directly; no Xcode project.

- **Bar:** satellite icon colored by state, plus latency or download (configurable).
- **Panel:** state and dish uptime; latency, packet loss, download, upload; 15-minute sparklines (Swift Charts); obstruction and alerts; today's outages.
- **Notifications:** outage longer than 10 s ("Starlink offline"), recovery with the outage duration, optional high latency for 5 minutes.
- **Data source:** the dish directly (default; status every 2 s, history every 30 s) or a collector URL (adds the TV dashboard link and speed tests).
- **Settings:** bar text, notifications, open at login (`SMAppService`), data source and addresses.

macOS asks for **Local Network** access the first time the app contacts the dish.

**Off Starlink:** the dish only answers from a Starlink network. When it stops answering, the app checks whether the internet still works (HTTPS request to `www.apple.com/library/test/success.html`, re-checked every 15 s). If it does, the Mac is on another network: the app shows **Not on Starlink** (gray icon, no outage alerts) and resumes when the dish answers again. If the internet is down too, it's treated as an outage. Inside a Starlink network the internet goes through the dish, so a working internet with a silent dish can't be a Starlink outage.
