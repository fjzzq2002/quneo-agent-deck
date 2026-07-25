// QuNeo Agent Deck — menu bar app.
//
// Reads session state files written by hook.py and drives the QuNeo's pad
// LEDs: each Claude Code session gets a pad. Pad presses acknowledge a
// session and pull up Warp. The rotaries are googly eyes that get frantic
// when a session needs attention. Runs as a status-bar item (no dock icon).
//
// CLI modes: `--test` pad sweep, `--eyes` googly eye demo (both exit after).
//
// Default QuNeo factory preset (manual v1.2.4, MIDI Input chapter):
//   Pad presses OUT: notes 36-51 on channel 1, bottom-left pad = 36,
//     row-major left-to-right going up, top-right = 51.
//   Pad LEDs IN (drum mode, channel 1): pad i (same visual order, 0-15)
//     has note 2i for its green LED and 2i+1 for red; velocity = brightness.
//   Rotary LEDs IN: CC6 (left) / CC7 (right), value 0-127 around the ring.
//   Notes 33-49 on channel 1 are the side-button LEDs — do not touch.

import AppKit
import CoreMIDI
import Foundation

let padNotes: [UInt8] = Array(36...51)  // press input, not LEDs
let stateDir = NSString(string: "~/.quneo-deck/state").expandingTildeInPath
let agentPlistPath = NSString(string: "~/Library/LaunchAgents/com.quneo.agentdeck.plist").expandingTildeInPath

struct Session {
    let id: String
    let status: String
    let cwd: String
    let pid: Int32?
    let tty: String?
    let term: String?
    let created: Double
    let updated: Double
    let path: String
    var remote: String? = nil   // ssh alias this session was polled from
    var host: String? = nil     // machine the claude process runs on
    var sshConn: String? = nil  // remote $SSH_CONNECTION: "clientIP clientPort serverIP serverPort"
    var agent: String? = nil    // nil = claude; "codex" = OpenAI Codex CLI
}

var padSlots: [Session?] = Array(repeating: nil, count: 16)  // index = pad

// --- Pad arrangement: sticky and persistent -----------------------------
// Sessions keep their pad for life (no reshuffling when another session
// ends). New sessions land on their project's remembered "home pad" when
// it's free, else the lowest free pad. Manual moves via the menu update
// both maps; everything persists in arrangement.json.
let arrangementPath = NSString(string: "~/.quneo-deck/arrangement.json").expandingTildeInPath
var slotForSession: [String: Int] = [:]
var homePads: [String: Int] = [:]

func projectName(_ cwd: String) -> String { (cwd as NSString).lastPathComponent }

func loadArrangement() {
    guard let d = FileManager.default.contents(atPath: arrangementPath),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
    slotForSession = (o["slots"] as? [String: Int]) ?? [:]
    homePads = (o["homes"] as? [String: Int]) ?? [:]
}

func saveArrangement() {
    let o: [String: Any] = ["slots": slotForSession, "homes": homePads]
    if let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) {
        try? d.write(to: URL(fileURLWithPath: arrangementPath))
    }
}

func assignPads(_ sessions: [Session]) -> [Session?] {
    var slots = [Session?](repeating: nil, count: 16)
    var used = Set<Int>()
    var changed = false
    let alive = Set(sessions.map { $0.id })
    for id in slotForSession.keys where !alive.contains(id) {
        slotForSession.removeValue(forKey: id)
        changed = true
    }
    var pending: [Session] = []
    for s in sessions.sorted(by: { $0.created < $1.created }) {
        if let i = slotForSession[s.id], (0..<16).contains(i), !used.contains(i) {
            slots[i] = s
            used.insert(i)
        } else {
            pending.append(s)
        }
    }
    for s in pending {
        let home = homePads[projectName(s.cwd)]
        let pad: Int?
        if let h = home, (0..<16).contains(h) {
            // Cyclic column-wise scan from the home pad: same-project
            // sessions stack up the column, wrapping to the next column.
            pad = nextFreeColumnwise(from: h, used: used)
        } else {
            // Un-homed sessions live in the leftmost column, growing
            // downward from the top-left pad; spill column-wise when full.
            pad = nextFreeColumnwise(from: 12, used: used)
        }
        guard let p = pad else { continue }
        slots[p] = s
        used.insert(p)
        slotForSession[s.id] = p
        changed = true
    }
    if changed { saveArrangement() }
    return slots
}

// Scan pads in column-major order, top-to-bottom within a column, then the
// next column, starting at `from`, cyclically. Pad i: row = i/4 (0 =
// bottom), col = i%4 — so "top-to-bottom" means descending row.
func nextFreeColumnwise(from: Int, used: Set<Int>) -> Int? {
    let start = (from % 4) * 4 + (3 - from / 4)  // row-major -> descending column-major
    for k in 0..<16 {
        let cm = (start + k) % 16
        let pad = (3 - cm % 4) * 4 + (cm / 4)    // descending column-major -> row-major
        if !used.contains(pad) { return pad }
    }
    return nil
}

func moveSession(id: String, toPad dest: Int) {
    guard (0..<16).contains(dest) else { return }
    let src = slotForSession[id]
    if let other = slotForSession.first(where: { $0.value == dest && $0.key != id })?.key {
        if let src = src {
            slotForSession[other] = src  // swap
        } else {
            slotForSession.removeValue(forKey: other)
        }
    }
    slotForSession[id] = dest
    if let s = padSlots.compactMap({ $0 }).first(where: { $0.id == id }) {
        homePads[projectName(s.cwd)] = dest  // project home follows manual moves
    }
    saveArrangement()
}

// MARK: - MIDI plumbing

var client = MIDIClientRef()
var outPort = MIDIPortRef()
var inPort = MIDIPortRef()
var quneoOut: MIDIEndpointRef = 0
var quneoIn: MIDIEndpointRef = 0
var connectedIn: MIDIEndpointRef = 0

func displayName(_ obj: MIDIObjectRef) -> String {
    var s: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(obj, kMIDIPropertyDisplayName, &s)
    return (s?.takeRetainedValue() as String?) ?? "?"
}

var lastSent = [UInt8: UInt8]()
func sendNote(_ note: UInt8, _ vel: UInt8) {
    guard quneoOut != 0, lastSent[note] != vel else { return }
    lastSent[note] = vel
    var packetList = MIDIPacketList()
    let packet = MIDIPacketListInit(&packetList)
    let bytes: [UInt8] = [0x90, note, vel]
    _ = MIDIPacketListAdd(&packetList, 1024, packet, 0, bytes.count, bytes)
    MIDISend(outPort, quneoOut, &packetList)
}

var lastCC = [UInt8: UInt8]()
func sendCC(_ cc: UInt8, _ val: UInt8) {
    guard quneoOut != 0, lastCC[cc] != val else { return }
    lastCC[cc] = val
    var packetList = MIDIPacketList()
    let packet = MIDIPacketListInit(&packetList)
    let bytes: [UInt8] = [0xB0, cc, val]
    _ = MIDIPacketListAdd(&packetList, 1024, packet, 0, bytes.count, bytes)
    MIDISend(outPort, quneoOut, &packetList)
}

// Pad i: green LED = note 2i, red LED = note 2i+1 (drum mode, channel 1).
func setPad(_ i: Int, green: UInt8, red: UInt8) {
    sendNote(UInt8(2 * i), green)
    sendNote(UInt8(2 * i + 1), red)
}

func allPadsOff() {
    for i in 0..<16 { setPad(i, green: 0, red: 0) }
}

// Clear pads (notes 0-31), side-button LEDs (33-49), and all slider/rotary
// LEDs (CC1-11) to a known state.
func clearAllLEDs() {
    for n: UInt8 in 0...49 { lastSent[n] = nil; sendNote(n, 0) }
    for c: UInt8 in 1...11 { lastCC[c] = nil; sendCC(c, 0) }
}

// --- System vitals on the horizontal sliders -----------------------------
// The four horizontal sliders (LED fill via CC11 top ... CC8 bottom) show
// CPU, RAM, disk, battery. The long slider (CC5, a positional dot) shows
// the fraction of the day elapsed — a little sun crawling left to right.
var statCPU = 0.0
var statRAM = 0.0
var statDisk = 0.0
var statBattery = 0.0
var statsInFlight = false

