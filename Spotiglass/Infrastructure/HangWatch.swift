import AppKit
import Darwin
import Foundation

/// Says in the log when the main thread is blocked (#734): a line with how long, what it was
/// doing (a sample of its stack taken while it was stuck), the calls running and the interaction
/// before it. A timer on a background queue sends the main queue a block every ``interval`` and
/// notes when it runs; when one is still waiting after ``threshold``, the timer pauses the main
/// thread for the few microseconds a stack sample takes and reads its frames, and samples again
/// every second it stays stuck. Nothing here ever waits: the timer only looks at the clock.
///
/// While Wax isn't the active app the app's watch looks once a second instead of ten times: a
/// background app shouldn't wake that often for nothing, and a hang there (at launch, or while
/// a song changes with Wax behind other windows) still gets its line. At that pace a block
/// shorter than a second can fall between two looks and go unseen, and a caught one is measured
/// from the look before it, so it may read a little short.
final class HangWatch: @unchecked Sendable {
    static let shared = HangWatch()

    /// A main thread blocked longer than this gets a line.
    static let threshold: TimeInterval = 0.25
    /// How often the timer looks, and the main queue is sent a block when none is waiting.
    static let interval: TimeInterval = 0.1
    /// How often it looks while the app isn't active.
    static let backgroundInterval: TimeInterval = 1
    /// Stack samples kept per hang: one at the threshold, then one a second.
    static let maxSamples = 4
    /// A hang still going after this long gets a line right away too: someone waiting that long
    /// may quit the app, and the line written when the hang ends would never come.
    static let stillBlockedAfter: TimeInterval = 2
    static let maxFrames = 48

