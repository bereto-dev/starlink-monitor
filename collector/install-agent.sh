#!/bin/bash
# Installs (or updates) the collector as a launchd agent for the current user.
#
# launchd jobs can't read ~/Desktop or ~/Documents (macOS privacy protection), so
# the collector and the TV dashboard are copied to
# ~/Library/Application Support/StarlinkMonitor/app and the agent runs that copy.
# Re-run this script after changing the code.
#
#   ./install-agent.sh            install / update and (re)start
#   ./install-agent.sh --remove   stop and remove the agent (keeps the data)
set -euo pipefail

LABEL=io.github.bereto-dev.starlinkmonitor
SRC="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HOME/Library/Application Support/StarlinkMonitor/app"
LOG="$HOME/Library/Logs/StarlinkMonitor/collector.log"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
PYTHON="${PYTHON:-/usr/bin/python3}"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true

if [[ "${1:-}" == "--remove" ]]; then
  rm -f "$PLIST"
  echo "Agent removed. Data and logs were kept."
  exit 0
fi

mkdir -p "$APP/collector" "$APP/tv" "$(dirname "$LOG")" "$(dirname "$PLIST")"
rsync -a --delete --exclude '__pycache__' --exclude '*.sh' "$SRC/collector/" "$APP/collector/"
rsync -a --delete "$SRC/tv/" "$APP/tv/"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$PYTHON</string>
		<string>-u</string>
		<string>$APP/collector/main.py</string>
	</array>
	<key>WorkingDirectory</key>
	<string>$APP/collector</string>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>10</integer>
	<key>ProcessType</key>
	<string>Background</string>
	<key>StandardOutPath</key>
	<string>$LOG</string>
	<key>StandardErrorPath</key>
	<string>$LOG</string>
</dict>
</plist>
EOF
plutil -lint "$PLIST" >/dev/null

# Free port 8766 if a collector was started by hand.
pkill -f 'collector/main.py' 2>/dev/null || true
sleep 1

launchctl bootstrap "$DOMAIN" "$PLIST"
echo "Agent loaded ($LABEL). Logs: $LOG"
