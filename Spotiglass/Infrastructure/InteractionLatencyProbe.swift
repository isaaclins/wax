import AppKit
import QuartzCore

/// Drives the real app through every interaction in ``InteractionLatencyProbe/steps`` and times
/// each one from the input to the first frame that shows it (#656). It runs only in screenshot
/// mode with ``InteractionLatency/environmentKey`` set (`scripts/latency-test.sh` does both), writes
/// an ``InteractionLatency/Report`` and quits the app.
///
/// Inputs are real events: keys and clicks are posted to the app's own event queue, so they go
/// through the same local key monitors, menu key equivalents and hit testing as a press on the
/// keyboard or trackpad. The window server step before that is left out.
///
/// The end of an interaction is the first Core Animation commit after which the state the screen
/// draws from has changed (the player says playing, the palette is open, the list has scrolled).
/// SwiftUI updates the views from that state before the commit, so the commit carries the new
/// frame; it reaches the display at the next refresh, which is added to every time. A main thread
/// that is busy after the input (#645: 50-610 ms rebuilding track rows) delays that commit, so it
/// counts in full.
@MainActor
final class InteractionLatencyProbe {
    private static var running: InteractionLatencyProbe?

    /// Starts the probe once, for the first main window, when the run asked for it.
    static func startIfRequested(scene: SpotiglassSceneHost, playbackHosts: SpotiglassPlaybackHosts) {
        guard running == nil,
            let reportURL = InteractionLatency.reportURL(
                in: ProcessInfo.processInfo.environment,
                screenshotModeActive: ScreenshotMode.isActive
            )
        else { return }
        let probe = InteractionLatencyProbe(reportURL: reportURL, scene: scene, playbackHosts: playbackHosts)
        running = probe
        Task { await probe.run() }
    }

    /// Set by `scripts/latency-test.sh --only <ids>`: comma-separated step ids to run.
    private static let onlyEnvironmentKey = "WAX_LATENCY_ONLY"
    /// How many times each interaction is tried. Even, so a toggle (sidebar, queue, lyrics,
    /// play/pause) ends the way it started and the next interaction finds the window as it was.
    private static let tries = 8
    /// How long a try may take before it counts as never shown.
    private static let timeoutSeconds = 3.0
    /// Quiet time before each try, so one try's follow-up work (an animation, a reply from the
    /// player) doesn't land in the next one's time.
    private static let settleSeconds = 0.35

    private let reportURL: URL
    private let scene: SpotiglassSceneHost
    private let playbackHosts: SpotiglassPlaybackHosts
    private var pending: PendingFrame?

    private init(reportURL: URL, scene: SpotiglassSceneHost, playbackHosts: SpotiglassPlaybackHosts) {
        self.reportURL = reportURL
        self.scene = scene
        self.playbackHosts = playbackHosts
    }

    // MARK: - What the app shows

    private var playback: PlaybackSessionViewModel { playbackHosts.spotify.playbackViewModel }
    private var palette: CommandPaletteViewModel { scene.commandPaletteManager.viewModel }
    private var browser: PlaylistBrowserViewModel? { scene.existingBrowserViewModel(for: .spotify) }
    private var window: NSWindow? { scene.window }

    private var isPlaying: Bool {
        if case .playing = playback.connectionState { return true }
        return false
    }

    private var nowPlayingURI: String? {
        switch playback.connectionState {
        case let .playing(song): song.uri
        case let .paused(song): song?.uri
        default: nil
        }
    }

    private var position: Int {
        switch playback.connectionState {
        case let .playing(song): song.positionMilliseconds
        case let .paused(song): song?.positionMilliseconds ?? 0
        default: 0
        }
    }

    // MARK: - The interactions

    /// One interaction: what to do and how to tell that it showed. `start` runs before each try
    /// and returns the check for that try, so a toggle checks for the opposite of what it found.
    private struct Step {
        let id: String
        let title: String
        /// Runs untimed before each try; `false` skips the try (the app isn't where it must be).
        var prepare: (InteractionLatencyProbe) async -> Bool = { _ in true }
        /// Sends the input and returns the check that turns true once the result is on screen.
        let start: (InteractionLatencyProbe) -> (() -> Bool)?
        /// Runs untimed after each try, to put the app back.
        var finish: (InteractionLatencyProbe) async -> Void = { _ in }
    }

