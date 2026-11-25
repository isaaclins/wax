import AppKit
import QuartzCore

/// Every interaction goes into the log (#734): each click, key, shortcut, scroll start and stop,
/// menu pick, drag and window change, with what it hit (the window, the control's accessibility
/// label, the list row) and how long until Wax drew its first frame after it.
///
/// The input is only noted when it arrives; the line is written after the frame that follows it
/// is committed, so looking up what was hit never delays that frame. Lines go to the log's
/// background queue. The first frame is the run loop's next Core Animation commit: what the
/// press changed right away (a highlight, a toggle) is in it, a result that waits on a call comes
/// later, and the call's own line says how long the interaction waited for it (``CallLog``).
@MainActor
final class InteractionLog {
    static let shared = InteractionLog()

    /// A first frame later than this after the input is marked SLOW.
    static let slowFrame: TimeInterval = 1
    /// Looking up the control under the pointer through accessibility stops for the session once
    /// it took longer than this ``slowLookupsAllowed`` times (the first one builds the tree), so
    /// the log never costs the app its speed.
    static let lookupBudget: TimeInterval = 0.008
    static let slowLookupsAllowed = 3

    private let write: (String) -> Void
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var nextID = 1
    private var dragging = false
    private var scrolling = false
    private var lastWheelAt: TimeInterval = 0
    private var repeatedKeys = 0
    private var lookupsAllowed = true
    private var slowLookups = 0

    private let lookupBudget: TimeInterval

    init(
        lookupBudget: TimeInterval = InteractionLog.lookupBudget,
        write: @escaping (String) -> Void = { SpotiglassLog.info(.interaction, $0) }
    ) {
        self.lookupBudget = lookupBudget
        self.write = write
    }