func updateSystemStats() {
    guard !statsInFlight else { return }
    statsInFlight = true
    DispatchQueue.global(qos: .utility).async {
        // CPU: sum of per-process %CPU, normalized by core count.
        let cpuSum = runCmd("/bin/ps", ["-A", "-o", "%cpu="])
            .split(separator: "\n")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            .reduce(0, +)
        let cpu = min(1.0, cpuSum / Double(ProcessInfo.processInfo.activeProcessorCount) / 100.0)

        // RAM: (active + wired + compressor) pages / total.
        let vm = runCmd("/usr/bin/vm_stat", [])
        func pages(_ label: String) -> Double {
            guard let r = vm.range(of: "Pages \(label): *(\\d+)", options: .regularExpression)
            else { return 0 }
            return Double(vm[r].split(separator: " ").last.map(String.init) ?? "") ?? 0
        }
        var pageSize = 16384.0
        if let r = vm.range(of: "page size of (\\d+)", options: .regularExpression),
           let p = Double(vm[r].split(separator: " ")[3]) { pageSize = p }
        let memTotal = Double(runCmd("/usr/sbin/sysctl", ["-n", "hw.memsize"])
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let usedBytes = (pages("active") + pages("wired down") + pages("occupied by compressor")) * pageSize
        let ram = memTotal > 0 ? min(1.0, usedBytes / memTotal) : 0

        // Disk: used fraction of /.
        var disk = 0.0
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
           let total = (attrs[.systemSize] as? NSNumber)?.doubleValue,
           let free = (attrs[.systemFreeSize] as? NSNumber)?.doubleValue, total > 0 {
            disk = 1.0 - free / total
        }

        // Battery: pmset (0 on desktops — bottom bar just stays dark).
        var battery = 0.0
        let batt = runCmd("/usr/bin/pmset", ["-g", "batt"])
        if let r = batt.range(of: "(\\d+)%", options: .regularExpression),
           let pct = Double(batt[r].dropLast()) {
            battery = pct / 100.0
        }

        DispatchQueue.main.async {
            statCPU = cpu
            statRAM = ram
            statDisk = disk
            statBattery = battery
            statsInFlight = false
        }
    }
}

func paintSystemStats() {
    func level(_ v: Double) -> UInt8 { UInt8(max(0, min(127, v * 127))) }
    sendCC(11, level(statCPU))
    sendCC(10, level(statRAM))
    sendCC(9, level(statDisk))
    sendCC(8, level(statBattery))
    let midnight = Calendar.current.startOfDay(for: Date())
    let dayFrac = Date().timeIntervalSince(midnight) / 86_400.0
    sendCC(5, level(dayFrac))
}

// The four vertical sliders under the eyes are the deck's pulse (LED fill
// via CC1-4): a slow breathing wave when calm, a VU-style dance that gets
// wilder the more sessions are working, synchronized alarm pumping during
// attention, and a left-to-right swoosh when a turn completes.
struct SliderShow {
    var phase = Double.random(in: 0..<(2 * .pi))
    var levels = [20.0, 20.0, 20.0, 20.0]
    var targets = [20.0, 20.0, 20.0, 20.0]
    var swooshT = -100

    mutating func swoosh(at t: Int) { swooshT = t }

    mutating func step(_ t: Int, working: Int, attention: Bool) {
        if attention {
            let v = t % 5 < 2 ? 120.0 : 25.0
            for i in 0..<4 { levels[i] += (v - levels[i]) * 0.7 }
        } else if t - swooshT < 14 {
            // celebratory wave rolls across the bars, then decays
            let age = Double(t - swooshT)
            for i in 0..<4 {
                let peak = max(0, 1 - abs(age / 2.5 - Double(i) - 1) / 1.6)
                levels[i] += (20 + peak * 105 - levels[i]) * 0.55
            }
        } else if working > 0 {
            let ceiling = 45 + Double(min(working, 4)) * 18
            for i in 0..<4 {
                if Double.random(in: 0..<1) < 0.12 { targets[i] = Double.random(in: 15...ceiling) }
                levels[i] += (targets[i] - levels[i]) * 0.22
            }
        } else {
            phase += 0.045
            for i in 0..<4 {
                let v = 14 + 16 * (0.5 + 0.5 * sin(phase + Double(i) * 0.85))
                levels[i] += (v - levels[i]) * 0.2
            }
        }
        for i in 0..<4 { sendCC(UInt8(1 + i), UInt8(max(0, min(127, levels[i].rounded())))) }
    }
}

func findQuNeo() {
    quneoOut = 0
    quneoIn = 0
    for i in 0..<MIDIGetNumberOfDestinations() {
        let d = MIDIGetDestination(i)
        if displayName(d) == "QuNeo" { quneoOut = d }
    }
    for i in 0..<MIDIGetNumberOfSources() {
        let s = MIDIGetSource(i)
        if displayName(s) == "QuNeo" { quneoIn = s }
    }
    if quneoIn != 0 && quneoIn != connectedIn {
        MIDIPortConnectSource(inPort, quneoIn, nil)
        connectedIn = quneoIn
    }
    if quneoOut != 0 {
        lastSent.removeAll()
        lastCC.removeAll()
    }
}

// Touching the QuNeo makes Local LED Control override our remote values
// and clear them on release — so after any touch, drop the dedup caches
// and let the next tick repaint everything.
func forceRepaint() {
    lastSent.removeAll()
    lastCC.removeAll()
}

func setupMIDI() {
    MIDIClientCreate("quneo-deck" as CFString, nil, nil, &client)
    MIDIOutputPortCreate(client, "deck-out" as CFString, &outPort)
    MIDIInputPortCreateWithBlock(client, "deck-in" as CFString, &inPort) { packetListPtr, _ in
        for packet in packetListPtr.unsafeSequence() {
            let length = Int(packet.pointee.length)
            let bytes = withUnsafeBytes(of: packet.pointee.data) { Array($0.prefix(length)) }
            var i = 0
            while i < bytes.count {
                if bytes[i] & 0xF0 == 0x90, i + 2 < bytes.count {
                    if bytes[i + 2] > 0 {
                        let note = bytes[i + 1]
                        DispatchQueue.main.async { handlePress(note: note) }
                    } else {
                        DispatchQueue.main.async { forceRepaint() }  // finger lifted
                    }
                    i += 3
                } else if bytes[i] & 0xF0 == 0x80 {
                    DispatchQueue.main.async { forceRepaint() }  // finger lifted
                    i += 3
                } else if bytes[i] & 0xF0 == 0xB0, i + 2 < bytes.count {
                    let cc = bytes[i + 1]
                    let val = bytes[i + 2]
                    DispatchQueue.main.async { handleCC(cc, val) }
                    i += 3
                } else if bytes[i] >= 0x80 {
                    i += 3
                } else {
                    i += 1
                }
            }
        }
    }
}

// MARK: - Session state

func loadSessions() -> [Session] {
    let fm = FileManager.default
    guard let files = try? fm.contentsOfDirectory(atPath: stateDir) else { return [] }
    var sessions: [Session] = []
    let now = Date().timeIntervalSince1970
    for f in files where f.hasSuffix(".json") {
        let path = (stateDir as NSString).appendingPathComponent(f)
        guard let data = fm.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["session_id"] as? String,
              let status = obj["status"] as? String
        else { continue }
        let pid = (obj["pid"] as? NSNumber)?.int32Value
        let updated = (obj["updated"] as? NSNumber)?.doubleValue ?? 0
        // Crashed / killed sessions never send SessionEnd: reap dead pids.
        if let pid = pid, kill(pid, 0) != 0 {
            try? fm.removeItem(atPath: path)
            continue
        }
        if pid == nil && now - updated > 86_400 { continue }
        sessions.append(Session(
            id: id, status: status,
            cwd: obj["cwd"] as? String ?? "",
            pid: pid,
            tty: obj["tty"] as? String,
            term: obj["term"] as? String,
            created: (obj["created"] as? NSNumber)?.doubleValue ?? 0,
            updated: updated, path: path,
            agent: obj["agent"] as? String
        ))
    }
    return sessions.sorted { $0.created < $1.created }
}

// --- Remote clusters -----------------------------------------------------
// Sessions on ssh-reachable machines (config.json "remotes": [...]). Every
// 2s the deck runs poll.py on each remote: it reaps dead sessions
// server-side (shared-home clusters: compute-node sessions included) and
// prints the survivors. ControlMaster keeps one persistent connection so
// polls are cheap. Remote status transitions play the sounds locally,
// since the cluster has no speakers worth listening to.
var remoteSessions: [Session] = []
var remotePollInFlight = false
var remotePollFailures = 0
var remoteStatusMemory: [String: String] = [:]

let sshBaseArgs = [
    "-o", "BatchMode=yes", "-o", "ConnectTimeout=4",
    "-o", "ControlMaster=auto", "-o", "ControlPath=~/.ssh/quneo-cm-%r@%h-%p",
    "-o", "ControlPersist=600",
]

func playSound(_ name: String?) {
    guard let name = name, name != "off" else { return }
    let path = "/System/Library/Sounds/\(name).aiff"
    guard FileManager.default.fileExists(atPath: path) else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    p.arguments = [path]
    try? p.run()
}

func playRemoteTransitions(_ sessions: [Session]) {
    let config = deckConfig()
    for s in sessions {
        let prev = remoteStatusMemory[s.id]
        remoteStatusMemory[s.id] = s.status
        guard prev != nil, prev != s.status else { continue }
        switch s.status {
        case "ready":     playSound(config["ready_sound"] as? String ?? "Glass")
        case "attention": playSound(config["attention_sound"] as? String ?? "Submarine")
        default: break
        }
    }
    let ids = Set(sessions.map { $0.id })
    remoteStatusMemory = remoteStatusMemory.filter { ids.contains($0.key) }
}

func pollRemotes() {
    guard !remotePollInFlight,
          let remotes = deckConfig()["remotes"] as? [String], !remotes.isEmpty else { return }
    remotePollInFlight = true
    DispatchQueue.global(qos: .utility).async {
        var collected: [Session] = []
        var failures = 0
        for host in remotes {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = sshBaseArgs + [host, "python3 ~/.quneo-deck/poll.py"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { failures += 1; continue }
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard p.terminationStatus == 0,
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else { failures += 1; continue }
            for obj in arr {
                guard let id = obj["session_id"] as? String,
                      let status = obj["status"] as? String else { continue }
                collected.append(Session(
                    id: id, status: status,
                    cwd: obj["cwd"] as? String ?? "",
                    pid: nil, tty: nil, term: nil,  // remote-only facts, unusable locally
                    created: (obj["created"] as? NSNumber)?.doubleValue ?? 0,
                    updated: (obj["updated"] as? NSNumber)?.doubleValue ?? 0,
                    path: "",
                    remote: host,
                    host: obj["host"] as? String,
                    sshConn: obj["ssh_conn"] as? String
                ))
            }
        }
        DispatchQueue.main.async {
            if failures > 0 && collected.isEmpty {
                remotePollFailures += 1
                if remotePollFailures >= 3 { remoteSessions = [] }  // network gone: clear pads
            } else {
                remotePollFailures = 0
                remoteSessions = collected
                playRemoteTransitions(collected)
            }
            remotePollInFlight = false
        }
    }
}

// --- Codex sessions ------------------------------------------------------
// Codex CLI has no session hooks, so the deck discovers codex processes
// itself: a new pid gets a state file (idle) with the same forensics the
// Claude hook records; CPU-time deltas flip it to working while a turn
// runs; codex's notify hook (codex-notify.py) supplies ready/attention,
// and the pid-based reaper retires the file when codex exits.
var codexCpu: [Int32: Double] = [:]
var codexQuietPolls: [Int32: Int] = [:]

func parseCpuTime(_ s: String) -> Double {
    var total = 0.0
    for part in s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":") {
        total = total * 60 + (Double(part) ?? 0)
    }
    return total
}

func scanCodex() {
    DispatchQueue.global(qos: .utility).async {
        let pids = runCmd("/usr/bin/pgrep", ["-x", "codex"])
            .split(separator: "\n").compactMap { Int32($0) }
        var alive = Set<Int32>()
        for pid in pids {
            alive.insert(pid)
            let path = (stateDir as NSString).appendingPathComponent("codex-\(pid).json")
            var obj: [String: Any]
            if let d = FileManager.default.contents(atPath: path),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                obj = o
            } else {
                var cwd = ""
                for line in runCmd("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"])
                    .split(separator: "\n") where line.hasPrefix("n") {
                    cwd = String(line.dropFirst())
                    break
                }
                let ttyRaw = runCmd("/bin/ps", ["-o", "tty=", "-p", "\(pid)"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                var term: String?
                outer: for p in ancestorPids(of: pid).dropFirst() {
                    let cmd = runCmd("/bin/ps", ["-o", "command=", "-p", "\(p)"])
                    for comp in cmd.split(separator: "/") where comp.hasSuffix(".app") {
                        var name = String(comp.dropLast(4))
                        if let r = name.range(of: " Helper") { name = String(name[..<r.lowerBound]) }
                        term = name
                        break outer
                    }
                }
                let now = Date().timeIntervalSince1970
                obj = ["session_id": "codex-\(pid)", "agent": "codex", "status": "idle",
                       "cwd": cwd, "pid": Int(pid), "created": now, "updated": now]
                if !ttyRaw.isEmpty && !ttyRaw.hasPrefix("?") { obj["tty"] = "/dev/" + ttyRaw }
                if let term = term { obj["term"] = term }
                deckLog("codex discovered: pid \(pid) in \(cwd)")
            }
            let cpu = parseCpuTime(runCmd("/bin/ps", ["-o", "cputime=", "-p", "\(pid)"]))
            let prevCpu = codexCpu[pid]
            codexCpu[pid] = cpu
            let status = obj["status"] as? String ?? "idle"
            if let prevCpu = prevCpu {
                let delta = cpu - prevCpu
                if delta > 0.35, status == "idle" || status == "ready" {
                    obj["status"] = "working"
                    obj["updated"] = Date().timeIntervalSince1970
                    codexQuietPolls[pid] = 0
                } else if status == "working" {
                    // "working" must be able to fall back asleep: without a
                    // turn-complete notify (or before one arrives), ~zero
                    // CPU for 3 polls (6s) reverts to idle.
                    if delta < 0.05 {
                        codexQuietPolls[pid, default: 0] += 1
                        if codexQuietPolls[pid]! >= 3 {
                            obj["status"] = "idle"
                            obj["updated"] = Date().timeIntervalSince1970
                            codexQuietPolls[pid] = 0
                        }
                    } else {
                        codexQuietPolls[pid] = 0
                    }
                }
            }
            if let d = try? JSONSerialization.data(withJSONObject: obj) {
                try? d.write(to: URL(fileURLWithPath: path))
            }
        }
        codexCpu = codexCpu.filter { alive.contains($0.key) }
        codexQuietPolls = codexQuietPolls.filter { alive.contains($0.key) }
    }
}

func acknowledge(_ session: Session) {
    // Bright states go back to dim once you've seen them.
    guard session.status == "ready" || session.status == "attention" else { return }
    if let host = session.remote {
        // Optimistic local dim; poll.py --ack makes it stick remotely.
        remoteStatusMemory[session.id] = "idle"
        remoteSessions = remoteSessions.map { s in
            guard s.id == session.id else { return s }
            return Session(id: s.id, status: "idle", cwd: s.cwd, pid: s.pid, tty: s.tty,
                           term: s.term, created: s.created, updated: s.updated,
                           path: s.path, remote: s.remote, host: s.host)
        }
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = sshBaseArgs + [host, "python3 ~/.quneo-deck/poll.py --ack \(session.id)"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
        }
        return
    }
    guard let data = FileManager.default.contents(atPath: session.path),
          var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return }
    obj["status"] = "idle"
    obj["updated"] = Date().timeIntervalSince1970
    if let out = try? JSONSerialization.data(withJSONObject: obj) {
        try? out.write(to: URL(fileURLWithPath: session.path))
    }
}