    private static var steps: [Step] {
        [
            Step(id: "playback.toggle.key", title: "Space pauses or resumes") { probe in
                let wasPlaying = probe.isPlaying
                probe.press(.space)
                return { probe.isPlaying != wasPlaying }
            },
            Step(id: "playback.toggle.click", title: "Click the play/pause button") { probe in
                let wasPlaying = probe.isPlaying
                guard probe.click(label: [SpotiglassL10n.string("playback.pause"), SpotiglassL10n.string("playback.play")])
                else { return nil }
                return { probe.isPlaying != wasPlaying }
            },
            Step(
                id: "playback.next",
                title: "⇧⌘→ skips to the next song",
                prepare: { await $0.waitUntil { !$0.playback.isSkipCommandPending } },
                start: { probe in
                    let uri = probe.nowPlayingURI
                    probe.press(.rightArrow, [.command, .shift])
                    return { probe.playback.isSkipCommandPending || probe.nowPlayingURI != uri }
                },
                // The app holds further skips until the player confirms this one. The sample
                // player never confirms a skip sent through the Web API, so the probe ends the wait
                // the confirmation would end; otherwise only the first try could skip.
                finish: { probe in
                    _ = await probe.waitUntil { !$0.playback.isSkipCommandPending }
                    probe.playback.clearPendingSkipCommand()
                }
            ),
            Step(
                id: "playback.previous",
                title: "⇧⌘← goes back a song",
                prepare: { await $0.waitUntil { !$0.playback.isSkipCommandPending } },
                start: { probe in
                    let uri = probe.nowPlayingURI
                    probe.press(.leftArrow, [.command, .shift])
                    return { probe.playback.isSkipCommandPending || probe.nowPlayingURI != uri }
                }
            ),
            Step(id: "playback.seek", title: "⌘→ jumps ahead in the song") { probe in
                let anchor = probe.playback.progressAnchor
                probe.press(.rightArrow, [.command])
                return { probe.playback.progressAnchor != anchor && probe.position != 0 }
            },
            Step(id: "playback.shuffle", title: "⌥⌘S turns shuffle on or off") { probe in
                let was = probe.playback.shuffleEnabled
                probe.press(.s, [.command, .option])
                return { probe.playback.shuffleEnabled != was }
            },
            Step(id: "playback.repeat", title: "⌥⌘R changes repeat") { probe in
                let was = probe.playback.repeatMode
                probe.press(.r, [.command, .option])
                return { probe.playback.repeatMode != was }
            },
            Step(
                id: "palette.open",
                title: "⌘K opens the command palette",
                start: { probe in
                    probe.press(.k, [.command])
                    return { probe.palette.isPresented }
                },
                finish: { probe in
                    probe.press(.escape)
                    _ = await probe.waitUntil { !$0.palette.isPresented }
                }
            ),
            Step(
                id: "palette.type",
                title: "Typing a letter in the palette",
                prepare: { probe in
                    if !probe.palette.isPresented { probe.press(.k, [.command]) }
                    guard await probe.waitUntil({ $0.palette.isPresented }) else { return false }
                    // Untimed: the last try's letter goes, so this one types into an empty field.
                    if !probe.palette.query.isEmpty { probe.palette.query = "" }
                    return await probe.waitUntil { $0.palette.query.isEmpty }
                },
                start: { probe in
                    probe.press(.m)
                    return { probe.palette.query == "m" }
                }
            ),
            Step(
                id: "palette.close",
                title: "Esc closes the command palette",
                prepare: { probe in
                    if !probe.palette.isPresented { probe.press(.k, [.command]) }
                    return await probe.waitUntil { $0.palette.isPresented }
                },
                start: { probe in
                    probe.press(.escape)
                    return { !probe.palette.isPresented }
                }
            ),
            Step(id: "sidebar.toggle", title: "⌘S hides or shows the sidebar") { probe in
                guard let browser = probe.browser else { return nil }
                let was = browser.isSidebarShown
                probe.press(.s, [.command])
                return { browser.isSidebarShown != was }
            },
            Step(id: "queue.toggle", title: "⌥⌘Q opens or closes the queue") { probe in
                let was = StoredFlag.queuePanelVisible.isOn
                probe.press(.q, [.command, .option])
                return { StoredFlag.queuePanelVisible.isOn != was }
            },
            Step(id: "lyrics.toggle", title: "⌥⌘L opens or closes the lyrics") { probe in
                let lyrics = probe.scene.lyricsOverlayController
                let was = lyrics.isPresented
                probe.press(.l, [.command, .option])
                return { lyrics.isPresented != was }
            },
            Step(
                id: "page.search",
                title: "⌘F opens Search",
                prepare: { await $0.showPage(.home) },
                start: { probe in
                    probe.press(.f, [.command])
                    return { probe.browser?.sidebarSelection == .search }
                }
            ),
            Step(
                id: "page.back",
                title: "⌘[ goes back a page",
                prepare: { probe in
                    guard await probe.showPage(.home) else { return false }
                    probe.press(.f, [.command])
                    return await probe.waitUntil { $0.browser?.sidebarSelection == .search && $0.browser?.canNavigateBack == true }
                },
                start: { probe in
                    probe.press(.leftBracket, [.command])
                    return { probe.browser?.sidebarSelection != .search }
                }
            ),
            Step(
                id: "page.sidebarClick",
                title: "Click a playlist in the sidebar",
                prepare: { probe in
                    guard await probe.showPage(.home), let row = probe.sidebarPlaylistRow() else { return false }
                    row.list.scrollRowToVisible(row.index)
                    return true
                },
                start: { probe in
                    guard let browser = probe.browser, let row = probe.sidebarPlaylistRow() else { return nil }
                    let rect = row.list.rect(ofRow: row.index)
                    probe.click(at: row.list.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil))
                    return {
                        if case .playlist = browser.sidebarSelection { return true }
                        return false
                    }
                }
            ),
            Step(
                id: "list.scroll",
                title: "Scrolling a long playlist",
                prepare: { await $0.showLongPlaylist() },
                start: { probe in probe.scrollTrackList() }
            ),
            Step(
                id: "settings.open",
                title: "⌘, opens Settings",
                start: { probe in
                    probe.press(.comma, [.command])
                    return { Self.isSettingsWindow(NSApp.keyWindow) }
                },
                finish: { probe in
                    NSApp.keyWindow.map { if Self.isSettingsWindow($0) { $0.close() } }
                    probe.window?.makeKeyAndOrderFront(nil)
                    _ = await probe.waitUntil { NSApp.keyWindow === $0.window }
                }
            ),
        ]
    }

    /// The playlist `mock_spotify.py --long-playlist` adds, for scrolling.
    private static let longPlaylist = "Long Mix"

    private static func isSettingsWindow(_ window: NSWindow?) -> Bool {
        // SwiftUI names it com_apple_SwiftUI_Settings_window. (The main window's identifier spells
        // out its view types, SpotiglassSettingsStore among them, so a bare "Settings" won't do.)
        window?.identifier?.rawValue.contains("Settings_window") == true
    }

    // MARK: - Running

    private func run() async {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        #if DEBUG
            let configuration = "Debug"
        #else
            let configuration = "Release"
        #endif
        installCommitObserver()
        let frame = 1000.0 / Double(max(NSScreen.main?.maximumFramesPerSecond ?? 60, 1))
        var measurements: [InteractionLatency.Measurement] = []
        var setupFailure: String?

        if await waitUntil(timeout: 90, { $0.isReady }) {
            // Keys reach the window and the menu bar only while the app is active. Launched from a
            // script it may start behind another app, and a polite activate() can be turned down.
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            await waitUntil(timeout: 5) { _ in NSApp.isActive }
            // The launch script places the window and the library finishes loading its artwork.
            try? await Task.sleep(for: .seconds(6))  // try?: only cancelled when the app quits
            let only = Set(
                (ProcessInfo.processInfo.environment[Self.onlyEnvironmentKey] ?? "")
                    .split(separator: ",").map { String($0) }
            )
            for step in Self.steps where only.isEmpty || only.contains(step.id) {
                measurements.append(await measure(step, frameMilliseconds: frame))
            }
        } else {
            setupFailure = "the library or the player never became ready (window: \(window != nil), "
                + "playlists: \(browser.map { "\($0.playlistState)" } ?? "none"), player: \(playback.connectionState))"
        }

        let report = InteractionLatency.Report(
            appVersion: version,
            configuration: configuration,
            frameMilliseconds: frame,
            measurements: measurements,
            setupFailure: setupFailure
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: reportURL, options: .atomic)
        } catch {
            SpotiglassLog.error(.persistence, "Latency probe could not write its report: \(error)")
        }
        for line in report.summaryLines() { SpotiglassLog.info(.persistence, "latency: \(line)") }
        NSApp.terminate(nil)
    }

    /// What the app shows now, for a try that went wrong.
    private var stateDescription: String {
        let key = NSApp.keyWindow.map { $0 === window ? "main" : ($0.identifier?.rawValue ?? "\(type(of: $0))") } ?? "none"
        let page = browser?.sidebarSelection.map { "\($0)" } ?? "none"
        return "key window \(key), page \(page), palette \(palette.isPresented ? "open" : "closed"), "
            + "player \(isPlaying ? "playing" : "not playing"), skip pending \(playback.isSkipCommandPending), "
            + "app active \(NSApp.isActive), menu items off: \(Self.disabledMenuShortcuts())"
    }

    private var isReady: Bool {
        guard window != nil, let browser else { return false }
        guard case .loaded = browser.playlistState else { return false }
        return isPlaying
    }

    private func measure(_ step: Step, frameMilliseconds: Double) async -> InteractionLatency.Measurement {
        var times: [Double] = []
        var problems: [String] = []
        for _ in 0..<Self.tries {
            try? await Task.sleep(for: .seconds(Self.settleSeconds))  // try?: only cancelled when the app quits
            await resetBetweenSteps(keepPalette: step.id == "palette.type" || step.id == "palette.close")
            guard await step.prepare(self) else {
                problems.append("couldn't get ready (\(stateDescription))")
                continue
            }
            try? await Task.sleep(for: .seconds(Self.settleSeconds))  // try?: only cancelled when the app quits
            let started = CACurrentMediaTime()
            guard let shown = step.start(self) else {
                problems.append("nothing to press (\(stateDescription))")
                continue
            }
            if let committed = await nextFrame(where: shown) {
                times.append((committed - started) * 1000 + frameMilliseconds)
            } else {
                problems.append("not shown after \(Int(Self.timeoutSeconds)) s (\(stateDescription))")
            }
            await step.finish(self)
        }
        return InteractionLatency.Measurement(
            id: step.id,
            title: step.title,
            milliseconds: times,
            timedOut: problems.count,
            problems: problems
        )
    }

    /// Waits, without timing, until `condition` holds; `false` when it didn't within `timeout`.
    @discardableResult
    private func waitUntil(
        timeout: Double = 3,
        _ condition: @escaping (InteractionLatencyProbe) -> Bool
    ) async -> Bool {
        let deadline = CACurrentMediaTime() + timeout
        while CACurrentMediaTime() < deadline {
            if condition(self) { return true }
            try? await Task.sleep(for: .milliseconds(20))  // try?: only cancelled when the app quits
        }
        return condition(self)
    }

    /// Puts the app back where every step starts: main window in front, no Settings, palette
    /// closed (unless the step works in it).
    private func resetBetweenSteps(keepPalette: Bool) async {
        for other in NSApp.windows where Self.isSettingsWindow(other) && other.isVisible { other.close() }
        if NSApp.keyWindow !== window, !(keepPalette && palette.isPresented) {
            window?.makeKeyAndOrderFront(nil)
        }
        if !keepPalette, palette.isPresented {
            press(.escape)
            await waitUntil { !$0.palette.isPresented }
        }
    }

    private func showPage(_ selection: SidebarSelection) async -> Bool {
        guard let browser else { return false }
        if browser.sidebarSelection != selection {
            browser.sidebarSelection = selection
        }
        return await waitUntil { $0.browser?.sidebarSelection == selection }
    }

    // MARK: - Frames

    private struct PendingFrame {
        let shown: () -> Bool
        let resume: (CFTimeInterval?) -> Void
    }

    /// Core Animation commits the frame in an observer at order 2000000 before the run loop
    /// sleeps; this one runs right after it.
    private func installCommitObserver() {
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue,
            true,
            2_000_001
        ) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.frameCommitted() }
        }
        // The run loop keeps it for the rest of the app's life, which ends with the probe.
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private func frameCommitted() {
        guard let pending, pending.shown() else { return }
        self.pending = nil
        pending.resume(CACurrentMediaTime())
    }

    /// The time of the first commit after which `shown` holds, or `nil` after the timeout.
    private func nextFrame(where shown: @escaping () -> Bool) async -> CFTimeInterval? {
        await withCheckedContinuation { continuation in
            var finished = false
            let resume: (CFTimeInterval?) -> Void = { value in
                guard !finished else { return }
                finished = true
                continuation.resume(returning: value)
            }
            pending = PendingFrame(shown: shown, resume: resume)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeoutSeconds) { [weak self] in
                MainActor.assumeIsolated {
                    self?.pending = nil
                    resume(nil)
                }
            }
        }
    }

    // MARK: - Input

    enum Key {
        case space, escape, delete, rightArrow, leftArrow, leftBracket, comma, k, m, s, q, l, f, r

        var code: UInt16 {
            switch self {
            case .space: 49
            case .escape: 53
            case .delete: 51
            case .rightArrow: 124
            case .leftArrow: 123
            case .leftBracket: 33
            case .comma: 43
            case .k: 40
            case .m: 46
            case .s: 1
            case .q: 12
            case .l: 37
            case .f: 3
            case .r: 15
            }
        }

        var characters: String {
            switch self {
            case .space: " "
            case .escape: "\u{1B}"
            case .delete: "\u{7F}"
            case .rightArrow: String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
            case .leftArrow: String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
            case .leftBracket: "["
            case .comma: ","
            case .k: "k"
            case .m: "m"
            case .s: "s"
            case .q: "q"
            case .l: "l"
            case .f: "f"
            case .r: "r"
            }
        }

        var isArrow: Bool { self == .rightArrow || self == .leftArrow }
    }

    private func press(_ key: Key, _ modifiers: NSEvent.ModifierFlags = []) {
        guard let window = NSApp.keyWindow ?? window else { return }
        var flags = modifiers
        if key.isArrow { flags.formUnion([.function, .numericPad]) }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: key.characters,
                charactersIgnoringModifiers: key.characters,
                isARepeat: false,
                keyCode: key.code
            ) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    /// Clicks the middle of the first element in the main window whose accessibility label is one
    /// of `label`. `false` when there is none.
    private func click(label: [String]) -> Bool {
        guard let window, let frame = Self.accessibilityFrame(in: window, labelledAnyOf: Set(label)) else { return false }
        click(at: window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY)))
        return true
    }

    /// The sidebar's list and the row of its second-to-last playlist. The sidebar's rows aren't in
    /// the in-app accessibility tree, so the row is found by place: playlists are its last rows,
    /// and the last one is the long playlist the scroll step opens.
    private func sidebarPlaylistRow() -> (list: NSTableView, index: Int)? {
        var queue: [NSView] = window?.contentView.map { [$0] } ?? []
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let list = view as? NSTableView, list.numberOfRows >= 3,
                let window, list.convert(list.bounds, to: nil).minX < window.contentLayoutRect.width * 0.3
            {
                return (list, list.numberOfRows - 2)
            }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// A click at `point` in the main window's coordinates.
    private func click(at point: NSPoint) {
        guard let window else { return }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ) else { return }
            NSApp.postEvent(event, atStart: false)
        }
    }

    private static func accessibilityFrame(in window: NSWindow, labelledAnyOf labels: Set<String>) -> NSRect? {
        var queue: [Any] = window.contentView.map { [$0] } ?? []
        var visited = 0
        while !queue.isEmpty, visited < 20_000 {
            let element = queue.removeFirst()
            visited += 1
            guard let node = element as? NSAccessibilityElementProtocol & NSObjectProtocol else { continue }
            let accessible = node as? NSAccessibilityProtocol
            // A row reads its name first and then its details ("Night Drive, 8 tracks"); a list's
            // text carries its words as the value instead.
            let text = accessible?.accessibilityLabel() ?? (accessible?.accessibilityValue() as? String)
            if let text, labels.contains(where: { text == $0 || text.hasPrefix($0 + ",") }) {
                let frame = node.accessibilityFrame()
                if frame.width > 0, frame.height > 0 { return frame }
            }
            if let children = accessible?.accessibilityChildren() { queue.append(contentsOf: children) }
            if let view = element as? NSView { queue.append(contentsOf: view.subviews) }
        }
        return nil
    }

    /// The app's own menu bar items with a shortcut that are switched off.
    private static func disabledMenuShortcuts() -> String {
        var off: [String] = []
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if !item.keyEquivalent.isEmpty, !item.isEnabled, item.action != nil { off.append(item.title) }
                if let sub = item.submenu { walk(sub) }
            }
        }
        NSApp.mainMenu.map(walk)
        return off.isEmpty ? "none" : off.joined(separator: ", ")
    }

    // MARK: - Scrolling

    private func showLongPlaylist() async -> Bool {
        guard let browser else { return false }
        if case .playlist = browser.sidebarSelection, scrollViewUnderTrackList() != nil {
            return true
        }
        guard case let .loaded(rows) = browser.playlistState,
            let long = rows.first(where: { $0.title == Self.longPlaylist })
        else { return false }
        guard await showPage(.playlist(long.id)) else { return false }
        return await waitUntil(timeout: 10) { $0.scrollViewUnderTrackList() != nil }
    }

    /// The tallest scroll view in the window that holds more than two screens: the track list.
    private func scrollViewUnderTrackList() -> NSScrollView? {
        guard let content = window?.contentView else { return nil }
        var queue: [NSView] = [content]
        var best: NSScrollView?
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let scroll = view as? NSScrollView, let document = scroll.documentView,
                document.frame.height > scroll.contentView.bounds.height * 2,
                document.frame.height > (best?.documentView?.frame.height ?? 0)
            {
                best = scroll
            }
            queue.append(contentsOf: view.subviews)
        }
        return best
    }

    /// The middle of the track list, in window coordinates.
    private func scrollPoint(in window: NSWindow) -> NSPoint {
        guard let scroll = scrollViewUnderTrackList() else {
            return NSPoint(x: window.contentLayoutRect.width * 0.62, y: window.contentLayoutRect.height * 0.5)
        }
        return scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
    }

    /// One trackpad-sized scroll step down the list; shown once the list has moved. Turns back
    /// to the top after it reaches the end, so every try moves.
    private func scrollTrackList() -> (() -> Bool)? {
        guard let window, let scroll = scrollViewUnderTrackList() else { return nil }
        let before = scroll.contentView.bounds.origin.y
        let maxY = (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height
        let down = before < maxY - 400
        let windowPoint = scrollPoint(in: window)
        let screenPoint = window.convertPoint(toScreen: windowPoint)
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        guard let cg = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: down ? -120 : 120 * 40,
            wheel2: 0,
            wheel3: 0
        ) else { return nil }
        cg.location = CGPoint(x: screenPoint.x, y: mainHeight - screenPoint.y)
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        // A scroll event made from a CGEvent carries no window, so neither NSApp nor the window
        // can route it: it goes straight to the list's scroll view, where a real one ends up.
        guard let event = NSEvent(cgEvent: cg) else { return nil }
        scroll.scrollWheel(with: event)
        return { scroll.contentView.bounds.origin.y != before }
    }
}
