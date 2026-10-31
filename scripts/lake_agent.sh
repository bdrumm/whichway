#!/usr/bin/env bash
# A launchd agent that runs `make lake` every night at 03:20: the data branch's new day files, the archive's
# newly published service days and this Mac's store go into data/lake before any rolling window loses them.
#   scripts/lake_agent.sh install   -> writes ~/Library/LaunchAgents/com.whichway.lake.plist and loads it
#   scripts/lake_agent.sh remove    -> unloads and deletes it
#   scripts/lake_agent.sh run       -> runs the job now (what the agent runs)
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="com.whichway.lake"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$REPO/data/lake/logs"
case "${1:-}" in
  install)
    mkdir -p "$LOG" "$HOME/Library/LaunchAgents"
    cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>-lc</string>
    <string>cd "$REPO" && make lake</string>
  </array>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>3</integer><key>Minute</key><integer>20</integer></dict>
  <key>StandardOutPath</key><string>$LOG/nightly.log</string>
  <key>StandardErrorPath</key><string>$LOG/nightly.log</string>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin</string></dict>
</dict></plist>
PL
    launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "installed $PLIST (nightly 03:20; log: $LOG/nightly.log)"
    ;;
  remove)
    launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
    rm -f "$PLIST"
    echo "removed $LABEL"
    ;;
  run)
    cd "$REPO" && make lake
    ;;
  *) echo "usage: $0 install|remove|run" >&2; exit 2;;
esac
