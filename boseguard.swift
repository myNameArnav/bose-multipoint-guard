// boseguard — keeps the Bose's 55 s +IPHONEACCEV battery heartbeat on the Mac.
//
// The headphones send the heartbeat over HFP to whichever source connected
// most recently (or to both after a simultaneous power-on connect). When the
// phone gets it, Android forces that link from sniff to active for ~25 s and
// the Mac's A2DP stream starves (static). Reconnecting the Mac makes the Mac
// the latest connection, which moves the heartbeat back to the Mac (harmless).
//
// Triggers a Mac-side reconnect when any of:
//  A) headphones connected to Mac >150 s but no heartbeat seen on Mac for 150 s
//     (heartbeat has moved to the phone);
//  B) while streaming, ReTx bursts line up with the Mac's heartbeat for 3 cycles
//     in a row (both devices getting it; the phone's copy lands ~2 s after);
//  C) once, ~45 s after the headphones freshly connect to the Mac.
//
// Build: swiftc -O boseguard.swift -o boseguard
// Run:   boseguard <address> [--dry-run]   (install.sh sets it up as a LaunchAgent)
import Foundation
import IOBluetooth

let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("--") }
guard let addr = args.first else { print("usage: boseguard <headphone-address, e.g. AA-BB-CC-DD-EE-FF> [--dry-run]"); exit(64) }
let dryRun = CommandLine.arguments.contains("--dry-run")
guard let dev = IOBluetoothDevice(addressString: addr) else { print("no device \(addr)"); exit(1) }

let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/boseguard.log")
let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
func log(_ s: String) {
    let line = "\(fmt.string(from: Date())) \(s)\n"
    FileHandle.standardOutput.write(line.data(using: .utf8)!)
    if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
    else { try? line.write(to: logURL, atomically: true, encoding: .utf8) }
}

let lock = NSLock()
var heartbeats: [Date] = []          // Mac-side +IPHONEACCEV arrivals
var retx: [(Date, Double)] = []      // per-second A2DP ReTx %
var connectedSince: Date? = nil
var lastCycle = Date.distantPast
var cycleTimes: [Date] = []
var startedAt = Date()
var freshConnect = false      // connected by the user/headphones, not by us

// ---- log stream reader -------------------------------------------------------
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/log")
proc.arguments = ["stream", "--style", "compact", "--level", "info", "--predicate",
    "process == \"bluetoothd\" AND (eventMessage CONTAINS \"IPHONEACCEV\" OR eventMessage CONTAINS \"A2DP LinkQualityReport\")"]
let pipe = Pipe(); proc.standardOutput = pipe; proc.standardError = FileHandle.nullDevice
proc.terminationHandler = { _ in log("log stream exited; quitting so launchd restarts us"); exit(2) }
try proc.run()

let retxRe = try NSRegularExpression(pattern: "ReTx = *([0-9.]+)")
var buf = Data()
pipe.fileHandleForReading.readabilityHandler = { h in
    let d = h.availableData
    if d.isEmpty { return }
    buf.append(d)
    while let nl = buf.firstIndex(of: 0x0a) {
        let lineData = buf.subdata(in: buf.startIndex..<nl)
        buf.removeSubrange(buf.startIndex...nl)
        guard let line = String(data: lineData, encoding: .utf8) else { continue }
        let now = Date()
        if line.contains("IPHONEACCEV") {
            lock.lock(); heartbeats.append(now); lock.unlock()
        } else if line.contains("LinkQualityReport"),
                  let m = retxRe.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let r = Range(m.range(at: 1), in: line), let v = Double(line[r]) {
            lock.lock(); retx.append((now, v)); lock.unlock()
        }
    }
}

// ---- reconnect ---------------------------------------------------------------
func cycle(_ reason: String) {
    let now = Date()
    cycleTimes = cycleTimes.filter { now.timeIntervalSince($0) < 3600 }
    if now.timeIntervalSince(lastCycle) < 180 || cycleTimes.count >= 6 {
        log("would reconnect (\(reason)) but rate-limited"); return
    }
    lastCycle = now; cycleTimes.append(now)
    if dryRun { log("DRY RUN reconnect: \(reason)"); return }
    log("reconnecting: \(reason)")
    let c = dev.closeConnection()
    Thread.sleep(forTimeInterval: 3)
    let o = dev.openConnection()
    log("  close=\(c) open=\(o) connected=\(dev.isConnected())")
    lock.lock(); heartbeats.removeAll(); lock.unlock()
    connectedSince = dev.isConnected() ? Date() : nil
    freshConnect = false
}

// ---- evaluation loop ---------------------------------------------------------
func evaluate() {
    let now = Date()
    let connected = dev.isConnected()
    if !connected { connectedSince = nil; return }
    if connectedSince == nil { connectedSince = now; freshConnect = true; log("headphones connected to Mac") }

    // Rule C: after a fresh connect (e.g. power-on, when both sources get the
    // heartbeat), reconnect once ~45 s in so the Mac becomes the latest source.
    if freshConnect && now.timeIntervalSince(connectedSince!) > 45 {
        freshConnect = false
        if now.timeIntervalSince(startedAt) > 60 { cycle("fresh connect — making the Mac the most recent source"); return }
    }

    lock.lock()
    heartbeats = heartbeats.filter { now.timeIntervalSince($0) < 600 }
    retx = retx.filter { now.timeIntervalSince($0.0) < 600 }
    let hb = heartbeats, rx = retx
    lock.unlock()

    // Rule A: heartbeat absent on the Mac.
    let since = now.timeIntervalSince(max(connectedSince!, startedAt))
    let lastHB = hb.last.map { now.timeIntervalSince($0) } ?? .infinity
    if since > 150 && lastHB > 150 {
        cycle("no heartbeat on Mac for \(Int(min(lastHB, since)))s — it went to the phone")
        return
    }

    // Rule B: ReTx bursts aligned with the heartbeat (phone also receiving it).
    let streaming = rx.last.map { now.timeIntervalSince($0.0) < 5 } ?? false
    guard streaming else { return }
    let complete = hb.filter { now.timeIntervalSince($0) > 56 }.suffix(3)
    guard complete.count == 3 else { return }
    var hits = 0
    for t in complete {
        let inW  = rx.filter { let d = $0.0.timeIntervalSince(t); return d >= 1 && d < 28 }
        let outW = rx.filter { let d = $0.0.timeIntervalSince(t); return d >= 30 && d < 54 }
        guard inW.count >= 20, outW.count >= 18 else { return }
        let badIn = inW.filter { $0.1 > 40 }.count, badOut = outW.filter { $0.1 > 40 }.count
        if badIn >= 8 && badIn >= 3 * max(badOut, 1) { hits += 1 }
    }
    if hits == 3 { cycle("ReTx bursts aligned with heartbeat for 3 cycles — phone is receiving it too") }
}

log("boseguard started for \(addr)\(dryRun ? " (dry run)" : "")")
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now() + 5, repeating: 5)
timer.setEventHandler { evaluate() }
timer.resume()
signal(SIGTERM) { _ in proc.terminate(); exit(0) }
RunLoop.main.run()
