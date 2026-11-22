// boseguard — keeps the Bose's 55 s +IPHONEACCEV battery heartbeat on the Mac.
//
// The headphones send the heartbeat over HFP to whichever source connected
// most recently (or to both for a while after the phone reconnects). When the
// phone gets it, Android forces that link from sniff to active for ~25 s and
// the Mac's A2DP stream starves (static). Reconnecting from the Mac makes the
// Mac the latest connection, which moves the heartbeat back to the Mac.
//
// A full reconnect is the only lever: macOS gives apps no control over its own
// HFP connection, and the headphones' BMAP interface neither exposes nor
// changes where the heartbeat goes.
//
// Reconnects from the Mac when either:
//  A) the headphones have been connected for 120 s and the Mac hasn't received a
//     heartbeat in 120 s (two missed beats): the phone has it;
//  B) while streaming, ReTx bursts start right after the Mac's heartbeat for 3
//     cycles in a row: the phone is getting it too (its copy lands ~2 s later).
//
// Safety:
//  - at most one reconnect every 3 min and 6 per hour;
//  - the reconnect retries the connect step, so the headphones aren't left
//    disconnected from the Mac;
//  - after a reconnect the Mac must get a heartbeat within 150 s. If it doesn't,
//    rule A pauses for 30 min (or until a heartbeat arrives). That stops a
//    reconnect loop if macOS changes its log format.
//
// Build: swiftc -O boseguard.swift -o boseguard
// Run:   boseguard <address> [--dry-run]   (install.sh sets it up as a LaunchAgent)
import Foundation
import IOBluetooth

// ---- tunables ---------------------------------------------------------------
let heartbeatMissingAfter: TimeInterval = 120   // period is 55 s, so 2 missed beats
let proofWindow: TimeInterval = 150             // heartbeat expected this soon after a reconnect
let pauseAfterNoProof: TimeInterval = 1800
let minGapBetweenReconnects: TimeInterval = 180
let maxReconnectsPerHour = 6

// ---- setup ------------------------------------------------------------------
let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("--") }
guard let addr = args.first else { print("usage: boseguard <headphone-address, e.g. AA-BB-CC-DD-EE-FF> [--dry-run]"); exit(64) }
let dryRun = CommandLine.arguments.contains("--dry-run")
guard let dev = IOBluetoothDevice(addressString: addr) else { print("no device \(addr)"); exit(1) }

let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/boseguard.log")
if let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size > 2_000_000 {
    let old = logURL.appendingPathExtension("old")
    try? FileManager.default.removeItem(at: old)
    try? FileManager.default.moveItem(at: logURL, to: old)
}
let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
let logQueue = DispatchQueue(label: "boseguard.log")
func log(_ s: String) {
    logQueue.sync {
        let line = "\(fmt.string(from: Date())) \(s)\n"
        FileHandle.standardOutput.write(line.data(using: .utf8)!)
        if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
        else { try? line.write(to: logURL, atomically: true, encoding: .utf8) }
    }
}

// Shared with the log reader (guarded by `lock`).
let lock = NSLock()
var heartbeats: [Date] = []          // Mac-side +IPHONEACCEV arrivals
var retx: [(Date, Double)] = []      // per-second A2DP ReTx %

// Main-thread only.
var connectedSince: Date? = nil
let startedAt = Date()
var lastReconnect = Date.distantPast
var reconnectTimes: [Date] = []
var awaitingProofSince: Date? = nil  // last reconnect, until a heartbeat confirms it worked
var ruleAPausedAt: Date? = nil

// ---- log stream reader ------------------------------------------------------
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
            log("hb")   // `log show` doesn't keep these lines; check.sh reads them from here
        } else if line.contains("LinkQualityReport"),
                  let m = retxRe.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let r = Range(m.range(at: 1), in: line), let v = Double(line[r]) {
            lock.lock(); retx.append((now, v)); lock.unlock()
        }
    }
}

// ---- reconnect --------------------------------------------------------------
func waitUntil(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if cond() { return true }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return cond()
}

