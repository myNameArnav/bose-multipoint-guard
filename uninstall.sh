#!/bin/zsh
LABEL=local.boseguard
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$HOME/.local/bin/boseguard"
echo "removed (logs left in ~/Library/Logs/boseguard.*)"