    private let write: (String) -> Void
    private let threshold: TimeInterval
    private let stillBlockedAfter: TimeInterval
    private let backgroundInterval: TimeInterval
    private let queue = DispatchQueue(label: "com.isaaclins.spotiglass.hangwatch", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var mainThread: thread_act_t = 0

    // Only touched on `queue`.
    /// When the block now waiting for the main queue was sent.
    private var sentAt: TimeInterval?
    private var hang: Hang?
    private var inBackground = false
    private var observers: [NSObjectProtocol] = []

    private struct Hang {
        var samples: [(at: TimeInterval, frames: [String])]
        var lastSampleAt: TimeInterval
        let interaction: CallLog.Interaction?
        let calls: String
        var reportedWhileBlocked = false
    }

    /// Filled while the main thread is paused, so the sampler allocates nothing then (the main
    /// thread may hold the allocator's lock).
    private let frames = UnsafeMutablePointer<UInt>.allocate(capacity: HangWatch.maxFrames)

    init(
        threshold: TimeInterval = HangWatch.threshold,
        stillBlockedAfter: TimeInterval = HangWatch.stillBlockedAfter,
        backgroundInterval: TimeInterval = HangWatch.backgroundInterval,
        write: @escaping (String) -> Void = { SpotiglassLog.error(.performance, $0) }
    ) {
        self.threshold = threshold
        self.stillBlockedAfter = stillBlockedAfter
        self.backgroundInterval = backgroundInterval
        self.write = write
    }

    /// Starts watching. Call on the main thread; later calls do nothing. With
    /// `followingAppActivity` the watch looks less often while the app isn't active.
    func start(followingAppActivity: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard timer == nil else { return }
        mainThread = mach_thread_self()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.interval, leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
        guard followingAppActivity else { return }
        let center = NotificationCenter.default
        for (name, active) in [
            (NSApplication.didBecomeActiveNotification, true), (NSApplication.didResignActiveNotification, false),
        ] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                    self?.setInBackground(!active)
                })
        }
        // A Wax opened behind other windows starts at the slower pace.
        if !NSApplication.shared.isActive { setInBackground(true) }
    }

    private func setInBackground(_ background: Bool) {
        queue.async { [self] in
            guard let timer, background != inBackground else { return }
            inBackground = background
            // A hang being watched carries on: only the pace changes.
            let interval = background ? backgroundInterval : Self.interval
            timer.schedule(
                deadline: .now() + interval, repeating: interval, leeway: .milliseconds(background ? 100 : 10))
        }
    }

    /// Stops watching. The app's watch runs for its lifetime; tests stop theirs.
    // periphery:ignore
    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        queue.sync { timer?.cancel() }
        timer = nil
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func tick() {
        let now = now
        guard let sentAt else {
            sentAt = now
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let ranAt = self.now
                self.queue.async { self.answered(at: ranAt) }
            }
            return
        }
        let waited = now - sentAt
        guard waited >= threshold else { return }
        if var hang {
            if hang.samples.count < Self.maxSamples, now - hang.lastSampleAt >= 1 {
                hang.samples.append((waited, sampleMainThread()))
                hang.lastSampleAt = now
            }
            if !hang.reportedWhileBlocked, waited >= stillBlockedAfter {
                hang.reportedWhileBlocked = true
                write(line(hang, sentAt: sentAt, blocked: waited, ended: false))
            }
            self.hang = hang
        } else {
            hang = Hang(
                samples: [(waited, sampleMainThread())],
                lastSampleAt: now,
                interaction: CallLog.lastInteraction,
                calls: CallLog.runningSummary()
            )
        }
    }

    private func answered(at ranAt: TimeInterval) {
        guard let sentAt else { return }
        self.sentAt = nil
        let blocked = ranAt - sentAt
        defer { hang = nil }
        guard blocked >= threshold else { return }
        write(line(hang, sentAt: sentAt, blocked: blocked, ended: true))
    }

    private func line(_ hang: Hang?, sentAt: TimeInterval, blocked: TimeInterval, ended: Bool) -> String {
        // A block shorter than the timer's step can end before a sample was taken.
        let calls = hang?.calls ?? CallLog.runningSummary()
        var line =
            ended
            ? "MAIN THREAD BLOCKED for \(CallLog.milliseconds(blocked)); \(calls)"
            : "MAIN THREAD STILL BLOCKED after \(CallLog.milliseconds(blocked)) (a line follows when it ends); \(calls)"
        if let interaction = hang?.interaction ?? CallLog.lastInteraction {
            line +=
                "; last interaction #\(interaction.id) \(interaction.label) \(CallLog.seconds(max(0, sentAt - interaction.at))) before it began"
        }
        let samples = hang?.samples ?? []
        if samples.isEmpty { line += "\n  (it ended before a stack sample was taken)" }
        for sample in samples {
            line += "\n  main thread stack at \(CallLog.milliseconds(sample.at)):"
            line += sample.frames.isEmpty ? "\n    (could not read it)" : sample.frames.map { "\n    \($0)" }.joined()
        }
        return line
    }

    /// The main thread's frames, innermost first, symbolized after it runs again.
    private func sampleMainThread() -> [String] {
        let count = readMainThreadFrames()
        return (0..<count).map { Self.symbolize(frames[$0]) }
    }

    /// Pauses the main thread, walks its frame pointers into ``frames`` and lets it go again.
    /// Nothing in between allocates or takes a lock.
    private func readMainThreadFrames() -> Int {
        guard thread_suspend(mainThread) == KERN_SUCCESS else { return 0 }
        defer { thread_resume(mainThread) }
        var count = 0
        var framePointer: UInt = 0
        #if arch(arm64)
            var state = arm_thread_state64_t()
            var stateCount = mach_msg_type_number_t(
                MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &state) {
                $0.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
                    thread_get_state(mainThread, ARM_THREAD_STATE64, $0, &stateCount)
                }
            }
            guard result == KERN_SUCCESS else { return 0 }
            frames[0] = Self.strip(UInt(state.__pc))
            frames[1] = Self.strip(UInt(state.__lr))
            count = 2
            framePointer = UInt(state.__fp)
        #elseif arch(x86_64)
            var state = x86_thread_state64_t()
            var stateCount = mach_msg_type_number_t(
                MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &state) {
                $0.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
                    thread_get_state(mainThread, x86_THREAD_STATE64, $0, &stateCount)
                }
            }
            guard result == KERN_SUCCESS else { return 0 }
            frames[0] = UInt(state.__rip)
            count = 1
            framePointer = UInt(state.__rbp)
        #endif
        // Each frame starts with the caller's frame pointer and the return address.
        var pair: (UInt, UInt) = (0, 0)
        while count < Self.maxFrames, framePointer != 0, framePointer & 0x7 == 0 {
            var read: vm_size_t = 0
            let status = withUnsafeMutablePointer(to: &pair) { pointer in
                vm_read_overwrite(
                    mach_task_self_,
                    vm_address_t(framePointer),
                    vm_size_t(MemoryLayout<(UInt, UInt)>.size),
                    vm_address_t(UInt(bitPattern: pointer)),
                    &read
                )
            }
            guard status == KERN_SUCCESS else { break }
            let returnAddress = Self.strip(pair.1)
            guard returnAddress != 0 else { break }
            frames[count] = returnAddress
            count += 1
            guard pair.0 > framePointer else { break }
            framePointer = pair.0
        }
        return count
    }

    /// A return address without its pointer signature.
    private static func strip(_ address: UInt) -> UInt {
        address & 0x0000_7FFF_FFFF_FFFF
    }

    private typealias Demangle =
        @convention(c) (
            UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32
        ) -> UnsafeMutablePointer<CChar>?

    private static let demangle: Demangle? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle")
        .map { unsafeBitCast($0, to: Demangle.self) }

    /// "Wax +0x12a4 PlaybackSessionViewModel.refresh() + 88": the image, the offset in it (enough
    /// to symbolize a stripped build against its dSYM) and the nearest symbol.
    static func symbolize(_ address: UInt) -> String {
        var info = Dl_info()
        // A return address points after the call; one byte back is inside it.
        guard address > 0, dladdr(UnsafeRawPointer(bitPattern: address - 1), &info) != 0 else {
            return String(format: "0x%lx", address)
        }
        let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
        let base = UInt(bitPattern: info.dli_fbase)
        var text = "\(image) +0x\(String(address - base, radix: 16))"
        if let symbolName = info.dli_sname {
            var symbol = String(cString: symbolName)
            if let demangle, let demangled = demangle(symbolName, strlen(symbolName), nil, nil, 0) {
                symbol = String(cString: demangled)
                free(demangled)
            }
            text += " \(symbol) + \(address - UInt(bitPattern: info.dli_saddr))"
        }
        return text
    }
}

