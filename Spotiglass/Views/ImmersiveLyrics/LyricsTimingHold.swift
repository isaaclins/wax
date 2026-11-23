import SwiftUI

/// Fixing a song's lyric timing by hand (#640): hold the lyrics with a right click, drag the line
/// being sung into the highlight in the middle, let go. While the hold lasts the lyrics stop
/// following the music and move under the fixed highlight, one line at a time.
@MainActor
@Observable
final class LyricsTimingHold {
    struct Session: Equatable {
        let songID: String
        let lines: [SyncedLyricLine]
        /// The line the lyrics showed when the hold started.
        let startIndex: Int
        var heldIndex: Int
        /// The song's shift when the hold started.
        let savedOffsetMs: Int
        /// Drag not yet worth a whole line.
        var leftoverPoints: CGFloat = 0
    }

    private(set) var session: Session?

    /// Where the song is now, without any shift: what letting go would make the held line's start.
    @ObservationIgnored private(set) var rawPositionMs: () -> Int = { 0 }

    /// Starts holding at the line the lyrics show right now. Without timed lines nothing starts.
    @discardableResult
    func begin(
        songID: String,
        lines: [SyncedLyricLine],
        savedOffsetMs: Int,
        rawPositionMs: @escaping () -> Int
    ) -> Bool {
        guard !lines.isEmpty else { return false }
        let effectivePositionMs = LrcLineParser.effectivePositionMs(positionMs: rawPositionMs(), offsetMs: savedOffsetMs)
        let index = LrcLineParser.activeTimedLineIndex(positionMs: effectivePositionMs, lines: lines)
        self.rawPositionMs = rawPositionMs
        session = Session(
            songID: songID,
            lines: lines,
            startIndex: index,
            heldIndex: index,
            savedOffsetMs: savedOffsetMs
        )
        return true
    }

    /// Moves the lyrics `points` up (later lines come into the highlight; negative moves them
    /// down). Returns how many lines the highlight moved.
    func drag(contentUpBy points: CGFloat, linePitch: CGFloat) -> Int {
        guard var session, linePitch > 0 else { return 0 }
        session.leftoverPoints += points
        let steps = Int((session.leftoverPoints / linePitch).rounded(.towardZero))
        let target = min(max(session.heldIndex + steps, 0), session.lines.count - 1)
        let moved = target - session.heldIndex
        session.heldIndex = target
        if moved == steps {
            session.leftoverPoints -= CGFloat(steps) * linePitch
        } else {
            // Past the first or last line the extra drag is dropped, so dragging back moves at once.
            session.leftoverPoints = 0
        }
        self.session = session
        return moved
    }

    /// Ends the hold. Returns the song and the shift that makes the held line start at
    /// `rawPositionMs`, or nil when the highlight is still on the line it started on.
    func finish(rawPositionMs: Int) -> (songID: String, offsetMs: Int)? {
        guard let session else { return nil }
        self.session = nil
        guard session.heldIndex != session.startIndex else { return nil }
        return (session.songID, session.lines[session.heldIndex].startTimeMs - rawPositionMs)
    }

    func cancel() {
        session = nil
    }

    /// "Lyrics 2.1 s sooner" / "Lyrics 0.4 s later", or "Original timing" near zero.
    static func label(forShiftMs shiftMs: Int) -> String {
        let tenths = Int((Double(abs(shiftMs)) / 100).rounded())
        guard tenths > 0 else { return SpotiglassL10n.string("lyrics.timing.original") }
        let seconds = String(format: "%.1f", Double(tenths) / 10)
        let key = shiftMs > 0 ? "lyrics.timing.sooner" : "lyrics.timing.later"
        return String(format: SpotiglassL10n.string(key), seconds)
    }
}

private struct LyricsTimingHoldKey: EnvironmentKey {
    static let defaultValue: LyricsTimingHold? = nil
}

extension EnvironmentValues {
    /// The hold of the lyrics view around this one, if it offers one.
    var lyricsTimingHold: LyricsTimingHold? {
        get { self[LyricsTimingHoldKey.self] }
        set { self[LyricsTimingHoldKey.self] = newValue }
    }
}

/// Turns right-button and key events on the lyrics into a hold: a press held for a moment or
/// dragged starts it, a release saves the line in the highlight as "now", Esc cancels, and a
/// short click on a song with a saved shift offers to reset it.
@MainActor
final class LyricsTimingHoldInput {
    /// What the lyrics on screen are, read when an event needs it.
    struct Context {
        let songID: String
        let lines: [SyncedLyricLine]
        let savedOffsetMs: Int
        /// The song's position now, without any shift.
        let rawPositionMs: () -> Int
        /// Drag that moves the lyrics by one line.
        let linePitch: CGFloat
    }

    /// Points are in window coordinates (y grows upwards).
    enum Event: Equatable {
        case rightDown(CGPoint, inside: Bool)
        case rightDragged(CGPoint)
        case rightUp(CGPoint)
        /// A scroll's vertical delta as the system reports it: positive moves content down.
        case scroll(deltaY: CGFloat, precise: Bool)
        case escape
    }

