// Log every MIDI message the QuNeo sends, one line each, flushed immediately.
import CoreMIDI
import Foundation

setbuf(stdout, nil)

func displayName(_ obj: MIDIObjectRef) -> String {
    var s: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(obj, kMIDIPropertyDisplayName, &s)
    return (s?.takeRetainedValue() as String?) ?? "?"
}

var client = MIDIClientRef()
MIDIClientCreate("midispy" as CFString, nil, nil, &client)

let start = Date()
func stamp() -> String { String(format: "%8.3f", Date().timeIntervalSince(start)) }

func describe(_ bytes: [UInt8]) {
    var i = 0
    while i < bytes.count {
        let b = bytes[i]
        guard b >= 0x80 else { i += 1; continue }
        let type = b & 0xF0
        let ch = (b & 0x0F) + 1
        switch type {
        case 0x90 where i + 2 < bytes.count:
            let kind = bytes[i + 2] > 0 ? "note-on " : "note-off"
            print("\(stamp())  \(kind) ch\(ch) note=\(bytes[i + 1]) vel=\(bytes[i + 2])")
            i += 3
        case 0x80 where i + 2 < bytes.count:
            print("\(stamp())  note-off ch\(ch) note=\(bytes[i + 1]) vel=\(bytes[i + 2])")
            i += 3
        case 0xB0 where i + 2 < bytes.count:
            print("\(stamp())  cc       ch\(ch) cc=\(bytes[i + 1]) val=\(bytes[i + 2])")
            i += 3
        case 0xC0, 0xD0:
            i += 2
        default:
            i += 3
        }
    }
}

var inPort = MIDIPortRef()
MIDIInputPortCreateWithBlock(client, "spy-in" as CFString, &inPort) { packetListPtr, _ in
    for packet in packetListPtr.unsafeSequence() {
        let length = Int(packet.pointee.length)
        let bytes = withUnsafeBytes(of: packet.pointee.data) { Array($0.prefix(length)) }
        describe(bytes)
    }
}

var found = false
for i in 0..<MIDIGetNumberOfSources() {
    let s = MIDIGetSource(i)
    if displayName(s) == "QuNeo" {
        MIDIPortConnectSource(inPort, s, nil)
        found = true
    }
}
guard found else { print("QuNeo source not found"); exit(1) }

print("listening to QuNeo — press things!")
RunLoop.main.run()