/// Memory and CPU once a minute while something plays (#734), so a slowdown over a long session
/// shows as growth in the log.
@MainActor
final class ResourceLog {
    static let shared = ResourceLog()
    static let interval: TimeInterval = 60

    private let write: (String) -> Void
    /// Off under the unit-test host, where sessions play stand-ins.
    private let isEnabled: Bool
    private var playing: Set<ObjectIdentifier> = []
    private var timer: Timer?
    private var last: (cpu: TimeInterval, at: TimeInterval)?

    init(
        isEnabled: Bool = !AppMetadata.isRunningUnitTests,
        write: @escaping (String) -> Void = { SpotiglassLog.info(.performance, $0) }
    ) {
        self.isEnabled = isEnabled
        self.write = write
    }

    /// A player session says whether it plays.
    func session(_ session: AnyObject, isPlaying: Bool) {
        let id = ObjectIdentifier(session)
        let changed = isPlaying ? playing.insert(id).inserted : playing.remove(id) != nil
        guard changed, isEnabled else { return }
        if playing.isEmpty {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            sample()
            timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sample() }
            }
        }
    }

    func sample() {
        let now = ProcessInfo.processInfo.systemUptime
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Self.seconds(usage.ru_utime) + Self.seconds(usage.ru_stime)
        let cpuShare =
            last.map { previous in
                String(
                    format: "%.1f%% of one core over the last %.0f s",
                    (cpu - previous.cpu) / max(now - previous.at, 0.001) * 100, now - previous.at)
            } ?? "first sample"
        last = (cpu, now)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let memory =
            status == KERN_SUCCESS
            ? String(
                format: "%.1f MB in use (peak %.1f MB)", Double(info.phys_footprint) / 1_048_576,
                Double(info.ledger_phys_footprint_peak) / 1_048_576)
            : "memory unknown"
        write("resources while playing: \(memory), CPU \(cpuShare)")
    }

    private static func seconds(_ time: timeval) -> TimeInterval {
        TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000
    }
}
