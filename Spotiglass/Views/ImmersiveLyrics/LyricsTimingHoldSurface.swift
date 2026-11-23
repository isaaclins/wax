import AppKit
import SwiftUI

extension View {
    /// Lets the lyrics of the playing song be held with a right click and dragged to fix their
    /// timing (#640), anywhere in this view. Only timed lyrics can be held.
    func lyricsTimingHold(
        playbackViewModel: PlaybackSessionViewModel,
        songID: String?,
        lyrics: FetchedLyrics?,
        textSize: LyricsTextMetrics,
        store: LyricsTimingStore = .shared,
        haptics: any LyricsHaptics = TrackpadLyricsHaptics.shared,
        clock: any PlaybackClock = ContinuousClock()
    ) -> some View {
        modifier(LyricsTimingHoldModifier(
            playbackViewModel: playbackViewModel,
            songID: songID,
            lyrics: lyrics,
            textSize: textSize,
            store: store,
            haptics: haptics,
            clock: clock
        ))
    }
}

private struct LyricsTimingHoldModifier: ViewModifier {
    let playbackViewModel: PlaybackSessionViewModel
    let songID: String?
    let lyrics: FetchedLyrics?
    let textSize: LyricsTextMetrics
    let store: LyricsTimingStore
    let haptics: any LyricsHaptics
    let clock: any PlaybackClock

    @State private var hold = LyricsTimingHold()
    @State private var input: LyricsTimingHoldInput?

    func body(content: Content) -> some View {
        content
            .environment(\.lyricsTimingHold, hold)
            .background {
                if let input {
                    LyricsTimingHoldSurface(input: input)
                }
            }
            .onAppear {
                input = LyricsTimingHoldInput(hold: hold, store: store, haptics: haptics, clock: clock)
                updateContext()
            }
            .onChange(of: songID) { _, _ in
                // The lyrics on screen belong to the old song: nothing is saved.
                input?.cancel(buttonStillDown: true)
                updateContext()
            }
            .onChange(of: lyrics) { _, _ in
                input?.cancel(buttonStillDown: true)
                updateContext()
            }
            .onChange(of: textSize) { _, _ in updateContext() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                input?.cancel(buttonStillDown: false)
            }
    }

    private func updateContext() {
        let songID = songID
        let lines: [SyncedLyricLine]? = if case let .synced(lines)? = lyrics, !lines.isEmpty { lines } else { nil }
        let pitch = textSize.inactiveFontSize * 1.25 + textSize.timedLineSpacing
        let store = store
        let playbackViewModel = playbackViewModel
        input?.context = {
            guard let songID, let lines else { return nil }
            return LyricsTimingHoldInput.Context(
                songID: songID,
                lines: lines,
                savedOffsetMs: store.offsetMs(for: songID),
                rawPositionMs: { LyricsPlaybackPosition.rawMs(playbackViewModel: playbackViewModel) },
                linePitch: pitch
            )
        }
    }
}

/// The short right click's menu on lyrics with a saved shift.
@MainActor
enum LyricsTimingResetMenu {
    static func makeMenu(songID: String, store: LyricsTimingStore) -> NSMenu {
        let menu = NSMenu()
        let item = NSMenuItem(
            title: SpotiglassL10n.string("lyrics.timing.reset"),
            action: #selector(LyricsTimingResetTarget.reset),
            keyEquivalent: ""
        )
        let target = LyricsTimingResetTarget(songID: songID, store: store)
        item.target = target
        // A menu item holds its target weakly; the item keeps it alive through its payload.
        item.representedObject = target
        menu.addItem(item)
        return menu
    }
}

@MainActor
final class LyricsTimingResetTarget: NSObject {
    let songID: String
    let store: LyricsTimingStore

    init(songID: String, store: LyricsTimingStore) {
        self.songID = songID
        self.store = store
    }

    @objc func reset() {
        store.reset(for: songID)
    }
}

/// Watches the window's right-button, scroll and Esc events for the hold. It takes no clicks
/// itself: everything else in the lyrics keeps working as before.
struct LyricsTimingHoldSurface: NSViewRepresentable {
    let input: LyricsTimingHoldInput

    func makeNSView(context: Context) -> LyricsTimingHoldView {
        LyricsTimingHoldView(input: input)
    }

    func updateNSView(_ view: LyricsTimingHoldView, context: Context) {
        guard view.input !== input else { return }
        view.input = input
        view.connectResetMenu()
    }

    static func dismantleNSView(_ view: LyricsTimingHoldView, coordinator: ()) {
        view.stopMonitoring()
    }
}

final class LyricsTimingHoldView: NSView {
    var input: LyricsTimingHoldInput
    private var monitor: Any?

    static let escapeKeyCode: UInt16 = 53
    static let monitoredEvents: NSEvent.EventTypeMask = [
        .rightMouseDown, .rightMouseDragged, .rightMouseUp, .scrollWheel, .keyDown,
    ]

    /// The reset menu on its way to the screen.
    private(set) var resetMenu: NSMenu?

    init(input: LyricsTimingHoldInput) {
        self.input = input
        super.init(frame: .zero)
        connectResetMenu()
    }

    /// Shows the reset menu from this view, where the right click was.
    func connectResetMenu() {
        let store = input.store
        input.showResetMenu = { [weak self] point, songID in
            guard let self else { return }
            resetMenu = LyricsTimingResetMenu.makeMenu(songID: songID, store: store)
            let location = convert(point, from: nil)
            // Not from inside the event monitor that reported the click.
            DispatchQueue.main.async { [weak self] in
                guard let self, let resetMenu, window?.isVisible == true else { return }
                resetMenu.popUp(positioning: nil, at: location, in: self)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopMonitoring()
        } else if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: Self.monitoredEvents) { [weak self] event in
                guard let self else { return event }
                return MainActor.assumeIsolated { self.route(event) }
            }
        }
    }

    func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        input.cancel(buttonStillDown: false)
    }

    /// The event to pass on, or nil when the hold took it.
    func route(_ event: NSEvent) -> NSEvent? {
        guard let holdEvent = holdEvent(for: event) else { return event }
        return input.handle(holdEvent) ? nil : event
    }

    func holdEvent(for event: NSEvent) -> LyricsTimingHoldInput.Event? {
        switch event.type {
        case .rightMouseDown:
            guard event.window === window, !isHiddenOrHasHiddenAncestor else { return nil }
            let inside = bounds.contains(convert(event.locationInWindow, from: nil))
            return .rightDown(event.locationInWindow, inside: inside)
        case .rightMouseDragged:
            guard event.window === window else { return nil }
            return .rightDragged(event.locationInWindow)
        case .rightMouseUp:
            guard event.window === window else { return nil }
            return .rightUp(event.locationInWindow)
        case .scrollWheel:
            // Scrolling in another window stays that window's.
            guard event.window === window else { return nil }
            return .scroll(deltaY: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas)
        case .keyDown where event.keyCode == Self.escapeKeyCode:
            return .escape
        default:
            return nil
        }
    }
}
