import AppKit
import SwiftUI
import XCTest
@testable import Spotiglass

/// Scrolling a playlist of a couple of thousand songs stuttered instead of following the
/// trackpad, and clicking in it lagged (#655). Every frame of a scroll, slow or a fast flick,
/// while the covers are still loading, and every click, selection, right-click and start of
/// playback has to show within 50 ms.
///
/// What made it slow is checked on every run: the table guessed most rows at 24 points and kept
/// growing while it scrolled, the first scroll and every click ran the body of all 2,000 rows,
/// a click ran the whole window again, and each row's menu searched the whole playlist. The
/// times themselves are checked in an optimized build (`make test-speed`), where they mean what
/// someone using the app sees; a Debug build only reports them.
@MainActor
final class LongListScrollCostTests: XCTestCase {
    private static let trackCount = 2_000
    private static let coverCount = 64
    nonisolated private static let budget: TimeInterval = 0.050
    /// Times only mean something in an optimized build; a Debug one takes several times as long.
    private static let checksTimes = !_isDebugAssertConfiguration()

    private var coverURLs: [URL] = []
    /// Whether this machine hands a posted click to the test's window (``click(_:row:modifiers:)``).
    private var clicksReachTheWindow = true

    override func tearDown() {
        ViewBodyTally.counts = nil
        SpotiglassL10n.settingsStore = nil
        ViewTestHost.tearDownAll()
        // The artwork store keeps a copy of each cover it loaded in the app's own cache.
        for url in coverURLs {
            try? FileManager.default.removeItem(at: ArtworkImageStore.cacheFileURL(for: url, diskDirectory: ArtworkImageStore.defaultDiskDirectory))
        }
        super.tearDown()
    }

    // MARK: - Scrolling

    func testScrollingABigPlaylistKeepsEveryFrameUnder50ms() async throws {
        let host = try await hostBigPlaylist()
        let table = host.table

        // The table knows every row's height before it scrolls: guessed at 24 points, a
        // 2,000-song playlist started at half its height and grew under the pointer.
        let rowHeight = table.rect(ofRow: 0).height
        XCTAssertEqual(table.rect(ofRow: Self.trackCount - 1).maxY, rowHeight * CGFloat(Self.trackCount), accuracy: rowHeight,
                       "the table doesn't know where its last row is before scrolling")

        ViewBodyTally.counts = [:]
        let firstFrame = scrollFrame(host, by: 260)
        let rowsBuiltByFirstFrame = rowBodies()
        XCTAssertLessThan(rowsBuiltByFirstFrame, 50, "the first frame of a scroll built \(rowsBuiltByFirstFrame) rows")

        // The rows on screen have their menus prepared (whether a song is liked) once they stop
        // changing for a moment (#689). The answer for the rows shown so far comes in first.
        await prepareMenusOfTheRowsOnScreen(host)
        let lookupsBefore = host.api.savedTrackStatusesCalls.count
        ViewBodyTally.counts = [:]
        // Flicks through the first 1,000 songs: the whole list in a Debug build on CI comes close
        // to the two minutes a test may take there.
        let flick = scrollToBottom(host, flick: true, stoppingAt: rowHeight * 1_000)
        XCTAssertNil(ViewBodyTally.counts?["TrackListRows"], "scrolling walked all the rows again")
        XCTAssertNil(ViewBodyTally.counts?["PlaylistDetailContent"], "scrolling ran the playlist page again")
        // A scroll with the mouse wheel or the arrow keys: new rows come on screen in turn after turn
        // of the run loop. None of them sends a lookup while the rows keep changing; once they stop,
        // one lookup asks for the rows on screen.
        for _ in 0..<30 {
            _ = scrollFrame(host, by: 40)
            await AppKitTestSupport.settle(passes: 1)
        }
        XCTAssertEqual(host.api.savedTrackStatusesCalls.count, lookupsBefore, "a scroll looked up liked songs while it scrolled")
        await prepareMenusOfTheRowsOnScreen(host)
        XCTAssertEqual(host.api.savedTrackStatusesCalls.count, lookupsBefore + 1, "the end of the scroll didn't look up the rows on screen once")
        XCTAssertLessThan(host.api.savedTrackStatusesCalls.last?.count ?? 0, 50, "the lookup asked for rows that are off screen")
        XCTAssertEqual(table.rect(ofRow: Self.trackCount - 1).maxY, rowHeight * CGFloat(Self.trackCount), accuracy: rowHeight,
                       "the table's height changed while it scrolled")

        // A slow scroll through 300 songs in the middle: all 2,000 at this pace is about 18,000
        // frames, longer than a Debug build on CI may take for one test.
        let slowStart = rowHeight * 800
        scrollTo(host, y: slowStart)
        let slow = scrollToBottom(host, flick: false, stoppingAt: slowStart + rowHeight * 300)

        // The covers were real pictures that loaded, not placeholders for ones that failed.
        let cover = await ArtworkImageStore.shared.image(for: coverURLs[1])
        XCTAssertNotNil(cover, "the covers didn't load")

        let report = String(format: "first frame %.1f ms; flick: %@; slow: %@", firstFrame * 1000, flick.summary, slow.summary)
        XCTContext.runActivity(named: "LongListScroll \(report)") { _ in }
        print("LongListScroll \(report)")
        if Self.checksTimes {
            XCTAssertLessThanOrEqual(firstFrame, Self.budget, report)
            XCTAssertEqual(flick.over, 0, report)
            XCTAssertEqual(slow.over, 0, report)
        }
    }