func reconnect(_ reason: String) {
    let now = Date()
    reconnectTimes = reconnectTimes.filter { now.timeIntervalSince($0) < 3600 }
    if now.timeIntervalSince(lastReconnect) < minGapBetweenReconnects || reconnectTimes.count >= maxReconnectsPerHour {
        log("would reconnect (\(reason)) but rate-limited"); return
    }
    lastReconnect = now; reconnectTimes.append(now)
    if dryRun { log("DRY RUN reconnect: \(reason)"); return }

    log("reconnecting: \(reason)")
    let closed = dev.closeConnection()
    let down = waitUntil(6) { !dev.isConnected() }
    var attempts = 0
    repeat {
        attempts += 1
        _ = dev.openConnection()
        if waitUntil(3, { dev.isConnected() }) { break }
        Thread.sleep(forTimeInterval: 2)
    } while attempts < 3
    let ok = dev.isConnected()
    log("  close=\(closed) linkDropped=\(down) attempts=\(attempts) connected=\(ok)")
    if !ok { log("  WARNING: couldn't reconnect; connect the headphones from the Bluetooth menu") }

    lock.lock(); heartbeats.removeAll(); retx.removeAll(); lock.unlock()
    connectedSince = ok ? Date() : nil
    awaitingProofSince = ok ? Date() : nil
}

// ---- evaluation loop --------------------------------------------------------
func evaluate() {
    let now = Date()
    guard dev.isConnected() else {
        if connectedSince != nil { log("headphones disconnected from Mac") }
        connectedSince = nil
        return
    }
    if connectedSince == nil { connectedSince = now; log("headphones connected to Mac") }

    lock.lock()
    heartbeats = heartbeats.filter { now.timeIntervalSince($0) < 600 }
    retx = retx.filter { now.timeIntervalSince($0.0) < 600 }
    let hb = heartbeats, rx = retx
    lock.unlock()
    let lastHB = hb.last

    // Did the last reconnect actually bring the heartbeat to the Mac?
    if let t = awaitingProofSince {
        if let h = lastHB, h > t {
            log("heartbeat is on the Mac \(Int(h.timeIntervalSince(t)))s after reconnect")
            awaitingProofSince = nil
        } else if now.timeIntervalSince(t) > proofWindow {
            log("WARNING: no heartbeat within \(Int(proofWindow))s of reconnecting; pausing rule A for \(Int(pauseAfterNoProof / 60)) min. "
                + "Either the phone took it straight back or macOS changed its Bluetooth log format.")
            awaitingProofSince = nil
            ruleAPausedAt = now
        }
    }
    if let p = ruleAPausedAt, now.timeIntervalSince(p) > pauseAfterNoProof || (lastHB.map { $0 > p } ?? false) {
        log("rule A resumed")
        ruleAPausedAt = nil
    }

    // Rule A: heartbeat absent on the Mac.
    let watchedFor = now.timeIntervalSince(max(connectedSince!, startedAt))
    let sinceHB = lastHB.map { now.timeIntervalSince($0) } ?? .infinity
    if ruleAPausedAt == nil && awaitingProofSince == nil
        && watchedFor > heartbeatMissingAfter && sinceHB > heartbeatMissingAfter {
        reconnect("no heartbeat on Mac for \(Int(min(sinceHB, watchedFor)))s; the phone has it")
        return
    }

    // Rule B: ReTx bursts right after each heartbeat (the phone is getting it too).
    let streaming = rx.last.map { now.timeIntervalSince($0.0) < 5 } ?? false
    guard streaming else { return }
    let complete = hb.filter { now.timeIntervalSince($0) > 56 }.suffix(3)
    guard complete.count == 3 else { return }
    var hits = 0
    for t in complete {
        let inW  = rx.filter { let d = $0.0.timeIntervalSince(t); return d >= 1 && d < 28 }
        let outW = rx.filter { let d = $0.0.timeIntervalSince(t); return d >= 30 && d < 54 }
        guard inW.count >= 20, outW.count >= 18 else { return }   // not enough samples (paused audio etc.)
        let badIn = inW.filter { $0.1 > 40 }.count, badOut = outW.filter { $0.1 > 40 }.count
        if badIn >= 8 && badIn >= 3 * max(badOut, 1) { hits += 1 }
    }
    if hits == 3 { reconnect("ReTx bursts right after the heartbeat for 3 cycles; the phone is getting it too") }
}

log("boseguard started for \(addr)\(dryRun ? " (dry run)" : "")")
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now() + 5, repeating: 5)
timer.setEventHandler { evaluate() }
timer.resume()
signal(SIGTERM) { _ in proc.terminate(); exit(0) }
RunLoop.main.run()
