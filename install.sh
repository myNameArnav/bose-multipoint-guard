#!/bin/zsh
# Build boseguard and install it as a per-user LaunchAgent.
# Usage: ./install.sh <headphone-address>   e.g. ./install.sh AA-BB-CC-DD-EE-FF
# Find the address in: System Settings → Bluetooth → (i), or
#   system_profiler SPBluetoothDataType
set -euo pipefail
ADDR=${1:?usage: ./install.sh <headphone-address>}
ADDR=${ADDR//:/-}
DIR=${0:A:h}
BIN="$HOME/.local/bin/boseguard"
LABEL=local.boseguard
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p "${BIN:h}" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
swiftc -O "$DIR/boseguard.swift" -o "$BIN"

cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN</string><string>$ADDR</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/boseguard.err</string>
</dict></plist>
PL

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed; log: ~/Library/Logs/boseguard.log"
