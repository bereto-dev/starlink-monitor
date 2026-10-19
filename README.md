# Starlink Monitor

Keep an eye on your Starlink connection from the macOS menu bar: latency, packet loss, throughput, obstruction, alerts and today's outages, with notifications when the connection drops.

Everything is **read-only**: it only asks the dish for its status and history and never sends commands.

## StarlinkBar (menu bar app)

### Download

1. Get **StarlinkBar-x.y.z.zip** from the [latest release](../../releases/latest).
2. Unzip it and move **StarlinkBar.app** to Applications.
3. The first time, right-click the app and choose **Open** (it isn't notarized by Apple yet). If macOS still blocks it, allow it in System Settings › Privacy & Security.
4. Allow **Local Network** access when macOS asks: that's how the app talks to the dish.

Requires macOS 13 or later and a Mac on a Starlink network. It works on its own: it reads the dish at `192.168.100.1` directly, no server needed.

### Build from source

```bash
menubar/StarlinkBar/build.sh --open   # build and launch (needs Xcode or the Command Line Tools)
menubar/StarlinkBar/build.sh --zip    # universal build + dist/StarlinkBar-<version>.zip
```

Releases are built by GitHub Actions when a `v*` tag is pushed (`.github/workflows/release.yml`).

## Collector + TV dashboard (optional)

For long-term history and a full-screen dashboard on a TV or any browser in the house:

```bash
python3 collector/main.py        # Python 3, standard library only
collector/install-agent.sh       # or run it at login as a launchd agent
```

Then open `http://<mac-ip>:8766/tv/`. The dashboard is plain ES5, so it also runs on old smart-TV browsers. StarlinkBar can read from the collector instead of the dish (Settings › Data source).

API: `/api/now`, `/api/history?range=15m|1h|24h|7d`, `/api/outages?since=&min_s=`.

## How it works

See [docs/DESIGN.md](docs/DESIGN.md) for the dish's gRPC-web API, field mapping, state rules and the design of each component.

Not affiliated with SpaceX or Starlink.

## License

[MIT](LICENSE)