    /// Starts listening for the app's lifetime. Later calls do nothing.
    func start() {
        guard monitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel,
        ]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSMenu.didSendActionNotification, object: nil, queue: .main) { [weak self] note in
            let item = note.userInfo?["MenuItem"] as? NSMenuItem
            let menu = (note.object as? NSMenu)?.title ?? ""
            MainActor.assumeIsolated {
                self?.record("menu pick “\(item?.title ?? "?")”" + (menu.isEmpty ? "" : " in “\(menu)”"), target: nil, at: nil)
            }
        })
        let windowEvents: [(Notification.Name, String)] = [
            (NSWindow.didBecomeKeyNotification, "became key"),
            (NSWindow.willCloseNotification, "closing"),
            (NSWindow.didMiniaturizeNotification, "minimized"),
            (NSWindow.didDeminiaturizeNotification, "restored"),
            (NSWindow.didEnterFullScreenNotification, "entered full screen"),
            (NSWindow.didExitFullScreenNotification, "left full screen"),
            (NSWindow.didEndLiveResizeNotification, "resized"),
            (NSWindow.didChangeScreenNotification, "moved to another screen"),
            (NSWindow.didChangeOcclusionStateNotification, "visibility changed"),
        ]
        for (name, what) in windowEvents {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated {
                    let frame = window.frame
                    let visible = window.occlusionState.contains(.visible) ? "visible" : "hidden"
                    self?.write(
                        "window \(Self.name(window)) \(what): \(Int(frame.width))x\(Int(frame.height)) at "
                            + "(\(Int(frame.minX)), \(Int(frame.minY))), \(visible)"
                    )
                }
            })
        }
        for (name, what) in [
            (NSApplication.didBecomeActiveNotification, "app became active"),
            (NSApplication.didResignActiveNotification, "app went to the background"),
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.write(what) }
            })
        }
    }

    /// Stops listening. The app's log listens for its lifetime; tests stop theirs.
    // periphery:ignore
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    // MARK: - Events

    /// One input, as the app's event monitor passes it on.
    func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            dragging = false
            let button = event.type == .rightMouseDown ? "right-click" : event.type == .otherMouseDown ? "click (button \(event.buttonNumber))" : "click"
            let label = event.clickCount > 1 ? "\(event.clickCount)x \(button)" : button
            record(label, target: target(of: event), at: event.timestamp, point: event)
        case .leftMouseDragged:
            guard !dragging else { return }
            dragging = true
            record("drag start", target: target(of: event), at: event.timestamp, point: event)
        case .leftMouseUp:
            guard dragging else { return }
            dragging = false
            record("drag end (drop)", target: target(of: event), at: event.timestamp, point: event)
        case .keyDown:
            if event.isARepeat {
                repeatedKeys += 1
                // Held keys repeat many times a second; every 10th says it is still held.
                guard repeatedKeys.isMultiple(of: 10) else { return }
                write("\(Self.keyLabel(event)) still held (\(repeatedKeys) repeats)")
                return
            }
            repeatedKeys = 0
            record(Self.keyLabel(event), target: focusTarget(event.window), at: event.timestamp)
        case .scrollWheel:
            handleScroll(event)
        default:
            break
        }
    }

    private func handleScroll(_ event: NSEvent) {
        if event.phase.contains(.began) {
            scrolling = true
            record("scroll start", target: target(of: event), at: event.timestamp, point: event)
        } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            // A slow scroll ends here; after a flick, momentum carries on until it stops.
            guard scrolling else { return }
            write("scroll fingers lifted")
        } else if event.momentumPhase.contains(.ended) {
            guard scrolling else { return }
            scrolling = false
            write("scroll end (momentum stopped)")
        } else if event.phase.isEmpty, event.momentumPhase.isEmpty {
            // A mouse wheel has no phases: a turn after a pause counts as a new scroll.
            let at = event.timestamp
            defer { lastWheelAt = at }
            guard at - lastWheelAt > 0.5 else { return }
            record("scroll (mouse wheel)", target: target(of: event), at: at, point: event)
        }
    }

    // MARK: - Lines

    private struct Target {
        var window: String
        var view: String
        var row: String?
    }

    /// Notes an interaction now and writes its line once the next frame is committed.
    private func record(_ label: String, target: Target?, at timestamp: TimeInterval?, point event: NSEvent? = nil) {
        let id = nextID
        nextID += 1
        let start = timestamp ?? ProcessInfo.processInfo.systemUptime
        var description = label
        if let target { description += " in \(target.window)" + (target.row.map { " \($0)" } ?? "") }
        CallLog.noteInteraction(CallLog.Interaction(id: id, label: label, at: start))
        let screenPoint = event.flatMap { event -> NSPoint? in
            guard let window = event.window else { return nil }
            return window.convertPoint(toScreen: event.locationInWindow)
        }
        let window = event?.window
        let view = target?.view
        afterNextCommit { [weak self] in
            guard let self else { return }
            let frameAfter = ProcessInfo.processInfo.systemUptime - start
            var line = "#\(id) \(description)"
            if let control = self.control(at: screenPoint, in: window) {
                line += " on \(control)"
            } else if let view {
                line += " on \(view)"
            }
            line += "; first frame after \(CallLog.milliseconds(frameAfter))"
            if frameAfter > Self.slowFrame { line += " SLOW (see the main thread line above)" }
            self.write(line)
        }
    }

    /// Runs `block` once, after the Core Animation commit of this run loop turn.
    private func afterNextCommit(_ block: @escaping @MainActor () -> Void) {
        // Core Animation commits in a before-waiting observer of order 2000000; this one is later.
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, Int.max) { _, _ in
            MainActor.assumeIsolated(block)
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private func target(of event: NSEvent) -> Target {
        guard let window = event.window else { return Target(window: "no window", view: "nothing") }
        var target = Target(window: Self.name(window), view: "nothing")
        guard let content = window.contentView else { return target }
        let hit = content.hitTest(content.convert(event.locationInWindow, from: nil))
        target.view = hit.map { String(describing: type(of: $0)) } ?? "nothing"
        var view = hit
        while let current = view {
            if let table = current as? NSTableView {
                let row = table.row(at: table.convert(event.locationInWindow, from: nil))
                target.row = row >= 0 ? "row \(row + 1) of \(table.numberOfRows)" : "between rows"
                break
            }
            view = current.superview
        }
        return target
    }

    private func focusTarget(_ window: NSWindow?) -> Target? {
        guard let window else { return nil }
        let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nothing"
        return Target(window: Self.name(window), view: "focus \(responder)")
    }

    /// The control under `point` as accessibility names it: "button “Next”" or "cell “Song” in
    /// row". Stops for the session once a lookup costs more than ``lookupBudget``.
    private func control(at point: NSPoint?, in window: NSWindow?) -> String? {
        guard lookupsAllowed, let point, let content = window?.contentView else { return nil }
        let start = ProcessInfo.processInfo.systemUptime
        defer {
            let took = ProcessInfo.processInfo.systemUptime - start
            if took > lookupBudget {
                slowLookups += 1
                if slowLookups >= Self.slowLookupsAllowed {
                    lookupsAllowed = false
                    write("looking up controls took \(CallLog.milliseconds(took)); interaction lines name only the view from now on")
                }
            }
        }
        var element = content.accessibilityHitTest(point)
        var parts: [String] = []
        for _ in 0 ..< 4 {
            guard let current = element as? NSAccessibilityProtocol else { break }
            let role = current.accessibilityRole()?.rawValue ?? ""
            let label = current.accessibilityLabel() ?? ""
            let title = current.accessibilityTitle() ?? ""
            let identifier = current.accessibilityIdentifier() ?? ""
            let name = [label, title].first { !$0.isEmpty } ?? identifier
            if !name.isEmpty || parts.isEmpty {
                parts.append("\(role.replacingOccurrences(of: "AX", with: "").lowercased()) “\(name)”")
            }
            if parts.count >= 2 || role == NSAccessibility.Role.row.rawValue { break }
            element = current.accessibilityParent()
        }
        return parts.isEmpty ? nil : parts.joined(separator: " in ")
    }

    private static func name(_ window: NSWindow) -> String {
        if !window.title.isEmpty { return "window “\(window.title)”" }
        if let identifier = window.identifier?.rawValue, !identifier.isEmpty { return "window \(identifier)" }
        return String(describing: type(of: window))
    }

    /// "key A", "shortcut ⌘F", or only "key in a password field": what is typed there never
    /// reaches the log.
    static func keyLabel(_ event: NSEvent) -> String {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isShortcut = !flags.intersection([.command, .control, .option]).isEmpty
        if isSecureField(event.window) { return "key in a password field" }
        return (isShortcut ? "shortcut " : "key ") + keyName(event)
    }

    private static func keyName(_ event: NSEvent) -> String {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var name = ""
        if flags.contains(.control) { name += "⌃" }
        if flags.contains(.option) { name += "⌥" }
        if flags.contains(.shift) { name += "⇧" }
        if flags.contains(.command) { name += "⌘" }
        switch event.keyCode {
        case 36: name += "Return"
        case 48: name += "Tab"
        case 49: name += "Space"
        case 51: name += "Delete"
        case 53: name += "Escape"
        case 123: name += "←"
        case 124: name += "→"
        case 125: name += "↓"
        case 126: name += "↑"
        default:
            let characters = event.charactersIgnoringModifiers ?? ""
            name += characters.isEmpty ? "key \(event.keyCode)" : characters.uppercased()
        }
        return name
    }

    private static func isSecureField(_ window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder is NSSecureTextField { return true }
        if let editor = responder as? NSText, editor.delegate is NSSecureTextField { return true }
        return false
    }
}
