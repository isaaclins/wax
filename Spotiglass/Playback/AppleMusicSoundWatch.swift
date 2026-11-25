import Foundation

/// Says in the playback log how long Apple Music's player took to start or stop after a command
/// (#679): resume, skip, a new queue, pause.
///
/// MusicKit plays through a system service outside the app (`RemotePlayerService`), so the app
/// can't hear the sound itself. It can see the player's position: a start counts once the
/// position moves (on the new song, when the command changes the song), a stop once it holds
/// still. Measured on a Mac mini M4 (docs/latency.md), the sound follows that position by roughly
/// another 30-200 ms, which the player service adds on its way to the speakers.
@MainActor
final class AppleMusicSoundWatch {
    /// What the watch reads from the player each time it looks.
    struct Reading: Equatable {
        let positionSeconds: TimeInterval
        /// The current queue entry, to tell a new song from the one before.
        let entryID: String?
        let isPlaying: Bool
    }

    enum Wait: Equatable {
        /// The position moves on the song that was current when the command went out.
        case moves
        /// The position moves on another song (a skip, a new queue).
        case movesOnAnotherSong
        /// The position holds still.
        case holdsStill
    }

    /// How often the watch looks while it waits.
    static let interval: Duration = .milliseconds(5)
    /// A position unchanged this long counts as held still: MusicKit's position runs on its own
    /// clock and changes on every read while it plays.
    static let stillAfter: Duration = .milliseconds(20)
    /// The watch gives up after this long and says so.
    static let limit: Duration = .seconds(10)

    private let clock: any PlaybackClock
    private let read: @MainActor () -> Reading
    private let report: @MainActor (String) -> Void
    private var watch: Task<Void, Never>?

    init(
        clock: any PlaybackClock = ContinuousClock(),
        read: @escaping @MainActor () -> Reading,
        report: @escaping @MainActor (String) -> Void = { PlaybackTrace.shared.sound($0) }
    ) {
        self.clock = clock
        self.read = read
        self.report = report
    }

    /// What the player shows now, to hand to ``watch(_:for:sentAt:before:requestedAt:)`` when the
    /// command has to finish before the watch starts (a new queue).
    func readNow() -> Reading {
        read()
    }

    /// `command` went out at `sentAt`; `before` is what the player showed then (read now when
    /// `nil`), and `requestedAt` the press behind it, when there was one. A newer command replaces
    /// a watch still waiting.
    func watch(
        _ command: String,
        for wait: Wait,
        sentAt: ContinuousClock.Instant,
        before: Reading? = nil,
        requestedAt: ContinuousClock.Instant? = nil
    ) {
        watch?.cancel()
        let before = before ?? read()
        watch = Task { @MainActor [weak self] in
            await self?.run(command, wait: wait, before: before, sentAt: sentAt, requestedAt: requestedAt)
        }
    }

    /// The player was stopped: nothing is waited for any more.
    func cancel() {
        watch?.cancel()
        watch = nil
    }

    private func run(
        _ command: String,
        wait: Wait,
        before: Reading,
        sentAt: ContinuousClock.Instant,
        requestedAt: ContinuousClock.Instant?
    ) async {
        var last = before
        // When the position last changed, and the first position seen on the song it waits for.
        var changedAt = sentAt
        var firstOnSong: TimeInterval? = wait == .movesOnAnotherSong ? nil : before.positionSeconds
        let deadline = sentAt.advanced(by: Self.limit)
        var next = clock.now
        while !Task.isCancelled {
            next = next.advanced(by: Self.interval)
            do {
                try await clock.sleep(until: next, tolerance: nil)
            } catch is CancellationError {
                // A newer command, or the player stopped.
                return
            } catch {
                SpotiglassLog.error(.playback, "sound watch for \(command) stopped: \(error)")
                return
            }
            guard !Task.isCancelled else { return }
            let now = clock.now
            let reading = read()
            defer { last = reading }
            switch wait {
            case .moves, .movesOnAnotherSong:
                guard wait == .moves || reading.entryID != before.entryID else { break }
                guard let first = firstOnSong else {
                    firstOnSong = reading.positionSeconds
                    break
                }
                if reading.isPlaying, reading.positionSeconds > first {
                    finish(command, "playing", at: now, sentAt: sentAt, requestedAt: requestedAt)
                    return
                }
            case .holdsStill:
                if reading.positionSeconds != last.positionSeconds {
                    changedAt = now
                } else if changedAt.duration(to: now) >= Self.stillAfter {
                    // It stopped when the position last changed, not when the watch noticed.
                    finish(command, "stopped", at: changedAt, sentAt: sentAt, requestedAt: requestedAt)
                    return
                }
            }
            if now >= deadline {
                report("\(command): not \(wait == .holdsStill ? "stopped" : "playing") \(PlaybackTrace.seconds(sentAt.duration(to: now))) after the command")
                return
            }
        }
    }

    private func finish(
        _ command: String,
        _ what: String,
        at instant: ContinuousClock.Instant,
        sentAt: ContinuousClock.Instant,
        requestedAt: ContinuousClock.Instant?
    ) {
        var line = "\(command): \(what) \(PlaybackTrace.milliseconds(sentAt.duration(to: instant))) after the command"
        if let requestedAt {
            line += ", \(PlaybackTrace.milliseconds(requestedAt.duration(to: instant))) after the press"
        }
        report(line)
    }
}
