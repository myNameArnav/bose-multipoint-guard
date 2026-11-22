# bose-multipoint-guard

A macOS fix for crackling, static and dropouts on Bose QuietComfort Headphones
when they're connected to **a Mac and an Android phone at the same time**
(multipoint) and you're listening on the Mac.

## Symptom

You listen to music or a video on the Mac while the headphones are also connected
to an Android phone. Every minute or so the audio crackles, cuts out for 0.5–2 s
or stutters. Moving closer to the Mac doesn't help, and nothing is playing on the
phone.

## Cause

The headphones send an Apple-style accessory battery report over HFP every
**55 seconds**, whether or not the battery level has changed:

```
AT+IPHONEACCEV=2,1,<battery 0-9>,2,0
```

These reports go to the **most recently connected** source. If both sources
connected at about the same time (for example at power-on), both get them.

- **On the Mac:** harmless. macOS uses the report to show the battery level.
- **On Android:** Android doesn't recognise the command
  (`bta_ag_process_at: Unmatched command index`) and drops it. But every AT
  command still makes the phone take its link to the headphones out of sniff
  (low-power) mode and hold it in active mode for about 25 s.

The headphones have one radio. While the phone's link is active, they miss
many of the Mac's A2DP transmit slots. The Mac's retransmission rate goes from
about 12% to about 70%, its jitter buffer runs dry, and you hear static. This
repeats every 55 s for as long as you listen.

Measured with one phone:

| Who receives the heartbeat | Mac A2DP median ReTx | Seconds with ReTx >40% |
|---|---|---|
| phone (link forced active) | 69.9% | 96% |
| Mac only | 11.8% | 10% |

Reconnecting the headphones **from the Mac** makes the Mac the most recent
source, and the heartbeat moves to the Mac. That fix lasts until the phone
reconnects, for example when the headphones are power-cycled or come back into
range.

## Fix

`boseguard` is a small background agent. It reads `bluetoothd`'s log and
reconnects the headphones from the Mac (an audio gap of about 4 s) when any of
these happens:

- **A:** The headphones have been connected to the Mac for more than 150 s, but the
  Mac hasn't received a heartbeat in 150 s. That means the heartbeat has moved to
  the phone.
- **B:** While audio is streaming, ReTx bursts start within about 2 s of the Mac's
  heartbeat for 3 cycles in a row. That means the phone is getting it too.
- **C:** About 45 s after the headphones newly connect to the Mac. This covers
  the power-on case.

It reconnects at most once every 3 minutes and at most 6 times an hour.

You don't need to change anything on the phone or the headphones, and phone
calls keep working on the phone.

## Install

Requires macOS with the Xcode Command Line Tools (`swiftc`).

```sh
system_profiler SPBluetoothDataType      # find your headphones' address
./install.sh AA-BB-CC-DD-EE-FF
```

The first time it connects or disconnects the headphones, macOS may ask you to
allow Bluetooth access.

- Log: `~/Library/Logs/boseguard.log`
- Try it without reconnecting anything: `swiftc -O boseguard.swift -o boseguard && ./boseguard <addr> --dry-run`
- Remove: `./uninstall.sh`

## Diagnose

```sh
./check.sh 5      # last 5 minutes
```

This shows:

- the heartbeats the Mac received
- how many seconds had bad A2DP retransmission
- the Android side, if a phone is on ADB
- what boseguard has done

If the static lines up with `forced:active` on the phone every ~55 s and the Mac
shows no heartbeats, the phone has the heartbeat.

## Notes

- Tested on QuietComfort Headphones (USB PID `0x4075`, firmware 1.0.6) with a
  Pixel running Android 17 and a recent macOS. Other Bose models that
  send `+IPHONEACCEV` probably behave the same way. Change the thresholds in
  `boseguard.swift` if needed.
- Things that didn't help: changing range or RF environment, Wi-Fi band, and
  lowering the AAC bitrate (`AACBitrate` in the Bluetooth preferences).
- Turning off "Phone calls" for the headphones on Android probably stops the
  wakeups too, because the report travels over HFP. But then you can't take
  calls on them.
