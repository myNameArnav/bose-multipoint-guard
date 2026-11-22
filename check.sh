#!/bin/zsh
# Show where the headphones' 55 s battery heartbeat is going, and whether the
# Mac's A2DP stream is suffering. Usage: ./check.sh [minutes]
# Android side needs a phone on ADB (optional).
M=${1:-5}
LOG=~/Library/Logs/boseguard.log
SINCE=$(date -v-${M}M '+%Y-%m-%d %H:%M:%S')
echo "== Mac: +IPHONEACCEV heartbeats received (last ${M}m) =="
# `log show` doesn't keep these lines, so they come from boseguard's own log.
awk -v s="$SINCE" '$3=="hb" && ($1" "$2)>=s {n++; t[n]=$2} END{for(i=(n>6?n-5:1);i<=n;i++)print t[i]; if(!n)print "(none)"}' $LOG 2>/dev/null
echo; echo "== Mac: A2DP seconds with ReTx >40% =="
/usr/bin/log show --last ${M}m --style compact --info --predicate 'process == "bluetoothd"' 2>/dev/null \
  | grep "A2DP LinkQualityReport" \
  | awk '{match($0,/ReTx = *[0-9.]+/); r=substr($0,RSTART+7,RLENGTH-7)+0; n++; if(r>40)b++} END{printf "%d/%d seconds bad\n", b, n}'
if command -v adb >/dev/null && adb get-state >/dev/null 2>&1; then
  echo; echo "== Android: heartbeats (unknown AT) and forced-active link wakes =="
  adb logcat -d -b all -v time 2>/dev/null | grep -aE "Unmatched command index|new_mode:forced:active" | tail -6 | cut -c1-120
fi
echo; echo "== boseguard =="; grep -v ' hb$' $LOG 2>/dev/null | tail -6
