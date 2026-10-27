# StarlinkBar (v0.4.0)

A lightweight macOS menu bar app that shows your Starlink connection at a glance: live latency, packet loss, throughput, obstruction, dish alerts and today's outages, read straight from your dish. Ships as a universal binary for Intel and Apple Silicon.

![StarlinkBar popup under the menu bar: STARLINK · CONNECTED, 28 ms latency with a 15-minute sparkline, download, upload, loss and today's outages](starlinkbar_cover.jpg)

> Running an older version? From 0.4.0 on, StarlinkBar updates itself: right-click the menu bar icon → **Check for Updates…**. On 0.3.2 or earlier, re-download it once from [Gumroad](https://bereto.gumroad.com/l/starlinkbar).

**Menu bar:** the dish icon and your latency, like `28 ms` (or download speed, or icon only). It says `offline` during an outage.

**Popup:**
- Connection state: Connected, Degraded or No internet, plus how long the dish has been up
- Latency with its 30 second average and a 15 minute sparkline
- Download, upload and packet loss
- Obstruction and dish alerts in plain English ("Weaker signal than expected", "No Ethernet link"…)
- Today's outages with time, duration and cause

**Notifications:** when Starlink drops for more than 10 seconds, and again when it's back ("The outage lasted 42 s"). Optional heads-up for high latency.

**Updates:** checks once a day and asks before installing. Every update is signed and verified before it's applied.

**Not on Starlink?** The same card measures whatever network you're on (Wi‑Fi, Ethernet, hotspot): latency, loss, throughput and outages, with your last Starlink numbers at the bottom. The menu bar switches to an antenna so you always know which one you're looking at.

## How it works

Every Starlink dish answers a small local API at `192.168.100.1`, the same one the Starlink app uses. StarlinkBar asks it for status and history every couple of seconds and turns the numbers into something readable. It's read-only: it never sends commands to the dish (no reboots, no stow), and nothing leaves your network. No account, no server, no extra permissions beyond Local Network access.

When the dish stops answering, StarlinkBar checks whether the internet still works. If it does, you're on another network, not in a Starlink outage, so it measures that network instead and doesn't cry wolf.

The details (gRPC-web transport, field numbers, state rules) are in [docs/DESIGN.md](https://github.com/bereto-dev/starlink-monitor/blob/main/docs/DESIGN.md).

## Requirements

- macOS 13 or later
- Intel or Apple Silicon Mac
- A Starlink connection (the app works on other networks too, but there's no dish to read there)
- Xcode Command Line Tools (`xcode-select --install`) to build from source

## Download & run (no build required)

Get `StarlinkBar.app` from [Gumroad](https://bereto.gumroad.com/l/starlinkbar).

1. Download the app
2. Move it to your `/Applications` folder
3. Right-click → **Open** → **Open** (required once to bypass Gatekeeper on unsigned apps)
4. Allow **Local Network** access when macOS asks: that's how the app talks to the dish

## Build from source

```bash
git clone https://github.com/bereto-dev/starlink-monitor.git
cd starlink-monitor
menubar/StarlinkBar/build.sh --open   # universal build + launch
```

`build.sh --zip` packages `dist/StarlinkBar-<version>.zip` with `ditto`.

## Settings

Right-click the menu bar icon → **Settings…**

- What the menu bar shows: latency, download speed or icon only
- Notifications for outages and for high latency
- Open at login
- Check for updates automatically (on by default)
- Data source: the dish directly (default) or the optional collector below

## Collector + Starlink Dashboard (optional)

For long-term history and a full-screen dashboard on any screen or browser in the house, there's a small Python collector (standard library only):

```bash
python3 collector/main.py        # or: collector/install-agent.sh to run it at login
```

Then open `http://<mac-ip>:8766/sl-dashboard/`. The dashboard is plain ES5, so it also runs on old smart-TV browsers. StarlinkBar can read from the collector instead of the dish (Settings › Data source).

API: `/api/now`, `/api/history?range=15m|1h|24h|7d`, `/api/outages?since=&min_s=`.

## Changelog

### 0.4.0 — Automatic updates
StarlinkBar now updates itself. Once a day it checks for a new version and, if there is one, shows you what's new with an Install and Relaunch button. You can also check any time from the right-click menu (Check for Updates…), and turn the daily check off in Settings. Updates are signed, so the app only installs versions that really come from me.

### 0.3.2 — New icon
A cleaner icon: a black dish on white, closer to the Starlink look. Downloads now live on Gumroad, and Check for Updates (right-click menu and About) takes you there.

### 0.3.1 — Roomier card
The popup is a bit wider so the numbers and the outage list breathe, and the refresh button is gone (the card already updates every couple of seconds). Refresh Now (⌘R) is still in the right-click menu.

### 0.3.0 — Works on any network
When you're not on Starlink, StarlinkBar now measures the network you're on: latency, loss, download, upload, time connected and today's outages, in the same card. The menu bar shows an antenna instead of the dish. Every dish alert also has a real name now, so you'll see "Weaker signal than expected" instead of "alert_17".

### 0.2.0 — New look
The popup was rebuilt to match my other menu bar apps: a dark card with a hand-drawn sparkline, a right-click menu, and proper Settings and About windows.

### 0.1.x — First versions
Reads the dish directly with no server needed, warns you about outages and when they end, and tells you when you're online through another network instead of showing a false outage.

## Origin

I wanted to know at a glance whether my Starlink was fine, without picking up my phone to open the Starlink app. Now it's one look at the menu bar.

Not affiliated with SpaceX or Starlink.

## License

[MIT](LICENSE)