// MARK: - Warp tab jumping (Accessibility API)
//
// Warp has no AppleScript tab API, so we walk its accessibility tree
// looking for a tab-like element whose title matches the session's folder
// name, and press it. Needs a one-time Accessibility grant for QuNeoDeck
// (System Settings > Privacy & Security > Accessibility) — the first jump
// attempt triggers the system prompt. Every attempt dumps whatever Warp
// exposes to ~/.quneo-deck/warp-ax.log so the matching can be calibrated.

struct AXNode {
    let el: AXUIElement
    let role: String
    let title: String
    let depth: Int
}

func axAttr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(el, name as CFString, &v)
    return v
}

func axWalk(_ el: AXUIElement, depth: Int = 0, maxDepth: Int = 18, into nodes: inout [AXNode]) {
    guard depth <= maxDepth, nodes.count < 4000 else { return }
    let role = axAttr(el, kAXRoleAttribute) as? String ?? "?"
    let title = (axAttr(el, kAXTitleAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
        ?? axAttr(el, kAXDescriptionAttribute) as? String ?? ""
    nodes.append(AXNode(el: el, role: role, title: title, depth: depth))
    if let children = axAttr(el, kAXChildrenAttribute) as? [AXUIElement] {
        for c in children { axWalk(c, depth: depth + 1, maxDepth: maxDepth, into: &nodes) }
    }
}

func warpApp() -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first {
        $0.bundleIdentifier == "dev.warp.Warp-Stable" || $0.localizedName == "Warp"
    }
}

func warpAXNodes() -> [AXNode] {
    guard let warp = warpApp() else { return [] }
    var nodes: [AXNode] = []
    axWalk(AXUIElementCreateApplication(warp.processIdentifier), into: &nodes)
    return nodes
}

// Set a Warp tab's title by writing the title escape sequence directly to
// the session's tty — the tab renders whatever its pty outputs, marker
// included. (Claude repaints its own topic title on its next update.)
func stampTabTitle(tty: String, title: String) -> Bool {
    let fd = open(tty, O_WRONLY | O_NOCTTY)
    guard fd >= 0 else { return false }
    let seq = "\u{1B}]0;\(title)\u{07}"
    let bytes = Array(seq.utf8)
    let n = write(fd, bytes, bytes.count)
    close(fd)
    return n > 0
}

func pressWarpMenuItem(_ appEl: AXUIElement, barTitle: String, itemTitle: String) -> Bool {
    guard let bar = axAttr(appEl, kAXMenuBarAttribute).map({ $0 as! AXUIElement }),
          let barItems = axAttr(bar, kAXChildrenAttribute) as? [AXUIElement],
          let tabBarItem = barItems.first(where: { axAttr($0, kAXTitleAttribute) as? String == barTitle }),
          let menus = axAttr(tabBarItem, kAXChildrenAttribute) as? [AXUIElement],
          let menu = menus.first,
          let items = axAttr(menu, kAXChildrenAttribute) as? [AXUIElement],
          let item = items.first(where: { axAttr($0, kAXTitleAttribute) as? String == itemTitle })
    else { return false }
    return AXUIElementPerformAction(item, "AXPress" as CFString) == .success
}

// Warp doesn't expose its tab strip to accessibility (GPU-rendered), but
// the window title mirrors the ACTIVE tab's title and menu items are
// pressable. So: stamp the target tab's title with a marker via its tty,
// then cycle "Switch to Next Tab" until the window title shows the marker.
@discardableResult
func jumpToWarpTab(session: Session) -> Bool {
    guard AXIsProcessTrusted() else {
        deckLog("warp jump: AX NOT TRUSTED — re-grant Accessibility to QuNeoDeck")
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        return false
    }
    guard let tty = session.tty, let warp = warpApp() else { return false }
    let name = (session.cwd as NSString).lastPathComponent
    let base = name.isEmpty ? String(session.id.prefix(8)) : name
    // Session-id suffix keeps markers unique even when several sessions
    // share a folder (stale markers from earlier jumps would collide).
    let marker = "◉ \(base) · \(session.id.prefix(4))"
    guard stampTabTitle(tty: tty, title: marker) else { return false }
    usleep(200_000)  // let Warp render the new title

    warp.activate(options: [])
    let appEl = AXUIElementCreateApplication(warp.processIdentifier)

    func markedWindow() -> AXUIElement? {
        guard let windows = axAttr(appEl, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        return windows.first { (axAttr($0, kAXTitleAttribute) as? String ?? "").contains(marker) }
    }

    for hop in 0..<24 {
        if let w = markedWindow() {
            AXUIElementPerformAction(w, "AXRaise" as CFString)
            deckLog("warp jump: found '\(marker)' after \(hop) hops")
            _ = stampTabTitle(tty: tty, title: "◉ \(base)")  // drop the id suffix
            return true
        }
        guard pressWarpMenuItem(appEl, barTitle: "Tab", itemTitle: "Switch to Next Tab") else {
            deckLog("warp jump: menu press failed at hop \(hop)")
            return false
        }
        usleep(140_000)
    }
    deckLog("warp jump: marker '\(marker)' not found after cycling")
    return false
}

@discardableResult
func runAppleScript(_ source: String) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", source]
    do {
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    } catch { return false }
}

// Terminal.app: every tab exposes its tty via AppleScript.
func jumpTerminalApp(tty: String) -> Bool {
    runAppleScript("""
    tell application "Terminal"
        activate
        repeat with w in windows
            repeat with t in tabs of w
                if tty of t is "\(tty)" then
                    set selected tab of w to t
                    set index of w to 1
                    return
                end if
            end repeat
        end repeat
    end tell
    """)
}

// iTerm2: every session exposes its tty via AppleScript.
func jumpITerm(tty: String, appName: String) -> Bool {
    runAppleScript("""
    tell application "\(appName)"
        activate
        repeat with w in windows
            repeat with t in tabs of w
                repeat with s in sessions of t
                    if tty of s is "\(tty)" then
                        select w
                        select t
                        select s
                        return
                    end if
                end repeat
            end repeat
        end repeat
    end tell
    """)
}

// VS Code-family IDEs (VS Code, Cursor, Windsurf...): Electron exposes
// window titles via accessibility, and titles include the workspace folder.
// Raise the window matching the deepest path component of the session's
// cwd — a session in a subfolder still finds its workspace window.
let electronIDEs: Set<String> = [
    "Visual Studio Code", "Code", "Code - Insiders", "VSCodium", "Cursor", "Windsurf",
]

func jumpElectronWindow(term: String, cwd: String) -> Bool {
    guard let app = NSWorkspace.shared.runningApplications.first(where: {
        $0.bundleURL?.lastPathComponent == "\(term).app" || $0.localizedName == term
    }) else {
        deckLog("electron jump: \(term) is not running")
        return false
    }
    // Activation needs no permission — do it before the AX guard so a
    // stale Accessibility grant still fronts the app.
    app.activate(options: [.activateIgnoringOtherApps])
    guard AXIsProcessTrusted() else {
        deckLog("electron jump: AX NOT TRUSTED — re-grant Accessibility to QuNeoDeck")
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        return false
    }
    let appEl = AXUIElementCreateApplication(app.processIdentifier)
    guard let windows = axAttr(appEl, kAXWindowsAttribute) as? [AXUIElement],
          !windows.isEmpty else { return false }
    if windows.count > 1 {
        // Skip home-dir-ish components ("Users", username) — they match
        // nothing useful; a session cwd of ~ can't identify a workspace.
        for comp in cwd.split(separator: "/").map(String.init).reversed() where comp.count > 1 {
            for w in windows {
                let title = axAttr(w, kAXTitleAttribute) as? String ?? ""
                if title.localizedCaseInsensitiveContains(comp) {
                    AXUIElementPerformAction(w, "AXRaise" as CFString)
                    deckLog("electron jump: raised '\(title.prefix(60))' via '\(comp)'")
                    return true
                }
            }
        }
        deckLog("electron jump: no \(term) window matched \(cwd), raising first")
    }
    AXUIElementPerformAction(windows[0], "AXRaise" as CFString)
    deckLog("electron jump: raised \(term) window (\(windows.count) open)")
    return true
}

func runCmd(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    p.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

func ancestorPids(of pid: Int32) -> [Int32] {
    var pids: [Int32] = [pid]
    var cur = pid
    for _ in 0..<10 {
        let out = runCmd("/bin/ps", ["-o", "ppid=", "-p", "\(cur)"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parent = Int32(out), parent > 1 else { break }
        pids.append(parent)
        cur = parent
    }
    return pids
}

// The IDE bridge extension (ide-bridge/) opens one unix socket per VS
// Code/Cursor window. Ask each window whether it owns a terminal whose
// shell is an ancestor of the session's claude process; the owner focuses
// that exact terminal and reports its workspace so we can raise its window.
func jumpViaIDEBridge(_ session: Session) -> Bool {
    guard let pid = session.pid else { return false }
    let dir = NSString(string: "~/.quneo-deck/ide").expandingTildeInPath
    guard let socks = try? FileManager.default.contentsOfDirectory(atPath: dir),
          socks.contains(where: { $0.hasSuffix(".sock") }) else { return false }
    let ancestors = ancestorPids(of: pid).map(String.init).joined(separator: ",")
    let request = "{\"ancestors\": [\(ancestors)]}"
    for sock in socks where sock.hasSuffix(".sock") {
        let out = runCmd("/bin/sh", ["-c",
            "printf '%s\\n' '\(request)' | /usr/bin/nc -U '\(dir)/\(sock)' -w 1"])
        guard let data = out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["ok"] as? Bool == true else { continue }
        let workspace = obj["workspace"] as? String ?? ""
        deckLog("ide bridge: focused terminal '\(obj["terminal"] ?? "?")' in workspace '\(workspace)'")
        if let term = session.term,
           let app = NSWorkspace.shared.runningApplications.first(where: {
               $0.bundleURL?.lastPathComponent == "\(term).app" || $0.localizedName == term
           }) {
            app.activate(options: [.activateIgnoringOtherApps])
            if AXIsProcessTrusted(), !workspace.isEmpty {
                let appEl = AXUIElementCreateApplication(app.processIdentifier)
                if let windows = axAttr(appEl, kAXWindowsAttribute) as? [AXUIElement],
                   let w = windows.first(where: {
                       (axAttr($0, kAXTitleAttribute) as? String ?? "")
                           .localizedCaseInsensitiveContains(workspace)
                   }) {
                    AXUIElementPerformAction(w, "AXRaise" as CFString)
                }
            }
        }
        return true
    }
    return false
}

// When a session first appears, the user almost certainly just typed
// `claude` in the terminal they're looking at — so snapshot the frontmost
// app + focused window at that moment. Jumping later raises exactly that
// window, no cwd inference needed. Works for any transport (local shells,
// multihop ssh) since it only observes the local side.
struct RememberedWindow {
    let appPid: pid_t
    let appName: String
    let el: AXUIElement
    let title: String
}

var sessionWindows: [String: RememberedWindow] = [:]
var knownSessionIds = Set<String>()

func captureWindowsForNewSessions(_ sessions: [Session]) {
    let now = Date().timeIntervalSince1970
    for s in sessions where !knownSessionIds.contains(s.id) {
        knownSessionIds.insert(s.id)
        // Only for genuinely fresh sessions — not ones discovered because
        // this app just (re)started. Remote sessions get a wider window
        // (poll latency + cluster clock skew).
        guard now - s.created < (s.remote != nil ? 60 : 15), AXIsProcessTrusted(),
              let front = NSWorkspace.shared.frontmostApplication else { continue }
        let appEl = AXUIElementCreateApplication(front.processIdentifier)
        guard let winRef = axAttr(appEl, "AXFocusedWindow") else { continue }
        let win = winRef as! AXUIElement
        let title = axAttr(win, kAXTitleAttribute) as? String ?? ""
        sessionWindows[s.id] = RememberedWindow(
            appPid: front.processIdentifier,
            appName: front.localizedName ?? "",
            el: win, title: title
        )
        deckLog("captured window for \(s.id.prefix(8)): \(front.localizedName ?? "?") '\(title.prefix(50))'")
    }
}

// Raise the window remembered for this session, if it still exists.
func jumpRemembered(_ session: Session) -> Bool {
    guard let rw = sessionWindows[session.id],
          let app = NSRunningApplication(processIdentifier: rw.appPid),
          !app.isTerminated else { return false }
    let appEl = AXUIElementCreateApplication(rw.appPid)
    guard let windows = axAttr(appEl, kAXWindowsAttribute) as? [AXUIElement] else { return false }
    var target: AXUIElement?
    if windows.contains(where: { CFEqual($0, rw.el) }) {
        target = rw.el
    } else if !rw.title.isEmpty {
        target = windows.first { (axAttr($0, kAXTitleAttribute) as? String ?? "") == rw.title }
    }
    guard let w = target else { return false }
    app.activate(options: [.activateIgnoringOtherApps])
    AXUIElementPerformAction(w, "AXRaise" as CFString)
    deckLog("jump: raised remembered \(rw.appName) window for \(session.id.prefix(8))")
    return true
}

// Remote sessions carry $SSH_CONNECTION, whose second field is our Mac's
// outgoing TCP port for that ssh link. lsof maps the port to the local ssh
// process, and its ancestry recovers the local tty and host app — so a
// cluster session "localizes" into a session the normal jump dispatch can
// handle with full precision (exact Warp tab, exact Cursor pane). Multihop
// sessions (SSH_CONNECTION pointing at an intermediate host) find no local
// match and fall back to the remembered window.
func localSSHEndpoint(_ session: Session) -> Session? {
    guard let conn = session.sshConn else { return nil }
    let parts = conn.split(separator: " ")
    guard parts.count >= 2, let port = Int(parts[1]) else { return nil }
    let out = runCmd("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:ESTABLISHED", "-Fpn"])
    var sshPid: Int32?
    var current: Int32?
    for line in out.split(separator: "\n") {
        if line.hasPrefix("p") {
            current = Int32(line.dropFirst())
        } else if line.hasPrefix("n"), line.contains(":\(port)->") {
            sshPid = current
            break
        }
    }
    guard let pid = sshPid else {
        deckLog("ssh endpoint: no local process owns port \(port) (multihop?)")
        return nil
    }
    let ttyRaw = runCmd("/bin/ps", ["-o", "tty=", "-p", "\(pid)"])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let tty = (ttyRaw.isEmpty || ttyRaw.hasPrefix("?")) ? nil : "/dev/" + ttyRaw
    var term: String?
    outer: for p in ancestorPids(of: pid) {
        let cmd = runCmd("/bin/ps", ["-o", "command=", "-p", "\(p)"])
        for comp in cmd.split(separator: "/") where comp.hasSuffix(".app") {
            var name = String(comp.dropLast(4))
            if let r = name.range(of: " Helper") { name = String(name[..<r.lowerBound]) }
            term = name
            break outer
        }
    }
    deckLog("ssh endpoint: port \(port) -> ssh pid \(pid), tty \(tty ?? "?"), app \(term ?? "?")")
    return Session(id: session.id, status: session.status, cwd: session.cwd,
                   pid: pid, tty: tty, term: term,
                   created: session.created, updated: session.updated,
                   path: "", remote: nil, host: session.host)
}

// Pad index currently being jumped to — the eyes stare at it while the
// jump is in flight.
var jumpStarePad: Int?

// The per-terminal jump chain, shared by local sessions and localized
// remote ones. Returns whether a precise jump landed.
func dispatchJump(_ s: Session) -> Bool {
    let term = s.term ?? "Warp"
    if term.hasPrefix("iTerm"), let tty = s.tty {
        return jumpITerm(tty: tty, appName: term)
    }
    if term == "Terminal", let tty = s.tty {
        return jumpTerminalApp(tty: tty)
    }
    if term.contains("Warp") {
        // Remembered window narrows multi-window Warp; the tty marker
        // then finds the exact tab.
        _ = jumpRemembered(s)
        warpApp()?.activate(options: [.activateIgnoringOtherApps])
        return jumpToWarpTab(session: s)
    }
    if electronIDEs.contains(term) {
        return jumpViaIDEBridge(s) || jumpRemembered(s)
            || jumpElectronWindow(term: term, cwd: s.cwd)
    }
    if jumpRemembered(s) { return true }
    // Unknown host (kitty, ghostty, ...): at least front it.
    NSWorkspace.shared.runningApplications
        .first { $0.localizedName == term }?
        .activate(options: [.activateIgnoringOtherApps])
    return false
}

func focusSession(_ session: Session) {
    acknowledge(session)
    let name = (session.cwd as NSString).lastPathComponent
    let term = session.term ?? "Warp"
    jumpStarePad = padSlots.firstIndex { $0?.id == session.id }

    // Jumping can take a few seconds (Warp tab cycling) — keep it off the
    // main thread so the menu bar stays responsive.
    DispatchQueue.global(qos: .userInitiated).async {
        defer { DispatchQueue.main.async { jumpStarePad = nil } }
        var jumped = false
        if session.remote != nil {
            // Localize via the SSH_CONNECTION port trick, then dispatch as
            // if the session were local; else fall back to the window
            // remembered when the session first appeared.
            if let localized = localSSHEndpoint(session) {
                jumped = dispatchJump(localized)
            } else {
                jumped = jumpRemembered(session)
            }
        } else {
            jumped = dispatchJump(session)
        }
        let where_ = session.remote.map { "☁️ \(session.host ?? $0)" } ?? term
        let detail = jumped ? "jumped" : "fronted \(where_)"
        let script = """
        display notification "\(session.cwd) — \(session.status) (\(detail))" with title "Claude: \(name)"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }
}

func handlePress(note: UInt8) {
    guard let idx = padNotes.firstIndex(of: note), let session = padSlots[idx] else { return }
    focusSession(session)
}

// MARK: - Eyes

// The two rotaries are eyes: CC6 positions the left pupil, CC7 the right.
// Both chase a shared gaze target (saccades every ~1-3s); the right eye
// lags and jitters a little so they read as googly rather than robotic.
// When any session needs attention the gaze darts side to side instead.
// --- Rotary tap hotkeys --------------------------------------------------
// The eyes are also buttons: tap the left eye = Ctrl+` (Typeless), tap the
// right eye = Return, tap both together = Esc. Gestures are evaluated on
// release (0.18s of silence) so chords win over singles. Touches show up
// as bursts of the rotaries' location CCs.
// Touch detection keys on the rotaries' PRESSURE CCs (4/5): pressure always
// fires on touch, while the location CCs (19/20) are pass-thru gated and
// stay silent for stationary taps.
let rotaryCCs: [UInt8: Int] = [4: 0, 5: 1]  // CC -> rotary index (left, right)
let rotaryKeys: [(name: String, key: CGKeyCode, flags: CGEventFlags)] = [
    ("F13", 105, []),               // left eye — Typeless hotkey (registered via "Add another")
    ("Return", 36, []),             // right eye
]
let chordKey: (name: String, key: CGKeyCode, flags: CGEventFlags) = ("Esc", 53, [])

var rotaryActive = [false, false]
var rotaryParticipated = [false, false]
var rotaryLastSeen = [0.0, 0.0]
var rotaryGestureStart = [0.0, 0.0]
var lastUnknownCCLog = 0.0

// F13 (the Typeless trigger) is posted as a raw CGEvent at the HID entry
// point of the event stream — hotkey listeners that tap at the HID level
// never see session-level synthetic events, but they do see these. F13 is
// safe to double-route because it types nothing in ordinary apps.
func postHIDKey(_ key: CGKeyCode) {
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let ev = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
        ev?.post(tap: .cghidEventTap)
    }
    deckLog("posted HID-level key \(key)")
}

// Inject via System Events rather than raw CGEvent posting: CGEvent fails
// silently under TCC, while osascript reports exactly why it was blocked.
// First use triggers a one-time "control System Events" Automation prompt.
func sendKey(_ key: CGKeyCode, flags: CGEventFlags = []) {
    if key == 105 {  // F13 — see postHIDKey
        postHIDKey(key)
        return
    }
    var mods: [String] = []
    if flags.contains(.maskControl) { mods.append("control") }
    if flags.contains(.maskShift) { mods.append("shift") }
    if flags.contains(.maskCommand) { mods.append("command") }
    if flags.contains(.maskAlternate) { mods.append("option") }
    // Hold the modifiers as real key events (down, then the key, then up)
    // rather than flag-decorating: hotkey listeners that watch physical
    // modifier presses (e.g. Typeless's "Left Ctrl") need the sequence.
    let lines: [String]
    if mods.isEmpty {
        lines = ["key code \(key)"]
    } else {
        lines = mods.map { "key down \($0)" }
            + ["delay 0.04", "key code \(key)", "delay 0.04"]
            + mods.reversed().map { "key up \($0)" }
    }
    let script = "tell application \"System Events\"\n"
        + lines.joined(separator: "\n") + "\nend tell"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    let errPipe = Pipe()
    p.standardError = errPipe
    p.terminationHandler = { proc in
        if proc.terminationStatus != 0 {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            deckLog("sendKey BLOCKED (exit \(proc.terminationStatus)): "
                + err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
    do { try p.run() } catch { deckLog("sendKey: osascript launch failed") }
}

// --- Tentacle arrow keys -------------------------------------------------
// The four vertical sliders (location CCs 11, 1, 19, 20) behave like
// keyboard keys: touching the top third fires Up immediately, the bottom
// third fires Down, the middle is a dead zone. Keep the finger resting and
// the arrow auto-repeats like a held key; lift and it stops. Touch
// presence is inferred from the CC stream (finger tremor keeps it alive),
// so the freshness windows are tuned generously.
let sliderJogCCs: Set<UInt8> = [11, 1, 19, 20]
let tapTopZone = 85.0      // >= this = top third  (quarter would be 96)
let tapBottomZone = 42.0   // <= this = bottom third (quarter would be 32)
let holdRepeatDelay = 0.5    // hold this long before scrolling starts
let holdScrollInterval = 0.1 // one scroll tick per interval while held
let touchTimeout = 0.5       // gesture over this long after the last CC

// Scroll wheel synthesis (used for hold-scrolling; posts at the HID entry
// point like F13, the proven pipe). Positive = scroll up.
func sendScroll(_ direction: Int32) {
    let ev = CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState),
                     units: .line, wheelCount: 1,
                     wheel1: direction, wheel2: 0, wheel3: 0)
    ev?.post(tap: .cghidEventTap)
}

struct SliderGesture {
    var active = false
    var startTime = 0.0
    var lastSeen = 0.0
    var key: CGKeyCode?  // direction fixed at touch-down; nil = dead zone
    var nextRepeat = 0.0
    var scrolling = false
}
var sliderGestures: [UInt8: SliderGesture] = [:]

func handleSliderTouch(_ cc: UInt8, _ value: UInt8) {
    let now = ProcessInfo.processInfo.systemUptime
    if var g = sliderGestures[cc], g.active, now - g.lastSeen < touchTimeout {
        g.lastSeen = now  // continuing touch: keep it alive, zone stays fixed
        sliderGestures[cc] = g
        return
    }
    var g = SliderGesture(active: true, startTime: now, lastSeen: now,
                          key: nil, nextRepeat: now + holdRepeatDelay)
    let v = Double(value)
    if v >= tapTopZone {
        g.key = 126
    } else if v <= tapBottomZone {
        g.key = 125
    }
    sliderGestures[cc] = g
    if let key = g.key {
        sendKey(key)
        deckLog("tentacle \(key == 126 ? "up" : "down") (touch)")
    }
}

func checkSliderHolds() {
    let now = ProcessInfo.processInfo.systemUptime
    for (cc, g) in sliderGestures where g.active {
        if now - g.lastSeen > touchTimeout {
            sliderGestures[cc]!.active = false
            continue
        }
        guard let key = g.key, now >= g.nextRepeat else { continue }
        sliderGestures[cc]!.nextRepeat = now + holdScrollInterval
        if !g.scrolling {
            sliderGestures[cc]!.scrolling = true
            deckLog("tentacle hold: scrolling \(key == 126 ? "up" : "down")")
        }
        sendScroll(key == 126 ? 1 : -1)
    }
}

func handleCC(_ cc: UInt8, _ value: UInt8) {
    if sliderJogCCs.contains(cc) {
        handleSliderTouch(cc, value)
        return
    }
    let now = ProcessInfo.processInfo.systemUptime
    guard let idx = rotaryCCs[cc] else {
        if now - lastUnknownCCLog > 5 {
            lastUnknownCCLog = now
            deckLog("unmapped CC \(cc) from QuNeo")
        }
        return
    }
    if !rotaryActive[idx] {
        rotaryActive[idx] = true
        rotaryParticipated[idx] = true
        rotaryGestureStart[idx] = now
    }
    rotaryLastSeen[idx] = now
}

func checkRotaryGestures() {
    let now = ProcessInfo.processInfo.systemUptime
    for i in 0..<2 where rotaryActive[i] && now - rotaryLastSeen[i] > 0.18 {
        rotaryActive[i] = false
    }
    guard !rotaryActive[0], !rotaryActive[1],
          rotaryParticipated[0] || rotaryParticipated[1] else { return }
    let both = rotaryParticipated[0] && rotaryParticipated[1]
    let leftOnly = rotaryParticipated[0]
    let starts = (0..<2).filter { rotaryParticipated[$0] }.map { rotaryGestureStart[$0] }
    let duration = now - (starts.min() ?? now)
    rotaryParticipated = [false, false]
    forceRepaint()  // touching rotaries invokes local LED override
    guard duration < 1.2 else {
        deckLog("rotary gesture ignored (held \(String(format: "%.1f", duration))s)")
        return
    }
    let action = both ? chordKey : rotaryKeys[leftOnly ? 0 : 1]
    sendKey(action.key, flags: action.flags)
    deckLog("eyes hotkey: \(both ? "chord" : leftOnly ? "left" : "right") -> \(action.name)")
}

// Approximate physical positions on the QuNeo faceplate, in inches,
// origin at the device's bottom-left. Rotaries sit left-center; the 4x4
// pad grid fills the right side (manual: 9.5" x 7.3", pads ~1.2").
let leftRotaryPos = (x: 2.1, y: 3.6)
let rightRotaryPos = (x: 3.4, y: 3.6)

func padCenter(_ i: Int) -> (x: Double, y: Double) {
    let row = Double(i / 4), col = Double(i % 4)
    return (4.85 + col * 1.22, 1.35 + row * 1.22)
}

// Rotary LED ring: assume value 0 at 12 o'clock increasing clockwise.
// (If gaze looks rotated/mirrored on hardware, calibrate here.)
func rotaryValue(from: (x: Double, y: Double), to: (x: Double, y: Double)) -> Double {
    let theta = atan2(to.y - from.y, to.x - from.x)  // CCW from +x axis
    var clock = Double.pi / 2 - theta                 // clockwise from top
    if clock < 0 { clock += 2 * .pi }
    return clock / (2 * .pi) * 128
}

// Per-eye LED values to fixate a pad — each eye computes its own angle,
// so they converge on the target like real eyes.
func stareValues(pad: Int) -> (l: Double, r: Double) {
    (rotaryValue(from: leftRotaryPos, to: padCenter(pad)),
     rotaryValue(from: rightRotaryPos, to: padCenter(pad)))
}

struct Eyes {
    var left = 64.0
    var right = 64.0
    var target = 64.0
    var nextSaccade = 0
    var frantic = false
    var stare: (l: Double, r: Double)?
    var relief: Double?
    var reliefUntil = 0

    private func wrap(_ x: Double) -> Double {
        var v = x.truncatingRemainder(dividingBy: 128)
        if v < 0 { v += 128 }
        return v
    }

    private func approach(_ from: Double, _ to: Double, rate: Double) -> Double {
        var d = (to - from).truncatingRemainder(dividingBy: 128)
        if d > 64 { d -= 128 }
        if d < -64 { d += 128 }
        return wrap(from + d * rate)
    }

    // Called when a stare ends: avert the gaze — drift somewhere roughly
    // opposite the lock, hold it a beat, then resume wandering.
    mutating func lookAway(at t: Int) {
        let away = wrap(left + 64 + Double.random(in: -20...20))
        relief = away
        target = away
        reliefUntil = t + Int.random(in: 12...20)  // 1.2-2s at 10 Hz
        nextSaccade = reliefUntil
    }

    mutating func step(_ t: Int) {
        if let s = stare {
            relief = nil
            // Fixate the target pad, with a nervous micro-jitter.
            left = approach(left, s.l + Double.random(in: -1.5...1.5), rate: 0.5)
            right = approach(right, s.r + Double.random(in: -1.5...1.5), rate: 0.5)
        } else if let r = relief {
            // The slow exhale: relaxed drift away from the released target.
            if t >= reliefUntil { relief = nil }
            left = approach(left, r, rate: 0.12)
            right = approach(right, r + Double.random(in: -2...2), rate: 0.1)
        } else {
            if frantic {
                target = (t / 3) % 2 == 0 ? 24.0 : 104.0
            } else if t >= nextSaccade {
                target = Double.random(in: 0..<128)
                nextSaccade = t + Int.random(in: 10...30)  // 1-3s at 10 Hz
            }
            left = approach(left, target, rate: 0.45)
            right = approach(right, target + Double.random(in: -4...4), rate: 0.3)
        }
        sendCC(6, UInt8(max(0, min(127, left.rounded()))))
        sendCC(7, UInt8(max(0, min(127, right.rounded()))))
    }
}

// MARK: - CLI modes

setupMIDI()
findQuNeo()

if CommandLine.arguments.contains("--test") {
    guard quneoOut != 0 else { print("QuNeo not found — is it plugged in?"); exit(1) }
    print("LED test: green sweep up, red sweep back, orange flash, off.")
    clearAllLEDs()
    for i in 0..<16 { setPad(i, green: 110, red: 0); usleep(90_000); setPad(i, green: 0, red: 0) }
    for i in (0..<16).reversed() { setPad(i, green: 0, red: 110); usleep(90_000); setPad(i, green: 0, red: 0) }
    for i in 0..<16 { setPad(i, green: 127, red: 127) }
    usleep(800_000)
    allPadsOff()
    exit(0)
}

// --ax: dump Warp's accessibility tree (for calibrating tab matching).
if CommandLine.arguments.contains("--ax") {
    if !AXIsProcessTrusted() {
        print("Not AX-trusted in this context — grant Accessibility first.")
    }
    for n in warpAXNodes() where !n.title.isEmpty || n.role.contains("Tab") {
        print("\(String(repeating: "  ", count: n.depth))\(n.role) '\(n.title.prefix(80))'")
    }
    exit(0)
}

if CommandLine.arguments.contains("--eyes") {
    guard quneoOut != 0 else { print("QuNeo not found — is it plugged in?"); exit(1) }
    print("googly eyes: wandering... then a frantic fit... then rest.")
    var eyes = Eyes()
    for t in 0..<150 {
        eyes.frantic = t >= 90 && t < 125
        eyes.step(t)
        usleep(100_000)
    }
    sendCC(6, 0)
    sendCC(7, 0)
    exit(0)
}

// MARK: - Menu bar app

// Drag-and-drop pad arrangement: a 4x4 grid mirroring the QuNeo (top row
// on top), sessions as colored blocks you drag between cells. Dropping on
// an occupied cell swaps. Writes through moveSession, so home pads learn
// from drags exactly like menu moves did.
final class ArrangeView: NSView {
    var dragId: String?
    var dragPoint = NSPoint.zero
    override var isFlipped: Bool { true }

    func padAt(_ point: NSPoint) -> Int? {
        let cw = bounds.width / 4, ch = bounds.height / 4
        guard cw > 0, ch > 0 else { return nil }
        let col = Int(point.x / cw), rowFromTop = Int(point.y / ch)
        guard (0..<4).contains(col), (0..<4).contains(rowFromTop) else { return nil }
        return (3 - rowFromTop) * 4 + col
    }

    func rect(forPad p: Int) -> NSRect {
        let cw = bounds.width / 4, ch = bounds.height / 4
        return NSRect(x: CGFloat(p % 4) * cw, y: CGFloat(3 - p / 4) * ch, width: cw, height: ch)
            .insetBy(dx: 6, dy: 6)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        for p in 0..<16 {
            let r = rect(forPad: p)
            let cell = NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9)
            NSColor.separatorColor.withAlphaComponent(0.25).setFill()
            cell.fill()
            let num = "\(p + 1)"
            num.draw(at: NSPoint(x: r.maxX - 16, y: r.maxY - 16), withAttributes: [
                .font: NSFont.systemFont(ofSize: 9),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ])
            if let s = padSlots[p], s.id != dragId {
                drawBlock(s, in: r)
            }
        }
        if let id = dragId, let s = padSlots.compactMap({ $0 }).first(where: { $0.id == id }) {
            let r = NSRect(x: dragPoint.x - 55, y: dragPoint.y - 28, width: 110, height: 56)
            drawBlock(s, in: r, dragging: true)
        }
    }

    func drawBlock(_ s: Session, in r: NSRect, dragging: Bool = false) {
        let statusColor: [String: NSColor] = [
            "working": .systemGreen, "ready": .systemOrange,
            "attention": .systemRed, "idle": .systemGray,
        ]
        let c = statusColor[s.status] ?? .systemGray
        let block = NSBezierPath(roundedRect: r.insetBy(dx: 4, dy: 4), xRadius: 7, yRadius: 7)
        c.withAlphaComponent(dragging ? 0.8 : 0.3).setFill()
        block.fill()
        c.setStroke()
        block.lineWidth = 2
        block.stroke()
        var name = s.cwd.isEmpty ? String(s.id.prefix(8)) : (s.cwd as NSString).lastPathComponent
        if s.agent == "codex" { name = "⬢ " + name }
        if s.remote != nil { name = "☁️ " + name }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        var size = name.size(withAttributes: attrs)
        let label = size.width > r.width - 16 ? String(name.prefix(12)) + "…" : name
        size = label.size(withAttributes: attrs)
        label.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2 - 6),
                   withAttributes: attrs)
        let sub = s.status
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let subSize = sub.size(withAttributes: subAttrs)
        sub.draw(at: NSPoint(x: r.midX - subSize.width / 2, y: r.midY + 4), withAttributes: subAttrs)
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if let p = padAt(pt), let s = padSlots[p] {
            dragId = s.id
            dragPoint = pt
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragId != nil else { return }
        dragPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragId = nil
            needsDisplay = true
        }
        guard let id = dragId else { return }
        let pt = convert(event.locationInWindow, from: nil)
        if let p = padAt(pt) {
            moveSession(id: id, toPad: p)
            deckLog("arrange: dragged \(id.prefix(8)) to pad \(p + 1)")
        }
    }
}

// Menu bar icon: a tiny QuNeo face — rounded body, four pad dots, and two
// eyes whose pupils track the same gaze as the hardware rotaries. Attention
// state draws them wide-eyed and red. Drawn literally (not a template):
// the status bar restyles template images by menu bar appearance and
// ignores tinting, and this icon must stay white.
func deckIcon(pupilPos: Double, attention: Bool) -> NSImage {
    let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        (attention ? NSColor.systemRed : NSColor.white).set()
        let body = NSBezierPath(roundedRect: NSRect(x: 1.0, y: 2.0, width: 16, height: 14),
                                xRadius: 3.5, yRadius: 3.5)
        body.lineWidth = 1.4
        body.stroke()
        let angle = pupilPos / 128.0 * 2.0 * Double.pi
        for cx in [6.0, 12.0] {
            let r = attention ? 3.6 : 3.0
            let eye = NSBezierPath(ovalIn: NSRect(x: cx - r / 2, y: 10.6 - r / 2, width: r, height: r))
            eye.lineWidth = attention ? 1.2 : 1.0
            eye.stroke()
            let wander = attention ? 0.0 : 0.8
            let px = cx + cos(angle) * wander
            let py = 10.6 + sin(angle) * wander
            let pr = attention ? 1.8 : 1.2
            NSBezierPath(ovalIn: NSRect(x: px - pr / 2, y: py - pr / 2, width: pr, height: pr)).fill()
        }
        for i in 0..<4 {
            NSBezierPath(ovalIn: NSRect(x: 3.4 + Double(i) * 3.1, y: 4.2, width: 1.7, height: 1.7)).fill()
        }
        return true
    }
    img.isTemplate = false
    return img
}

// Shared config, also read by hook.py (which plays the sounds).
let configPath = NSString(string: "~/.quneo-deck/config.json").expandingTildeInPath

func deckConfig() -> [String: Any] {
    guard let d = FileManager.default.contents(atPath: configPath),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    else { return [:] }
    return o
}

func setDeckConfig(_ key: String, _ value: Any) {
    var c = deckConfig()
    c[key] = value
    if let d = try? JSONSerialization.data(withJSONObject: c, options: [.prettyPrinted, .sortedKeys]) {
        try? d.write(to: URL(fileURLWithPath: configPath))
    }
}

func systemSounds() -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? [])
        .filter { $0.hasSuffix(".aiff") }
        .map { ($0 as NSString).deletingPathExtension }
        .sorted()
}

func deckLog(_ msg: String) {
    let path = NSString(string: "~/.quneo-deck/app.log").expandingTildeInPath
    let line = "\(Date()) \(msg)\n"
    if let h = FileHandle(forWritingAtPath: path) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        h.closeFile()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    var eyes = Eyes()
    var sliders = SliderShow()
    var statusMemory: [String: String] = [:]  // for the done-swoosh
    var tick = 0
    var eyeTick = 0
    var paused = false
    var demoRunning = false
    var currentIcon = ""
    var videoMode = false  // solid full-brightness LEDs: no PWM dimming or blinking to flicker on camera

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.delegate = self
        statusItem.menu = menu
        videoMode = deckConfig()["video_mode"] as? Bool ?? false
        loadArrangement()
        updateIcon()
        clearAllLEDs()
        deckLog("started pid=\(ProcessInfo.processInfo.processIdentifier) " +
                "statusItem visible=\(statusItem.isVisible) quneo=\(quneoOut != 0) " +
                "axTrusted=\(AXIsProcessTrusted())")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            deckLog("after 2s: statusItem visible=\(self.statusItem.isVisible) " +
                    "button=\(self.statusItem.button != nil) icon=\(self.currentIcon)")
        }

        let deckTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.deckTick() }
        RunLoop.main.add(deckTimer, forMode: .common)
        let eyeTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            checkRotaryGestures()
            checkSliderHolds()
            self?.eyeStep()
        }
        RunLoop.main.add(eyeTimer, forMode: .common)
    }

    func applicationWillTerminate(_ notification: Notification) {
        allPadsOff()
        for c: UInt8 in 1...11 { sendCC(c, 0) }
    }

    var attention: Bool { padSlots.contains { $0?.status == "attention" } }

    func deckTick() {
        tick += 1
        if quneoOut == 0 { findQuNeo() }
        if tick % 8 == 0 {
            forceRepaint()  // 2s safety net vs. local-LED overrides
            pollRemotes()
            scanCodex()
        }
        if tick % 20 == 1 { updateSystemStats() }  // every 5s
        let sessions = loadSessions() + remoteSessions
        captureWindowsForNewSessions(sessions)
        padSlots = assignPads(sessions)
        for s in sessions {
            if statusMemory[s.id] != nil, statusMemory[s.id] != s.status, s.status == "ready" {
                sliders.swoosh(at: eyeTick)
            }
            statusMemory[s.id] = s.status
        }
        let ids = Set(sessions.map { $0.id })
        statusMemory = statusMemory.filter { ids.contains($0.key) }
        updateIcon()
        guard !demoRunning, !paused, quneoOut != 0 else { return }
        for i in 0..<16 {
            if let s = padSlots[i] {
                let c = colors(for: s.status)
                setPad(i, green: c.green, red: c.red)
            } else {
                setPad(i, green: 0, red: 0)
            }
        }
        paintSystemStats()
    }

    func colors(for status: String) -> (green: UInt8, red: UInt8) {
        if videoMode {
            // Full duty cycle only — brightness 127 or nothing — so no PWM
            // dimming can strobe on camera. Activity shows as a slow
            // green<->orange color swap, not a brightness change.
            switch status {
            case "working":   return tick % 6 < 3 ? (127, 0) : (127, 127)
            case "attention": return (0, 127)
            case "ready":     return (127, 127)
            case "idle":      return (127, 0)
            default:          return (0, 0)
            }
        }
        switch status {
        case "working":   return (tick % 4 < 2 ? 20 : 80, 0)   // green pulse
        case "attention": return (0, tick % 2 == 0 ? 127 : 0)  // red blink
        case "ready":     return (127, 127)                      // solid orange (green+red)
        case "idle":      return (10, 0)                        // dim green
        default:          return (0, 0)
        }
    }

    func eyeStep() {
        guard !demoRunning, !paused, quneoOut != 0 else { return }
        eyeTick += 1
        // Stare priority: pad being jumped to, else the latest unresolved
        // attention pad; otherwise wander.
        var starePad = jumpStarePad
        if starePad == nil {
            var latest: (idx: Int, updated: Double)?
            for (i, s) in padSlots.enumerated() {
                guard let s = s, s.status == "attention" else { continue }
                if latest == nil || s.updated > latest!.updated { latest = (i, s.updated) }
            }
            starePad = latest?.idx
        }
        let wasStaring = eyes.stare != nil
        eyes.stare = starePad.flatMap { $0 < 16 ? stareValues(pad: $0) : nil }
        if wasStaring && eyes.stare == nil { eyes.lookAway(at: eyeTick) }
        eyes.step(eyeTick)
        let workingCount = padSlots.compactMap { $0 }.filter { $0.status == "working" }.count
        sliders.step(eyeTick, working: workingCount, attention: attention)
    }

    func updateIcon() {
        let attn = attention
        let quant = Int(eyes.left / 16) & 7  // 8 pupil directions, avoids churn
        let key = "\(attn)-\(quant)-\(paused)-\(quneoOut == 0)"
        guard key != currentIcon else { return }
        currentIcon = key
        statusItem.button?.image = deckIcon(pupilPos: eyes.left, attention: attn)
        statusItem.button?.appearsDisabled = paused || quneoOut == 0
        statusItem.button?.toolTip = quneoOut == 0 ? "QuNeo Deck — QuNeo not connected"
            : paused ? "QuNeo Deck — paused" : "QuNeo Deck"
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: quneoOut != 0 ? "QuNeo: connected" : "QuNeo: not found",
                     action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        let active = padSlots.enumerated().compactMap { i, s in s.map { (i, $0) } }
        if active.isEmpty {
            menu.addItem(withTitle: "No Claude sessions", action: nil, keyEquivalent: "")
        } else {
            for (i, s) in active {
                let dot = ["working": "🟢", "ready": "🟠", "attention": "🔴", "idle": "⚪️"][s.status] ?? "⚪️"
                var name = s.cwd.isEmpty ? s.id : (s.cwd as NSString).lastPathComponent
                if s.agent == "codex" { name = "⬢ " + name }
                if s.remote != nil { name = "☁️ \(name) @ \(s.host ?? s.remote!)" }
                let item = NSMenuItem(title: "\(dot) \(name) — \(s.status)  ·  pad \(i + 1)",
                                      action: #selector(sessionClicked(_:)), keyEquivalent: "")
                item.target = self
                item.tag = i
                menu.addItem(item)
            }

            let arrange = NSMenuItem(title: "Arrange Pads…", action: #selector(openArrange), keyEquivalent: "")
            arrange.target = self
            menu.addItem(arrange)
        }
        menu.addItem(.separator())

        let pauseItem = NSMenuItem(title: paused ? "Resume LEDs" : "Pause LEDs",
                                   action: #selector(togglePause), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)

        let video = NSMenuItem(title: "Video Mode (solid, no flicker)",
                               action: #selector(toggleVideoMode), keyEquivalent: "")
        video.target = self
        video.state = videoMode ? .on : .off
        menu.addItem(video)

        let sweep = NSMenuItem(title: "Demo: Pad Sweep", action: #selector(runSweep), keyEquivalent: "")
        sweep.target = self
        menu.addItem(sweep)
        let googly = NSMenuItem(title: "Demo: Googly Eyes", action: #selector(runEyes), keyEquivalent: "")
        googly.target = self
        menu.addItem(googly)
        menu.addItem(.separator())

        let config = deckConfig()
        menu.addItem(soundPicker(title: "Done Sound  🟠", key: "ready_sound",
                                 current: config["ready_sound"] as? String ?? "Glass"))
        menu.addItem(soundPicker(title: "Attention Sound  🔴", key: "attention_sound",
                                 current: config["attention_sound"] as? String ?? "Submarine"))
        menu.addItem(.separator())

        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = FileManager.default.fileExists(atPath: agentPlistPath) ? .on : .off
        menu.addItem(login)

        let quit = NSMenuItem(title: "Quit QuNeo Deck", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    func soundPicker(title: String, key: String, current: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for name in ["Off"] + systemSounds() {
            let mi = NSMenuItem(title: name, action: #selector(soundChosen(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = [key, name]
            mi.state = (name == "Off" ? current == "off" : current == name) ? .on : .off
            sub.addItem(mi)
        }
        item.submenu = sub
        return item
    }

    @objc func soundChosen(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        let value = pair[1] == "Off" ? "off" : pair[1]
        setDeckConfig(pair[0], value)
        if value != "off" {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            p.arguments = ["/System/Library/Sounds/\(value).aiff"]
            try? p.run()  // preview
        }
    }

    @objc func sessionClicked(_ sender: NSMenuItem) {
        guard sender.tag < padSlots.count, let session = padSlots[sender.tag] else { return }
        focusSession(session)
    }

    var arrangePanel: NSPanel?

    @objc func openArrange() {
        if arrangePanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 420),
                                styleMask: [.titled, .closable, .utilityWindow],
                                backing: .buffered, defer: false)
            panel.title = "Arrange Pads — drag blocks (top row = top of QuNeo)"
            panel.level = .floating
            panel.isReleasedWhenClosed = false
            let view = ArrangeView(frame: panel.contentLayoutRect)
            view.autoresizingMask = [.width, .height]
            panel.contentView = view
            arrangePanel = panel
            let refresh = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let panel = self?.arrangePanel, panel.isVisible else { return }
                panel.contentView?.needsDisplay = true
            }
            RunLoop.main.add(refresh, forMode: .common)
        }
        arrangePanel?.center()
        arrangePanel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func toggleVideoMode() {
        videoMode.toggle()
        setDeckConfig("video_mode", videoMode)
        forceRepaint()
    }

    @objc func togglePause() {
        paused.toggle()
        if paused { clearAllLEDs() } else { lastSent.removeAll(); lastCC.removeAll() }
        updateIcon()
    }

    // Demos run as a subprocess of this same binary (--test / --eyes) so
    // their timing loops can't block the app; LEDs repaint when they exit.
    func runDemo(_ flag: String) {
        guard !demoRunning, let bin = Bundle.main.executablePath else { return }
        demoRunning = true
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = [flag]
        p.terminationHandler = { _ in
            DispatchQueue.main.async {
                lastSent.removeAll()
                lastCC.removeAll()
                self.demoRunning = false
            }
        }
        do { try p.run() } catch { demoRunning = false }
    }

    @objc func runSweep() { runDemo("--test") }
    @objc func runEyes() { runDemo("--eyes") }

    @objc func toggleLogin() {
        let fm = FileManager.default
        if fm.fileExists(atPath: agentPlistPath) {
            try? fm.removeItem(atPath: agentPlistPath)
        } else if let bin = Bundle.main.executablePath {
            let plist: [String: Any] = [
                "Label": "com.quneo.agentdeck",
                "ProgramArguments": [bin],
                "RunAtLoad": true,
            ]
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try? data.write(to: URL(fileURLWithPath: agentPlistPath))
            }
        }
    }

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
