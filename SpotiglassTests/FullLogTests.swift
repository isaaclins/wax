import AppKit
import Foundation
import XCTest

@testable import Spotiglass

/// The log holds everything Wax does (#734): no call fails without a line, a blocked main thread
/// says what it was doing, a song change says why, and no secret gets in.
@MainActor
final class FullLogTests: XCTestCase {
    // MARK: - Calls

    /// The error MusicKit's player gives for a song it won't load, with the error beneath it: the
    /// read fails, and the log file has a line with all of it.
    func testAFailingMusicKitCallLeavesALineWithTheWholeError() async throws {
        let marker = "read \(UUID().uuidString)"
        let underlying = NSError(
            domain: "MPErrorDomain", code: 5, userInfo: [NSLocalizedDescriptionKey: "The item is not available"])
        let failure = NSError(
            domain: MusicKitApplicationPlayer.playerErrorDomain,
            code: MusicKitApplicationPlayer.prepareToPlayFailedCode,
            userInfo: [NSLocalizedDescriptionKey: "Failed to prepare to play", NSUnderlyingErrorKey: underlying]
        )

        do {
            _ = try await MusicKitContentSource.logged("library playlists \(marker)") { () async throws -> Int in
                throw failure
            }
            XCTFail("The read must fail")
        } catch {}

        let lines = try SpotiglassLogReader.lines(containing: marker)
        XCTAssertTrue(
            lines.contains { $0.contains("[calls] → #") && $0.contains("MusicKit library playlists") }, "\(lines)")
        let failed = try XCTUnwrap(lines.first { $0.contains("[ERROR] [calls] ← #") }, "\(lines)")
        XCTAssertTrue(failed.contains("MusicKit library playlists \(marker) failed after"), failed)
        XCTAssertTrue(failed.contains("MPMusicPlayerControllerErrorDomain 6: Failed to prepare to play"), failed)
        XCTAssertTrue(failed.contains("underlying: MPErrorDomain 5: The item is not available"), failed)
    }

    /// Offline, an API request fails before any answer: the log file has the request, how long it
    /// took and the error.
    func testAFailingHTTPRequestLeavesALineWithTheWholeError() async throws {
        let marker = UUID().uuidString
        let client: HTTPClient = FailingURLProtocol.session()
        FailingURLProtocol.outcome = .error(URLError(.timedOut))
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player?marker=\(marker)")!)
        request.setValue("Bearer secret-token-\(marker)", forHTTPHeaderField: "Authorization")

        do {
            _ = try await client.data(for: request)
            XCTFail("The request must fail")
        } catch {}

        let lines = try SpotiglassLogReader.lines(containing: marker)
        let failed = try XCTUnwrap(lines.first { $0.contains("[ERROR] [calls] ← #") }, "\(lines)")
        XCTAssertTrue(
            failed.contains("HTTP GET https://api.spotify.com/v1/me/player?marker=\(marker) failed after"), failed)
        XCTAssertTrue(failed.contains("\(NSURLErrorDomain) \(URLError.timedOut.rawValue)"), failed)
        XCTAssertFalse(lines.joined().contains("secret-token"), "A token reached the log: \(lines)")
    }

    /// A server error is an answer, not a thrown error: it still gets an error line with its status.
    func testAnHTTPServerErrorIsLoggedAsAFailure() async throws {
        let marker = UUID().uuidString
        let client: HTTPClient = FailingURLProtocol.session()
        FailingURLProtocol.outcome = .status(503)

        let (_, response) = try await client.data(
            for: URLRequest(url: URL(string: "https://lrclib.net/api/get?m=\(marker)")!))

        XCTAssertEqual(response.statusCode, 503)
        let lines = try SpotiglassLogReader.lines(containing: marker)
        XCTAssertTrue(lines.contains { $0.contains("[ERROR] [calls]") && $0.contains("status 503") }, "\(lines)")
    }

    /// LRCLIB answers 404 for a song it has no lyrics for: an answer, not a failure, so no error
    /// line for every such song.
    func testAnExpectedStatusIsNotLoggedAsAFailure() async throws {
        let marker = UUID().uuidString
        FailingURLProtocol.outcome = .status(404)

        let (_, response) = try await CallLog.http(
            URLRequest(url: URL(string: "https://lrclib.net/api/get-cached?m=\(marker)")!),
            session: FailingURLProtocol.session(),
            expected: [404]
        )

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
        let lines = try SpotiglassLogReader.lines(containing: marker)
        XCTAssertTrue(
            lines.contains {
                $0.contains("[INFO] [calls] ← #") && $0.contains("done after") && $0.contains("status 404")
            }, "\(lines)")
        XCTAssertFalse(lines.contains { $0.contains("[ERROR]") }, "\(lines)")
    }