    // MARK: - Language

    /// The list keeps the rows whose song and selection didn't change instead of building them
    /// again. A language switch changes neither, so the rows have to follow it by themselves:
    /// each looks its text up while its body runs, which ties it to the app language (#548).
    func testALanguageSwitchRedrawsTheRowsTheListKeeps() async throws {
        let store = try ViewTestHost.makeSettingsStore()
        SpotiglassL10n.settingsStore = store
        try store.mutate { $0.appearance.language = .english }
        let host = try await hostBigPlaylist(language: store)
        let visible = host.table.rows(in: host.table.visibleRect)
        XCTAssertGreaterThan(visible.length, 5)

        ViewBodyTally.counts = [:]
        try store.mutate { $0.appearance.language = .german }
        await AppKitTestSupport.settle()

        XCTAssertNil(ViewBodyTally.counts?["TrackListRows"], "the list built its rows again, so this didn't test the rows it keeps")
        let stale = (visible.location..<(visible.location + visible.length)).filter {
            ViewBodyTally.counts?["TrackListRow:t\($0)"] == nil
        }
        XCTAssertEqual(stale, [], "these rows on screen kept their English text")
    }

    // MARK: - Clicks, selection, menu, playback

    func testClickingSelectingRightClickingAndPlayingShowWithin50ms() async throws {
        let host = try await hostBigPlaylist()
        // Somewhere in the middle, as after a scroll.
        for _ in 0..<200 { _ = scrollFrame(host, by: 260) }
        await AppKitTestSupport.settle()
        let table = host.table
        let visible = table.rows(in: table.visibleRect)
        let middle = visible.location + visible.length / 2
        let browser = host.browser
        var times: [(String, TimeInterval)] = []

        func measure(
            _ name: String, showsInPlayerBar: Bool = false, buildsEveryRow: Bool = false, _ change: () -> Void,
            file: StaticString = #filePath, line: UInt = #line
        ) {
            ViewBodyTally.counts = [:]
            times.append((name, timeToShow(host.window, change)))
            let counts = ViewBodyTally.counts ?? [:]
            // A click is the table's business: the window, the sidebar and the player bar ran
            // again on every one, and the table ran the body of every row.
            let outside = ["PlaylistBrowserView", "PlaylistBrowserSidebar", "PlaylistBrowserMainDetailColumn", "PlaylistDetailContent"]
                + (showsInPlayerBar ? [] : ["BrowserTransportBar"])
            for outside in outside {
                XCTAssertNil(counts[outside], "\(name) ran \(outside) again", file: file, line: line)
            }
            if !buildsEveryRow {
                XCTAssertLessThan(rowBodies(), 50, "\(name) built \(rowBodies()) rows", file: file, line: line)
            }
            // The rows follow the selection by themselves. Building the list of rows again made the
            // table go through all 2,000 of them, the most of a first click's 55 ms (#689).
            XCTAssertNil(counts["TrackListRows"], "\(name) built the list of rows again", file: file, line: line)
        }

        // Clicks go through the app's event queue the way the mouse's do. In the app the table
        // doesn't have the keyboard before the first click (the sidebar does), so neither does
        // it here; that click selects the row and gives the table the keyboard (#628). It is the
        // one that was slow: about 55 ms against 20 for every later click (#689). The table takes
        // the keyboard from AppKit now: SwiftUI's own focus state stayed behind when the keyboard
        // left outside SwiftUI, and then a click sometimes didn't hand it back (#748).
        host.window.makeFirstResponder(nil)
        measure("click") { click(host, row: middle) }
        XCTAssertEqual(browser.selectedDetailTrackIDs, ["t\(middle)"], "the click didn't select its row")
        XCTAssertNotNil(ViewBodyTally.counts?["TrackListRow:t\(middle)"], "the clicked row didn't show it is selected")
        // The keyboard comes with the click itself, so only a machine that hands the window its
        // clicks can tell.
        if clicksReachTheWindow {
            XCTAssertTrue(host.window.firstResponder === table, "the click left the table without the keyboard")
        }
        measure("click another") { click(host, row: middle + 1) }
        XCTAssertEqual(browser.selectedDetailTrackIDs, ["t\(middle + 1)"])
        // A shift-click, as the table makes it: SwiftUI reads the shift key from the keyboard
        // itself, which a test can't press. The table proposes the range and SwiftUI builds each
        // row it proposes, so this is still over 50 ms (#694).
        measure("shift-click 30", buildsEveryRow: true) {
            table.selectRowIndexes(IndexSet(integersIn: (middle + 1)...(middle + 30)), byExtendingSelection: false)
        }
        XCTAssertEqual(browser.selectedDetailTrackIDs.count, 30, "shift-click didn't select the range")
        measure("click one") { click(host, row: middle) }
        XCTAssertEqual(browser.selectedDetailTrackIDs, ["t\(middle)"])

        // A right-click: the menu the table hands AppKit for the row, built in full.
        let rowRect = table.rect(ofRow: middle)
        let point = table.convert(NSPoint(x: rowRect.midX, y: rowRect.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: host.window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        var menu: NSMenu?
        measure("right-click") {
            // The view under the pointer, or the first one around it, that has a menu there.
            var view = host.window.contentView?.hitTest(point)
            while let current = view, menu == nil {
                menu = current.menu(for: event)
                view = current.superview
            }
            if let menu { menu.delegate?.menuNeedsUpdate?(menu) }
        }
        XCTAssertGreaterThan(menu?.items.count ?? 0, 3, "the right-click built no menu")

        // Starting a song in the list: the row and the player bar show it.
        let nowPlaying = PlaybackNowPlaying(
            name: "Song", artists: ["Artist"], albumName: nil, albumID: nil, albumArtURL: nil,
            durationMilliseconds: 180_000, positionMilliseconds: 0, uri: "spotify:track:t\(middle)"
        )
        measure("start playback", showsInPlayerBar: true) { host.playback.setConnectionState(.playing(nowPlaying)) }
        measure("pause", showsInPlayerBar: true) { host.playback.setConnectionState(.paused(nowPlaying)) }

        // ⌘A on the table, last: it builds every row it selects, and takes seconds (#694).
        measure("select all", buildsEveryRow: true) { table.selectAll(nil) }
        XCTAssertEqual(browser.selectedDetailTrackIDs.count, Self.trackCount)

        let report = times.map { String(format: "%@ %.1f ms", $0.0, $0.1 * 1000) }.joined(separator: ", ")
            + (clicksReachTheWindow ? "" : " (clicks made by the table: this machine doesn't hand posted clicks to the window)")
        XCTContext.runActivity(named: "LongListInteractions \(report)") { _ in }
        print("LongListInteractions \(report)")
        if Self.checksTimes {
            for (name, time) in times {
                XCTAssertLessThanOrEqual(time, Self.budget, "\(name): \(report)")
            }
        }
    }

    // MARK: - Hosting

    private struct Host {
        let window: NSWindow
        let scrollView: NSScrollView
        let table: NSTableView
        let browser: PlaylistBrowserViewModel
        let playback: PlaybackSessionViewModel
        let api: MockBrowsingAPI
        /// The clock menu preparation waits on for the rows on screen to settle.
        let menuClock: ManualPlaybackClock
    }

    /// Lets the rows on screen settle on the menu clock and waits for their lookup.
    private func prepareMenusOfTheRowsOnScreen(_ host: Host) async {
        await AppKitTestSupport.settle()
        let armed = await host.menuClock.waitForSleepers(1)
        XCTAssertTrue(armed, "the rows on screen never waited to have their menus prepared")
        let before = host.api.savedTrackStatusesCalls.count
        host.menuClock.advance(by: PlaylistBrowserViewModel.menuPreparationSettle)
        let lookedUp = await AppKitTestSupport.settle(until: { host.api.savedTrackStatusesCalls.count > before })
        XCTAssertTrue(lookedUp, "the rows on screen weren't looked up")
        await AppKitTestSupport.settle()
    }

    /// Covers the size Spotify sends (640 px), each its own picture so none decodes for free.
    /// They sit in the artwork store's disk cache under addresses no earlier run used, so every
    /// row loads and decodes its cover for real, off the network.
    private func makeCovers() throws -> [URL] {
        let run = UUID().uuidString
        var urls: [URL] = []
        for index in 0..<Self.coverCount {
            let rep = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 640, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep)?.cgContext)
            var generator = SystemRandomNumberGenerator()
            for _ in 0..<200 {
                context.setFillColor(CGColor(
                    red: .random(in: 0...1, using: &generator),
                    green: .random(in: 0...1, using: &generator),
                    blue: .random(in: 0...1, using: &generator),
                    alpha: 1
                ))
                context.fillEllipse(in: CGRect(
                    x: .random(in: -100...640, using: &generator), y: .random(in: -100...640, using: &generator),
                    width: .random(in: 20...200, using: &generator), height: .random(in: 20...200, using: &generator)
                ))
            }
            let data = try XCTUnwrap(rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]))
            let url = try XCTUnwrap(URL(string: "https://covers.invalid/\(run)/cover-\(index).jpg"))
            let cached = ArtworkImageStore.cacheFileURL(for: url, diskDirectory: ArtworkImageStore.defaultDiskDirectory)
            try FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: cached)
            urls.append(url)
        }
        coverURLs = urls
        return urls
    }

    private func track(_ index: Int, covers: [URL]) -> MusicPlaylistTrackItem {
        MusicPlaylistTrackItem(
            id: "t\(index)",
            content: .track(MusicTrack(
                id: "t\(index)",
                name: "Song number \(index) with a longer title",
                artists: ["Artist \(index % 97)", "Featured \(index % 13)"],
                artistRefs: [
                    MusicArtistRef(id: "a\(index % 97)", name: "Artist \(index % 97)"),
                    MusicArtistRef(id: "f\(index % 13)", name: "Featured \(index % 13)"),
                ],
                albumArtworkURL: covers[index % covers.count],
                durationMilliseconds: 180_000 + index,
                isExplicit: index % 5 == 0,
                isPlayable: true,
                linkedFromID: nil,
                uri: "spotify:track:t\(index)"
            ))
        )
    }

    /// The real browser with a 2,000-song playlist open and its first rows drawn.
    private func hostBigPlaylist(language: SpotiglassSettingsStore? = nil) async throws -> Host {
        let covers = try makeCovers()
        let tracks = (0..<Self.trackCount).map { track($0, covers: covers) }
        let api = MockBrowsingAPI(
            playlistResults: [.success([
                PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "Liked"),
                PlaylistBrowsingTestFixtures.playlist(id: "p2", name: "Daily"),
            ])],
            trackResults: ["p1": [.success(tracks)]]
        )
        let menuClock = ManualPlaybackClock()
        let browserVM = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache(), menuPreparationClock: menuClock)
        await browserVM.loadIfNeeded()
        await browserVM.selectPlaylist(id: "p1")
        XCTAssertEqual(PlaylistBrowsingTestFixtures.playlistTracks(browserVM.detailState).count, Self.trackCount)

        let store = PinnedItemsStore(cache: InMemoryPinnedItemsCache())
        store.bind(userID: "u1")
        // A stand-in Spotify player: no web page and no network.
        let playbackHost = SpotiglassPlaybackHost(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander())
        )
        let view = PlaylistBrowserView(
            viewModel: browserVM,
            playbackHost: playbackHost,
            catalogProvider: api,
            commandPaletteManager: CommandPaletteManager(),
            signOut: {}
        )
        .environmentObject(store)
        .environmentObject(LyricsOverlayController())
        .modifier(OptionalLanguage(store: language))
        ViewBodyTally.counts = [:]
        let controller = ViewTestHost.host(view, size: CGSize(width: 1_400, height: 900), takesClicks: true)
        let window = try XCTUnwrap(controller.view.window)
        // In the window list, off screen, so the app hands it the clicks it is sent.
        window.orderFrontRegardless()
        XCTAssertTrue(
            AppKitTestSupport.pumpRunLoop(until: { ViewBodyTally.counts?["PlaybackControlsView"] != nil }),
            "the browser never rendered"
        )
        // The browser starts at a width of zero and collapses the sidebar; a widening brings it
        // back, as it does when a real window opens.
        window.setContentSize(NSSize(width: 1_450, height: 900))
        var table: NSTableView?
        XCTAssertTrue(AppKitTestSupport.pumpRunLoop(until: {
            table = AppKitTestSupport.tables(in: window.contentView).first { $0.numberOfRows >= Self.trackCount }
            return table != nil
        }), "the playlist's table never showed all \(Self.trackCount) songs")
        let found = try XCTUnwrap(table)
        let scrollView = try XCTUnwrap(found.enclosingScrollView)
        await AppKitTestSupport.settle()
        return Host(window: window, scrollView: scrollView, table: found, browser: browserVM, playback: playbackHost.playbackViewModel, api: api, menuClock: menuClock)
    }

    /// A click on `row`, posted to the app's event queue and handed out from it as the app's own
    /// event loop does, so the app sees it as the current event. GitHub's runners don't hand a
    /// posted click to the window; there the table selects the row itself, as its own click does,
    /// and the report says so.
    private func click(_ host: Host, row: Int, modifiers: NSEvent.ModifierFlags = []) {
        defer {
            if host.browser.selectedDetailTrackIDs != ["t\(row)"] {
                clicksReachTheWindow = false
                host.table.selectRowIndexes([row], byExtendingSelection: false)
            }
        }
        let rect = host.table.rect(ofRow: row)
        // On the title, clear of the cover and the hover play button.
        let point = host.table.convert(NSPoint(x: rect.minX + rect.width * 0.4, y: rect.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: host.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ) else { return XCTFail("no \(type) event") }
            NSApp.postEvent(event, atStart: false)
            while let next = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(next)
            }
        }
    }

    private func rowBodies() -> Int {
        (ViewBodyTally.counts ?? [:]).keys.filter { $0.hasPrefix("TrackListRow:") }.count
    }

    // MARK: - Measuring

    /// How long `change` takes to show: the change, then the window laying out and drawing,
    /// committing it, and whatever that set off on the main thread.
    private func timeToShow(_ window: NSWindow, _ change: () -> Void) -> TimeInterval {
        let start = CACurrentMediaTime()
        change()
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        RunLoop.current.run(mode: .default, before: Date())
        return CACurrentMediaTime() - start
    }

    private func maxScrollY(_ host: Host) -> CGFloat {
        max(0, (host.scrollView.documentView?.frame.height ?? 0) - host.scrollView.contentView.bounds.height)
    }

    private func scrollTo(_ host: Host, y: CGFloat) {
        host.scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        host.scrollView.reflectScrolledClipView(host.scrollView.contentView)
        AppKitTestSupport.settle()
    }

    /// One frame of a scroll as the trackpad makes it: the content moves by `delta`, then the
    /// window shows it. Returns how long the frame took.
    private func scrollFrame(_ host: Host, by delta: CGFloat) -> TimeInterval {
        let clip = host.scrollView.contentView
        return timeToShow(host.window) {
            var origin = clip.bounds.origin
            origin.y = min(max(0, origin.y + delta), maxScrollY(host))
            clip.scroll(to: origin)
            host.scrollView.reflectScrolledClipView(clip)
        }
    }

    private struct ScrollResult {
        var frames: [TimeInterval] = []
        var over: Int { frames.filter { $0 > LongListScrollCostTests.budget }.count }
        var summary: String {
            let sorted = frames.sorted()
            guard !sorted.isEmpty else { return "no frames" }
            return String(
                format: "%d frames, median %.1f ms, p95 %.1f ms, worst %.1f ms, %d over 50 ms",
                frames.count, sorted[sorted.count / 2] * 1000, sorted[min(sorted.count - 1, sorted.count * 95 / 100)] * 1000,
                (sorted.last ?? 0) * 1000, over
            )
        }
    }

    /// Scrolls from where it is to the bottom, or to `stoppingAt`: 6 points a frame, or flicks
    /// that start at 260 points a frame and slow down the way the trackpad's momentum does.
    private func scrollToBottom(_ host: Host, flick: Bool, stoppingAt end: CGFloat = .greatestFiniteMagnitude) -> ScrollResult {
        var result = ScrollResult()
        var velocity: CGFloat = flick ? 260 : 6
        let end = min(end, maxScrollY(host))
        while host.scrollView.contentView.bounds.origin.y < end - 1, result.frames.count < 20_000 {
            result.frames.append(scrollFrame(host, by: velocity))
            if flick {
                // Momentum keeps 95 % of the speed each frame; a new flick when it runs out.
                velocity *= 0.95
                if velocity < 20 { velocity = 260 }
            }
        }
        return result
    }
}

/// The app language over the hosted browser, as the main window puts it there, when a test gives one.
private struct OptionalLanguage: ViewModifier {
    let store: SpotiglassSettingsStore?

    func body(content: Content) -> some View {
        if let store { content.spotiglassLanguage(store) } else { content }
    }
}
