#!/bin/zsh
# Show where the headphones' 55 s battery heartbeat is going, and whether the
# Mac's A2DP stream is suffering. Usage: ./check.sh [minutes]
# Android side needs a phone on ADB (optional).
M=${1:-5}
echo "== Mac: +IPHONEACCEV heartbeats received (last ${M}m) =="
/usr/bin/log show --last ${M}m --style compact --predicate 'process == "bluetoothd" AND eventMessage CONTAINS "IPHONEACCEV"' 2>/dev/null | awk 'NR>1{print substr($2,1,8)}' | tail -6
echo; echo "== Mac: A2DP seconds with ReTx >40% =="
/usr/bin/log show --last ${M}m --style compact --info --predicate 'process == "bluetoothd"' 2>/dev/null \
  | grep "A2DP LinkQualityReport" \
  | awk '{match($0,/ReTx = *[0-9.]+/); r=substr($0,RSTART+7,RLENGTH-7)+0; n++; if(r>40)b++} END{printf "%d/%d seconds bad\n", b, n}'
if command -v adb >/dev/null && adb get-state >/dev/null 2>&1; then
  echo; echo "== Android: heartbeats (unknown AT) and forced-active link wakes =="
  adb logcat -d -b all -v time 2>/dev/null | grep -aE "Unmatched command index|new_mode:forced:active" | tail -6 | cut -c1-120
fi
echo; echo "== boseguard =="; tail -5 ~/Library/Logs/boseguard.log 2>/dev/null