    /// Codes, tokens and cookies never reach the log, whatever carries them.
    func testSecretsAreHidden() {
        let text = SpotiglassLog.redactSecrets(
            "GET https://x.test/cb?code=AQB123&state=abc&access_token=xyz refresh_token=r1 Authorization: Bearer abc.def Cookie: sp_dc=1"
        )
        for secret in ["AQB123", "xyz", "r1", "abc.def", "sp_dc"] {
            XCTAssertFalse(text.contains(secret), "\(secret) is in \(text)")
        }
        XCTAssertTrue(text.contains("state=abc"), text)
        // An error's code is no secret.
        let error = SpotiglassLog.redactSecrets(#"Error Domain=NSURLErrorDomain Code=-1001 "The request timed out.""#)
        XCTAssertTrue(error.contains("Code=-1001"), error)
        // Only a code may be a bare number; a numeric password or token is still hidden.
        let numeric = SpotiglassLog.redactSecrets("https://x.test/a?password=1234&token=987654")
        XCTAssertFalse(numeric.contains("1234"), numeric)
        XCTAssertFalse(numeric.contains("987654"), numeric)
    }

    /// MusicKit's request errors print the request with its headers as a dictionary: the user
    /// token in there stays out of the call's line, also when it is the error beneath another.
    func testAMusicKitErrorThatPrintsItsHeadersKeepsTheTokenOut() async throws {
        struct PrintsHeaders: Error, CustomStringConvertible {
            var description: String {
                #"request failed: ["Music-User-Token": "AmUserTok42", "Authorization": "Bearer devTok42", "Accept": "application/json"]"#
            }
        }
        let marker = "read \(UUID().uuidString)"
        let failure = NSError(domain: "MusicKit", code: 1, userInfo: [NSUnderlyingErrorKey: PrintsHeaders()])
        do {
            _ = try await MusicKitContentSource.logged("catalog \(marker)") { () async throws -> Int in throw failure }
            XCTFail("The read must fail")
        } catch {}

        let lines = try SpotiglassLogReader.lines(containing: marker)
        let failed = try XCTUnwrap(lines.first { $0.contains("[ERROR] [calls] ← #") }, "\(lines)")
        XCTAssertTrue(failed.contains("Accept"), failed)
        XCTAssertFalse(failed.contains("AmUserTok42"), failed)
        XCTAssertFalse(failed.contains("devTok42"), failed)
    }

    /// Leaving a page cancels its reads, and MusicKit hands that back as Foundation's
    /// "cancelled": the line says cancelled, and no error line is written for it.
    func testACancelledMusicKitReadIsNotAFailure() async throws {
        let marker = "read \(UUID().uuidString)"
        do {
            _ = try await MusicKitContentSource.logged("recently played \(marker)") { () async throws -> Int in
                throw NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
            }
            XCTFail("The read must fail")
        } catch {}

        let lines = try SpotiglassLogReader.lines(containing: marker)
        XCTAssertTrue(
            lines.contains {
                $0.contains("[INFO] [calls] ← #") && $0.contains("done after") && $0.hasSuffix(": cancelled")
            }, "\(lines)")
        XCTAssertFalse(lines.contains { $0.contains("[ERROR]") }, "\(lines)")
    }

    // MARK: - Interactions

    /// What is typed into a password field never reaches the log, held keys included; other keys
    /// are named.
    func testKeysInAPasswordFieldAreNotNamed() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 60), styleMask: [.titled], backing: .buffered,
            defer: false)
        defer { window.close() }
        window.isReleasedWhenClosed = false
        let secure = NSSecureTextField(frame: NSRect(x: 10, y: 10, width: 180, height: 24))
        let plain = NSTextField(frame: NSRect(x: 10, y: 34, width: 180, height: 24))
        window.contentView?.addSubview(secure)
        window.contentView?.addSubview(plain)
        func key(_ character: String, repeat isARepeat: Bool = false) throws -> NSEvent {
            try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: isARepeat,
                    keyCode: 0
                ))
        }

        XCTAssertTrue(window.makeFirstResponder(secure))
        XCTAssertEqual(InteractionLog.keyLabel(try key("q")), "key in a password field")
        XCTAssertEqual(InteractionLog.keyLabel(try key("q", repeat: true)), "key in a password field")

        XCTAssertTrue(window.makeFirstResponder(plain))
        XCTAssertEqual(InteractionLog.keyLabel(try key("q")), "key Q")
    }

    /// Every kind of input gets its line, naming what it hit (the window, the control, the list
    /// row) and how long until the next frame, written after that frame.
    func testEveryInputGetsALineWithWhatItHit() throws {
        let fixture = InteractionFixture()
        defer { fixture.close() }
        var lines: [String] = []
        // A budget no lookup reaches, so a slow machine can't switch the lookup off mid-test.
        let log = InteractionLog(lookupBudget: 60) { lines.append($0) }
        let window = fixture.window
        // The interactions here would otherwise stay the last one for calls in later tests.
        defer { CallLog.noteInteraction(CallLog.Interaction(id: 0, label: "none", at: 0)) }

        func mouse(_ type: NSEvent.EventType, at point: NSPoint, clicks: Int = 1, ago: TimeInterval = 0) throws
            -> NSEvent
        {
            try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime - ago,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1
                ))
        }
        func key(
            _ characters: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = [], repeat isARepeat: Bool = false
        ) throws -> NSEvent {
            try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: isARepeat, keyCode: code
                ))
        }
        func written() -> [String] {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            defer { lines = [] }
            return lines
        }

        log.handle(try mouse(.leftMouseDown, at: fixture.buttonCenter))
        let click = try XCTUnwrap(written().first)
        XCTAssertTrue(click.contains("click in window “Fixture”"), click)
        // What accessibility names under the pointer (a window that isn't on screen has only
        // itself to offer; in the app it is the control, `button “Next track”`).
        XCTAssertTrue(click.contains(" on window “Fixture”"), click)
        XCTAssertTrue(click.contains("; first frame after "), click)
        XCTAssertFalse(click.contains("SLOW"), click)

        log.handle(try mouse(.rightMouseDown, at: fixture.buttonCenter))
        XCTAssertTrue(written().first?.contains("right-click") == true)
        log.handle(try mouse(.otherMouseDown, at: fixture.buttonCenter))
        XCTAssertTrue(written().first?.contains("click (button ") == true)
        log.handle(try mouse(.leftMouseDown, at: fixture.buttonCenter, clicks: 2))
        XCTAssertTrue(written().first?.contains("2x click") == true)

        // A press the app answered more than a second later is marked.
        log.handle(try mouse(.leftMouseDown, at: fixture.buttonCenter, ago: 2))
        XCTAssertTrue(written().first?.contains(" SLOW ") == true)

        // A list row is named by its place in the list.
        log.handle(try mouse(.leftMouseDown, at: fixture.rowPoint(1)))
        let row = try XCTUnwrap(written().first)
        XCTAssertTrue(row.contains("row 2 of 5"), row)

        // A drag: one line when it starts, one at the drop; a plain mouse-up has none.
        log.handle(try mouse(.leftMouseUp, at: fixture.buttonCenter))
        XCTAssertEqual(written(), [])
        log.handle(try mouse(.leftMouseDown, at: fixture.buttonCenter))
        _ = written()
        log.handle(try mouse(.leftMouseDragged, at: fixture.buttonCenter))
        log.handle(try mouse(.leftMouseDragged, at: fixture.rowPoint(3)))
        XCTAssertTrue(written().first?.contains("drag start") == true)
        log.handle(try mouse(.leftMouseUp, at: fixture.rowPoint(3)))
        XCTAssertTrue(written().first?.contains("drag end (drop)") == true)

        // Keys and shortcuts, with the named keys spelled out.
        log.handle(try key("a"))
        XCTAssertTrue(written().first?.contains("key A in window “Fixture”") == true)
        log.handle(try key("k", flags: [.command, .shift, .option, .control]))
        XCTAssertTrue(written().first?.contains("shortcut ⌃⌥⇧⌘K") == true)
        for (code, name) in [
            (36, "Return"), (48, "Tab"), (49, "Space"), (51, "Delete"), (53, "Escape"), (123, "←"), (124, "→"),
            (125, "↓"), (126, "↑"),
        ] {
            log.handle(try key(" ", code: UInt16(code)))
            XCTAssertTrue(written().first?.contains("key \(name) ") == true, name)
        }
        log.handle(try key(""))
        XCTAssertTrue(written().first?.contains("key key 0") == true)
        // A held key: every 10th repeat says it is still held.
        for _ in 0..<10 { log.handle(try key("j", repeat: true)) }
        XCTAssertEqual(written(), ["key J still held (10 repeats)"])

        // Trackpad scrolls start, lift and end; a mouse wheel counts a turn after a pause.
        log.handle(try Self.scroll(phase: 1))
        XCTAssertTrue(written().first?.contains("scroll start") == true)
        log.handle(try Self.scroll(phase: 4))
        XCTAssertEqual(written(), ["scroll fingers lifted"])
        log.handle(try Self.scroll(momentum: 3))
        XCTAssertEqual(written(), ["scroll end (momentum stopped)"])
        log.handle(try Self.scroll(momentum: 3))
        XCTAssertEqual(written(), [])
        log.handle(try Self.scroll())
        XCTAssertTrue(written().first?.contains("scroll (mouse wheel)") == true)
        log.handle(try Self.scroll())
        XCTAssertEqual(written(), [], "A wheel still turning is the same scroll")
    }

    /// Once looking up the control has gone over its budget three times, it stops for the
    /// session and the lines name only the view under the pointer.
    func testASlowControlLookupSwitchesItselfOff() throws {
        let fixture = InteractionFixture()
        defer { fixture.close() }
        var lines: [String] = []
        // Every lookup counts as over a budget below zero.
        let log = InteractionLog(lookupBudget: -1) { lines.append($0) }
        defer { CallLog.noteInteraction(CallLog.Interaction(id: 0, label: "none", at: 0)) }
        for _ in 0..<4 {
            let event = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: .leftMouseDown, location: fixture.buttonCenter, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1
                ))
            log.handle(event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertEqual(lines.filter { $0.hasPrefix("looking up controls took ") }.count, 1, "\(lines)")
        XCTAssertTrue(lines.last?.contains(" on NSButton;") == true, "\(lines)")
    }

    /// Window changes, menu picks and the app coming and going are lines too.
    func testWindowChangesMenuPicksAndTheAppGoingAwayAreLines() throws {
        let fixture = InteractionFixture()
        defer { fixture.close() }
        var lines: [String] = []
        let log = InteractionLog(lookupBudget: 60) { lines.append($0) }
        defer { CallLog.noteInteraction(CallLog.Interaction(id: 0, label: "none", at: 0)) }
        log.start()
        log.start()
        defer { log.stop() }
        let center = NotificationCenter.default

        center.post(name: NSWindow.didEndLiveResizeNotification, object: fixture.window)
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        let item = NSMenuItem(title: "Next Track", action: nil, keyEquivalent: "")
        center.post(
            name: NSMenu.didSendActionNotification, object: NSMenu(title: "Playback"), userInfo: ["MenuItem": item])
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertTrue(lines.contains { $0.hasPrefix("window window “Fixture” resized: 320x") }, "\(lines)")
        XCTAssertTrue(lines.contains("app went to the background"), "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("menu pick “Next Track” in “Playback”") }, "\(lines)")

        // A window without a title is named by its identifier, else by its kind.
        fixture.window.title = ""
        fixture.window.identifier = NSUserInterfaceItemIdentifier("queue")
        lines = []
        center.post(name: NSWindow.didMiniaturizeNotification, object: fixture.window)
        XCTAssertTrue(lines.first?.hasPrefix("window window queue minimized") == true, "\(lines)")
        fixture.window.identifier = nil
        lines = []
        center.post(name: NSWindow.didDeminiaturizeNotification, object: fixture.window)
        XCTAssertTrue(lines.first?.hasPrefix("window NSWindow restored") == true, "\(lines)")
    }

    /// A trackpad or mouse-wheel scroll event, with the phases macOS gives it.
    private static func scroll(phase: Int64 = 0, momentum: Int64 = 0) throws -> NSEvent {
        let event = try XCTUnwrap(
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -4, wheel2: 0, wheel3: 0))
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        event.timestamp = CGEventTimestamp(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    // MARK: - Resources

    /// Memory and CPU are sampled when something starts to play, and the next sample says how
    /// busy the app was since the last.
    func testResourcesAreSampledWhilePlaying() {
        var lines: [String] = []
        let log = ResourceLog(isEnabled: true) { lines.append($0) }
        let session = NSObject()

        log.session(session, isPlaying: true)
        log.session(session, isPlaying: true)
        XCTAssertEqual(lines.count, 1, "\(lines)")
        XCTAssertTrue(lines[0].hasPrefix("resources while playing: "), lines[0])
        XCTAssertTrue(lines[0].contains(" MB in use (peak "), lines[0])
        XCTAssertTrue(lines[0].hasSuffix("CPU first sample"), lines[0])

        log.sample()
        XCTAssertTrue(lines[1].contains("% of one core over the last "), lines[1])

        log.session(session, isPlaying: false)
        log.session(session, isPlaying: false)
        XCTAssertEqual(lines.count, 2)

        // Under the unit-test host the shared one stays off.
        var offLines: [String] = []
        let off = ResourceLog { offLines.append($0) }
        off.session(session, isPlaying: true)
        XCTAssertEqual(offLines, [])
    }

    /// A call that starts right after a press and takes over a second says the press waited for it.
    func testACallAfterAnInteractionSaysHowLongTheInteractionWaited() async throws {
        var lines: [(Bool, String)] = []
        var clock: TimeInterval = 1_000
        let write = CallLog.write
        let now = CallLog.now
        CallLog.write = { lines.append(($0, $1)) }
        CallLog.now = { clock }
        defer {
            CallLog.write = write
            CallLog.now = now
        }
        CallLog.noteInteraction(CallLog.Interaction(id: 41, label: "click", at: 999.8))

        _ = try await CallLog.run(.musicKit, "player.skipToNextEntry") { () async throws -> Void in clock += 2.5 }

        // Only this call's lines: anything else the test host logs meanwhile doesn't count.
        let mine = lines.filter { $0.1.contains("player.skipToNextEntry") }
        XCTAssertEqual(mine.count, 2, "\(lines)")
        XCTAssertTrue(mine[0].1.contains("(after interaction #41 click)"), mine[0].1)
        XCTAssertTrue(mine[1].1.contains("SLOW: interaction #41 click waited 2.70 s for this"), mine[1].1)
    }

    // MARK: - Hangs

    /// The main thread sleeps for 700 ms: the watch writes one line that says so and shows where
    /// the main thread was stuck.
    func testABlockedMainThreadGetsALineWithItsStack() throws {
        var captured: [String] = []
        let lock = NSLock()
        let watch = HangWatch(threshold: 0.25) { line in lock.withLock { captured.append(line) } }
        watch.start()
        defer { watch.stop() }
        // Let the watch's first turn land before blocking.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        usleep(700_000)

        let deadline = Date().addingTimeInterval(5)
        while lock.withLock({ captured.isEmpty }), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let line = try XCTUnwrap(lock.withLock { captured.first }, "No line for a 700 ms block")
        XCTAssertTrue(line.hasPrefix("MAIN THREAD BLOCKED for "), line)
        XCTAssertTrue(line.contains("main thread stack at "), line)
        XCTAssertTrue(line.contains("usleep") || line.contains("nanosleep"), "The stack must show the sleep: \(line)")
    }

    /// A hang someone may end by quitting the app: a line comes while it still lasts, and the
    /// usual one when it ends.
    func testALongHangGetsALineWhileItStillLasts() throws {
        var captured: [String] = []
        let lock = NSLock()
        let watch = HangWatch(threshold: 0.1, stillBlockedAfter: 0.4) { line in lock.withLock { captured.append(line) }
        }
        watch.start()
        defer { watch.stop() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        // The line written while blocked is there before the main thread runs again.
        var stillBlocked: String?
        let deadline = Date().addingTimeInterval(10)
        while stillBlocked == nil, Date() < deadline {
            usleep(50_000)
            stillBlocked = lock.withLock { captured.first }
        }
        let line = try XCTUnwrap(stillBlocked, "No line while the main thread was blocked")
        XCTAssertTrue(line.hasPrefix("MAIN THREAD STILL BLOCKED after "), line)
        XCTAssertTrue(line.contains("usleep") || line.contains("nanosleep"), "The stack must show the sleep: \(line)")

        let ended = Date().addingTimeInterval(5)
        while lock.withLock({ captured.count < 2 }), Date() < ended {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let lines = lock.withLock { captured }
        XCTAssertEqual(lines.count, 2, "\(lines)")
        XCTAssertTrue(lines.last?.hasPrefix("MAIN THREAD BLOCKED for ") == true, "\(lines)")
    }

    /// While Wax isn't the active app the watch looks once a second, and still catches a hang
    /// (at launch, or while a song changes behind other windows); back in front it looks as often
    /// as before.
    func testTheWatchStillCatchesAHangWhileTheAppIsInTheBackground() throws {
        var captured: [String] = []
        let lock = NSLock()
        // A short background pace and a block five times as long: a look always lands inside it.
        let watch = HangWatch(threshold: 0.1, backgroundInterval: 0.2) { line in lock.withLock { captured.append(line) }
        }
        watch.start(followingAppActivity: true)
        defer { watch.stop() }
        let center = NotificationCenter.default

        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        usleep(1_000_000)
        let backgroundDeadline = Date().addingTimeInterval(5)
        while lock.withLock({ captured.isEmpty }), Date() < backgroundDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(
            lock.withLock { captured.first }?.hasPrefix("MAIN THREAD BLOCKED for ") == true,
            "\(lock.withLock { captured })")
        lock.withLock { captured = [] }

        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        usleep(500_000)
        let deadline = Date().addingTimeInterval(5)
        while lock.withLock({ captured.isEmpty }), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(
            lock.withLock { captured.first }?.hasPrefix("MAIN THREAD BLOCKED for ") == true,
            "\(lock.withLock { captured })")
    }

    // MARK: - Song changes

    /// In the background the session doesn't read the player, so the last position can be from
    /// minutes before the song ended by itself: it is counted on from that read, and the change
    /// isn't called MusicKit's own. A song paused at that read stays where it was.
    func testASongThatEndedLongAfterTheLastReadIsNotCalledMusicKitsOwn() {
        typealias Change = AppleMusicSongChange
        let readWhilePlaying = Change.Seen(
            positionMilliseconds: 20_000, durationMilliseconds: 200_000, readAt: 1_000, rate: 1)
        XCTAssertEqual(
            Change.reason(before: readWhilePlaying, command: nil, now: 1_181),
            "the song before ended (3:20.0 of 3:20.0, counted on from a read 181.00 s before)"
        )
        // A read a moment ago is not called out.
        XCTAssertEqual(
            Change.reason(
                before: Change.Seen(
                    positionMilliseconds: 198_000, durationMilliseconds: 200_000, readAt: 1_000, rate: 1), command: nil,
                now: 1_001),
            "the song before ended (3:19.0 of 3:20.0)"
        )
        let readWhilePaused = Change.Seen(
            positionMilliseconds: 20_000, durationMilliseconds: 200_000, readAt: 1_000, rate: 0)
        XCTAssertEqual(
            Change.reason(before: readWhilePaused, command: nil, now: 1_181),
            "MusicKit moved on by itself, no song command sent: the song before stopped at 0:20.0 of 3:20.0"
        )
        // A song moving part way, read 40 s ago at 1:01: still short of its end.
        let partWay = Change.Seen(positionMilliseconds: 61_000, durationMilliseconds: 200_000, readAt: 1_000, rate: 1)
        XCTAssertEqual(
            Change.reason(before: partWay, command: nil, now: 1_040),
            "MusicKit moved on by itself, no song command sent: the song before stopped at 1:41.0 of 3:20.0, counted on from a read 40.00 s before"
        )
    }
}

/// Answers every request with the outcome a test sets.
private final class FailingURLProtocol: URLProtocol {
    enum Outcome {
        case error(Error)
        case status(Int)
    }

    nonisolated(unsafe) static var outcome: Outcome = .error(URLError(.notConnectedToInternet))

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FailingURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch Self.outcome {
        case .error(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .status(let status):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("unavailable".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

/// A window with a button and a five-row list, for interaction lines.
@MainActor
private final class InteractionFixture: NSObject, NSTableViewDataSource {
    let window: NSWindow
    private let button: NSButton
    private let table: NSTableView

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Fixture"
        button = NSButton(title: "Next", target: nil, action: nil)
        button.frame = NSRect(x: 10, y: 160, width: 100, height: 30)
        table = NSTableView(frame: NSRect(x: 10, y: 10, width: 300, height: 140))
        super.init()
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("song")))
        table.headerView = nil
        table.rowHeight = 20
        table.dataSource = self
        window.contentView?.addSubview(button)
        window.contentView?.addSubview(table)
        table.reloadData()
        window.contentView?.layoutSubtreeIfNeeded()
    }

    var buttonCenter: NSPoint {
        button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
    }

    func rowPoint(_ row: Int) -> NSPoint {
        let rect = table.rect(ofRow: row)
        return table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
    }

    func close() {
        window.close()
    }

    nonisolated func numberOfRows(in tableView: NSTableView) -> Int { 5 }

    nonisolated func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        "Song \(row + 1)"
    }
}