    private enum Phase: Equatable {
        case idle
        case pressed(start: CGPoint, last: CGPoint)
        case holding(last: CGPoint)
        /// The hold was cancelled with the button still down: its release does nothing.
        case ignoringUntilUp
    }

    static let holdDelay: Duration = .milliseconds(250)
    static let dragSlop: CGFloat = 4

    let hold: LyricsTimingHold
    let store: LyricsTimingStore
    var context: () -> Context?
    var showResetMenu: (_ point: CGPoint, _ songID: String) -> Void = { _, _ in }
    private let haptics: any LyricsHaptics
    private let clock: any PlaybackClock
    private var pressTask: Task<Void, Never>?
    private var phase: Phase = .idle {
        didSet {
            switch (oldValue == .idle, phase == .idle) {
            case (true, false): Self.pressesInProgress += 1
            case (false, true): Self.pressesInProgress -= 1
            default: break
            }
        }
    }

    private static var pressesInProgress = 0

    /// While the lyrics are held (or the right button is still down after a cancel), Esc is the
    /// hold's: the app's own Escape handling (closing the lyrics) leaves it alone.
    static var isHoldInProgress: Bool { pressesInProgress > 0 }

    init(
        hold: LyricsTimingHold,
        store: LyricsTimingStore,
        haptics: any LyricsHaptics,
        clock: any PlaybackClock = ContinuousClock(),
        context: @escaping () -> Context? = { nil }
    ) {
        self.hold = hold
        self.store = store
        self.haptics = haptics
        self.clock = clock
        self.context = context
    }

    /// Handles one event; true when it was the hold's and must not go on to the window.
    func handle(_ event: Event) -> Bool {
        switch (event, phase) {
        case let (.rightDown(point, inside), .idle):
            guard inside, context() != nil else { return false }
            phase = .pressed(start: point, last: point)
            schedulePressTimer()
            return true
        case let (.rightDragged(point), .pressed(start, _)):
            phase = .pressed(start: start, last: point)
            if hypot(point.x - start.x, point.y - start.y) > Self.dragSlop {
                beginHold()
                dragHold(contentUpBy: point.y - start.y, to: point)
            }
            return true
        case let (.rightDragged(point), .holding(last)):
            dragHold(contentUpBy: point.y - last.y, to: point)
            return true
        case let (.scroll(deltaY, precise), .holding(last)):
            let pitch = context()?.linePitch ?? 0
            dragHold(contentUpBy: -deltaY * (precise ? 1 : pitch), to: last)
            return true
        case let (.rightUp(point), .pressed):
            endPress()
            if let songID = context()?.songID, store.hasShift(for: songID) {
                showResetMenu(point, songID)
            }
            return true
        case (.rightUp, .holding):
            phase = .idle
            if let raw = context()?.rawPositionMs(), let result = hold.finish(rawPositionMs: raw) {
                store.setOffset(result.offsetMs, for: result.songID)
                haptics.saved()
            } else {
                hold.cancel()
            }
            return true
        case (.rightUp, .ignoringUntilUp):
            phase = .idle
            return true
        case (.escape, .pressed), (.escape, .holding):
            cancel(buttonStillDown: true)
            return true
        case (.rightDragged, .ignoringUntilUp), (.scroll, .ignoringUntilUp):
            return true
        default:
            return false
        }
    }

    /// The song changed, the lyrics went away or the app lost focus: the hold ends unsaved.
    func cancel(buttonStillDown: Bool) {
        guard phase != .idle else { return }
        pressTask?.cancel()
        pressTask = nil
        hold.cancel()
        phase = buttonStillDown ? .ignoringUntilUp : .idle
    }

    private func endPress() {
        pressTask?.cancel()
        pressTask = nil
        phase = .idle
    }

    private func schedulePressTimer() {
        pressTask?.cancel()
        let deadline = clock.now.advanced(by: Self.holdDelay)
        pressTask = Task { [weak self, clock] in
            try? await clock.sleep(until: deadline, tolerance: nil)
            guard !Task.isCancelled else { return }
            self?.beginHold()
        }
    }

    private func beginHold() {
        guard case let .pressed(_, last) = phase else { return }
        pressTask?.cancel()
        pressTask = nil
        guard let context = context(),
              hold.begin(
                  songID: context.songID,
                  lines: context.lines,
                  savedOffsetMs: context.savedOffsetMs,
                  rawPositionMs: context.rawPositionMs
              )
        else {
            phase = .ignoringUntilUp
            return
        }
        phase = .holding(last: last)
        haptics.holdStarted()
    }

    private func dragHold(contentUpBy points: CGFloat, to point: CGPoint) {
        guard case .holding = phase else { return }
        phase = .holding(last: point)
        let pitch = context()?.linePitch ?? 0
        if hold.drag(contentUpBy: points, linePitch: pitch) != 0 {
            haptics.lineChanged()
        }
    }
}
