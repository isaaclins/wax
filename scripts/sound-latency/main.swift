// Press-to-sound for Wax's transport (#679): presses play/pause, next and previous in the running
// app and times, from each press, when the Mac's audio output goes silent or makes sound again.
//
// A measuring tool for a developer's Mac, never part of the app: it listens to the Mac's audio
// output through a Core Audio process tap, which the app itself must never use
// (scripts/eq-mic-permission-audit.sh). The tap hears the output before the volume and mute are
// applied, so it works with the Mac muted. The first run asks for "System Audio Recording"
// permission for the terminal (or ssh) that runs it.
//
// Built and run by scripts/sound-latency.sh; see docs/latency.md.

import AppKit
import AudioToolbox
import CoreAudio
import Foundation

struct Options {
    var pid: pid_t = 0
    var rounds = 6
    var only: Set<String> = []
}

func parse() -> Options {
    var options = Options()
    var args = CommandLine.arguments.dropFirst()
    while let arg = args.popFirst() {
        switch arg {
        case "--pid": options.pid = pid_t(args.popFirst() ?? "") ?? 0
        case "--rounds": options.rounds = Int(args.popFirst() ?? "") ?? options.rounds
        case "--only": options.only = Set((args.popFirst() ?? "").split(separator: ",").map(String.init))
        default:
            FileHandle.standardError.write("usage: sound-latency --pid <Wax pid> [--rounds N] [--only pause,resume,next,previous]\n".data(using: .utf8)!)
            exit(2)
        }
    }
    guard options.pid > 0 else {
        FileHandle.standardError.write("sound-latency: --pid is required\n".data(using: .utf8)!)
        exit(2)
    }
    return options
}

func milliseconds(hostTime: UInt64) -> Double {
    var timebase = mach_timebase_info()
    mach_timebase_info(&timebase)
    return Double(hostTime) * Double(timebase.numer) / Double(timebase.denom) / 1e6
}

func nowMilliseconds() -> Double { milliseconds(hostTime: mach_absolute_time()) }

/// The output's loudest sample per IO cycle, with the cycle's time.
final class OutputListener {
    private let lock = NSLock()
    private var cycles: [(at: Double, peak: Float)] = []
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?

    func start() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tap), "create the tap")
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Wax sound latency",
            kAudioAggregateDeviceUIDKey: "wax-sound-latency-\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "create the listening device")
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, device, DispatchQueue(label: "sound-latency")) { [weak self] _, input, inputTime, _, _ in
            var peak: Float = 0
            for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
                guard let data = buffer.mData else { continue }
                let samples = data.assumingMemoryBound(to: Float.self)
                for index in 0..<(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size) {
                    peak = max(peak, abs(samples[index]))
                }
            }
            let at = milliseconds(hostTime: inputTime.pointee.mHostTime)
            self?.lock.withLock { self?.cycles.append((at, peak)) }
        }, "listen")
        try check(AudioDeviceStart(device, proc), "start listening")
    }

    func stop() {
        if let proc {
            AudioDeviceStop(device, proc)
            AudioDeviceDestroyIOProcID(device, proc)
        }
        AudioHardwareDestroyAggregateDevice(device)
        AudioHardwareDestroyProcessTap(tap)
    }

    func cycles(from start: Double) -> [(at: Double, peak: Float)] {
        lock.withLock { cycles.filter { $0.at >= start } }
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw NSError(domain: "sound-latency", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "couldn't \(what) (\(status))"]) }
    }
}

enum Press: String, CaseIterable {
    case pause, resume, next, previous

    /// Wax's shortcuts: Space plays and pauses, ⇧⌘→ and ⇧⌘← skip.
    var key: (code: CGKeyCode, flags: CGEventFlags) {
        switch self {
        case .pause, .resume: (49, [])
        case .next: (124, [.maskCommand, .maskShift])
        case .previous: (123, [.maskCommand, .maskShift])
        }
    }

    /// Whether the press ends in silence (pause) or in sound (the rest).
    var endsSilent: Bool { self == .pause }
    /// A skip stops the song that plays before the next one sounds.
    var stopsFirst: Bool { self == .next || self == .previous }
}

func press(_ press: Press, pid: pid_t) -> Double {
    let source = CGEventSource(stateID: .privateState)
    let (code, flags) = press.key
    let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
    down?.flags = flags
    up?.flags = flags
    let at = nowMilliseconds()
    down?.postToPid(pid)
    up?.postToPid(pid)
    return at
}

/// Milliseconds from the press to the sound it asked for, or nil when it never came.
func measure(_ press: Press, pressedAt: Double, cycles: [(at: Double, peak: Float)]) -> Double? {
    if press.endsSilent {
        return cycles.first { $0.peak == 0 }.map { $0.at - pressedAt }
    }
    var rest = cycles[...]
    if press.stopsFirst {
        guard let silent = rest.firstIndex(where: { $0.peak == 0 }) else { return nil }
        rest = rest[silent...]
    }
    return rest.first { $0.peak > 0 }.map { $0.at - pressedAt }
}

func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
}

let options = parse()
let listener = OutputListener()
do {
    try listener.start()
} catch {
    FileHandle.standardError.write("sound-latency: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
defer { listener.stop() }

func settle(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

settle(0.5)
guard listener.cycles(from: nowMilliseconds() - 400).contains(where: { $0.peak > 0 }) else {
    FileHandle.standardError.write("sound-latency: nothing is playing. Start a playlist in Wax first (the Mac may stay muted).\n".data(using: .utf8)!)
    exit(1)
}

var results: [Press: [Double?]] = [:]
let sequence: [(Press, Double)] = [(.pause, 1.2), (.resume, 2.0), (.next, 2.5), (.previous, 2.5)]
for round in 1...options.rounds {
    for (kind, wait) in sequence {
        let at = press(kind, pid: options.pid)
        settle(wait)
        guard options.only.isEmpty || options.only.contains(kind.rawValue) else { continue }
        let ms = measure(kind, pressedAt: at, cycles: listener.cycles(from: at))
        results[kind, default: []].append(ms)
        print("round \(round) \(kind.rawValue): \(ms.map { String(format: "%.0f ms", $0) } ?? "no change heard")")
    }
}

print("")
print("press-to-sound, \(options.rounds) rounds (median, fastest, slowest):")
for kind in Press.allCases {
    guard let all = results[kind] else { continue }
    let heard = all.compactMap { $0 }
    guard !heard.isEmpty else {
        print("  \(kind.rawValue): never heard")
        continue
    }
    let missed = all.count - heard.count
    print(String(format: "  %@: %.0f ms, %.0f, %.0f", kind.rawValue, median(heard), heard.min()!, heard.max()!)
        + (missed > 0 ? " (\(missed) not heard)" : ""))
}
