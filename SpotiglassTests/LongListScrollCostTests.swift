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

        ViewBodyTally.counts = [:]
        // Flicks through the first 1,000 songs: the whole list in a Debug build on CI comes close
        // to the two minutes a test may take there.
        let flick = scrollToBottom(host, flick: true, stoppingAt: rowHeight * 1_000)
        XCTAssertNil(ViewBodyTally.counts?["TrackListRows"], "scrolling walked all the rows again")
        XCTAssertNil(ViewBodyTally.counts?["PlaylistDetailContent"], "scrolling ran the playlist page again")
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
            _ name: String, showsInPlayerBar: Bool = false, _ change: () -> Void,
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
            XCTAssertLessThan(rowBodies(), 50, "\(name) built \(rowBodies()) rows", file: file, line: line)
        }

        // Clicks go through the app's event queue the way the mouse's do. In the app the table
        // doesn't have the keyboard before the first click (the sidebar does), so neither does it
        // here, and the first click includes the table taking the keyboard (#689). Whether it does
        // isn't checked: taking the keyboard away from outside SwiftUI leaves its focus state
        // behind, and the click then sometimes doesn't hand the keyboard back (#748).
        host.window.makeFirstResponder(nil)
        measure("click") { click(host, row: middle) }
        XCTAssertEqual(browser.selectedDetailTrackIDs, ["t\(middle)"], "the click didn't select its row")
        measure("click another") { click(host, row: middle + 1) }
        XCTAssertEqual(browser.selectedDetailTrackIDs, ["t\(middle + 1)"])
        // Shift-click and ⌘A are caught on their way to the window, so they're only checked where
        // posted events reach it (not on GitHub's runners).
        if clicksReachTheWindow {
            // A shift-click 29 songs further down, scrolled to as someone would: the 30 songs from the
            // last one clicked. When the table made this selection, SwiftUI built every row it added,
            // on screen or not (#694).
            let start = middle + 1
            // A song clicked, then the song the range starts from ⌘-clicked: the shift-click keeps
            // the first one, as the table does. The list notes the ⌘-click on its way to the table;
            // the table reads ⌘ from the keyboard, which a test can't press, so where it took the
            // click as a plain one the selection is set as its ⌘-click leaves it.
            let picked = "t\(start - 3)"
            click(host, row: start - 3)
            XCTAssertEqual(browser.selectedDetailTrackIDs, [picked])
            click(host, row: start, modifiers: .command)
            if browser.selectedDetailTrackIDs != [picked, "t\(start)"] {
                browser.selectedDetailTrackIDs = [picked, "t\(start)"]
            }
            await AppKitTestSupport.settle()
            scrollTo(host, y: host.scrollView.contentView.bounds.origin.y + table.rect(ofRow: start + 29).minY - table.rect(ofRow: start + 1).minY)
            measure("shift-click 30") { click(host, row: start + 29, modifiers: .shift) }
            XCTAssertEqual(
                browser.selectedDetailTrackIDs, Set((start...(start + 29)).map { "t\($0)" } + [picked]),
                "shift-click didn't select the songs from the last clicked one, next to the ⌘-clicked one"
            )
            // Another shift-click extends from the same song, not from the end of the range, and
            // swaps only the range.
            click(host, row: start + 27, modifiers: .shift)
            XCTAssertEqual(browser.selectedDetailTrackIDs, Set((start...(start + 27)).map { "t\($0)" } + [picked]))
            let back = host.scrollView.contentView.bounds.origin.y
            scrollTo(host, y: back - (table.rect(ofRow: start + 29).minY - table.rect(ofRow: start + 1).minY))
        }
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

        // ⌘A, pressed on the table. When the table selected them itself, SwiftUI built all
        // 2,000 rows and it took seconds (#694).
        if clicksReachTheWindow {
            XCTAssertTrue(host.window.firstResponder === table, "the table lost the keyboard")
            measure("select all") { press(host, "a", modifiers: .command) }
            XCTAssertEqual(browser.selectedDetailTrackIDs.count, Self.trackCount, "⌘A didn't select every song")
        }

        let report = times.map { String(format: "%@ %.1f ms", $0.0, $0.1 * 1000) }.joined(separator: ", ")
            + (clicksReachTheWindow ? "" : " (clicks made by the table, shift-click and ⌘A not checked: this machine doesn't hand posted events to the window)")
        XCTContext.runActivity(named: "LongListInteractions \(report)") { _ in }
        print("LongListInteractions \(report)")
        if Self.checksTimes {
            for (name, time) in times {
                XCTAssertLessThanOrEqual(time, Self.budget, "\(name): \(report)")
            }
        }
    }

    /// A shift-click selects the songs from the last song clicked without shift to the clicked
    /// one, up or down, next to songs picked with ⌘-click before, and the song alone when there's
    /// no such song in the list (#694). Checked
    /// here too, without the window: GitHub's runners don't hand posted clicks to it.
    func testAShiftClickSelectsFromTheLastClickedSong() throws {
        let covers = [try XCTUnwrap(URL(string: "https://covers.invalid/cover.jpg"))]
        let tracks = TrackRowViewModel.numberedPlaylistRows((0..<10).map { track($0, covers: covers) })
        let positions = TrackListSelectionShortcuts.positions(of: tracks)
        func extend(to row: Int, from anchor: Int?, keeping base: Set<String> = []) -> Set<String> {
            TrackListSelectionShortcuts.extend(
                to: "t\(row)", from: anchor.map { "t\($0)" }, keeping: base, positions: positions, tracks: tracks
            )
        }
        XCTAssertEqual(extend(to: 7, from: 3), ["t3", "t4", "t5", "t6", "t7"])
        XCTAssertEqual(extend(to: 1, from: 3), ["t1", "t2", "t3"])
        XCTAssertEqual(extend(to: 3, from: 3), ["t3"])
        XCTAssertEqual(extend(to: 5, from: nil), ["t5"])
        // Songs picked with ⌘-click before stay, as the table keeps them; one that left the list doesn't.
        XCTAssertEqual(extend(to: 7, from: 5, keeping: ["t1", "t5"]), ["t1", "t5", "t6", "t7"])
        XCTAssertEqual(extend(to: 6, from: 5, keeping: ["t1", "t5", "gone"]), ["t1", "t5", "t6"])
        XCTAssertEqual(
            TrackListSelectionShortcuts.extend(to: "t5", from: "gone", positions: positions, tracks: tracks), ["t5"],
            "an anchor that left the list still extended"
        )
    }

    /// Where a shift-click starts and what it keeps, against what a plain `NSTableView` does with
    /// the same clicks and keys posted through the event queue (#694). Runs everywhere: this is
    /// the bookkeeping the clicks go through on a Mac.
    func testShiftClicksKeepWhatTheTableKeeps() throws {
        let covers = [try XCTUnwrap(URL(string: "https://covers.invalid/cover.jpg"))]
        let tracks = TrackRowViewModel.numberedPlaylistRows((0..<20).map { track($0, covers: covers) })
        let positions = TrackListSelectionShortcuts.positions(of: tracks)
        func ids(_ rows: [Int]) -> Set<String> { Set(rows.map { "t\($0)" }) }
        var selection: Set<String> = []
        var state = TrackListShiftClick()
        // A click the table makes: it changes the selection, then the list hears of it.
        func click(_ row: Int, command: Bool = false, shift: Bool = false) {
            state.clicked("t\(row)", command: command, shift: shift, selection: selection)
            selection = !command ? ["t\(row)"] : shift ? selection.union(["t\(row)"]) : selection.symmetricDifference(["t\(row)"])
            state.selectionChanged(to: selection)
        }
        func shiftClick(_ row: Int) {
            selection = state.shiftClicked("t\(row)", positions: positions, tracks: tracks)
            state.selectionChanged(to: selection)
        }
        func tableSelects(_ rows: [Int]) {
            selection = ids(rows)
            state.selectionChanged(to: selection)
        }

        // ⌘-clicked songs stay; a second shift-click swaps only the range.
        click(2); click(5, command: true); shiftClick(10)
        XCTAssertEqual(selection, ids([2] + Array(5...10)))
        shiftClick(8)
        XCTAssertEqual(selection, ids([2] + Array(5...8)))
        shiftClick(0)
        XCTAssertEqual(selection, ids(Array(0...5)))

        // After ⌘A a shift-click selects the range from the last clicked song alone.
        click(4)
        selection = ids(Array(0..<20)); state.selectedAll(); state.selectionChanged(to: selection)
        shiftClick(8)
        XCTAssertEqual(selection, ids(Array(4...8)), "a shift-click after ⌘A kept every song")

        // After shift-arrow the range replaces what the arrows selected.
        click(5); tableSelects(Array(5...8)); shiftClick(2)
        XCTAssertEqual(selection, ids(Array(2...5)), "a shift-click after shift-arrow kept the arrows' songs")

        // A ⌘-click that takes a song out still moves where the next range starts.
        click(4); click(9, command: true); click(9, command: true)
        XCTAssertEqual(selection, ids([4]))
        shiftClick(12)
        XCTAssertEqual(selection, ids([4] + Array(9...12)))

        // A ⌘-shift-click adds its song alone and starts the next range there.
        click(2); click(5, command: true, shift: true); shiftClick(9)
        XCTAssertEqual(selection, ids([2] + Array(5...9)))

        // An arrow key moves the start.
        click(3); tableSelects([4]); shiftClick(6)
        XCTAssertEqual(selection, ids(Array(4...6)))

        // No start yet: the song alone, and the next shift-click extends from it.
        var fresh = TrackListShiftClick()
        XCTAssertEqual(fresh.shiftClicked("t7", positions: positions, tracks: tracks), ids([7]))
        fresh.selectionChanged(to: ids([7]))
        XCTAssertEqual(fresh.shiftClicked("t9", positions: positions, tracks: tracks), ids([7, 8, 9]))
    }

    /// Which song a row of the table is, with the rows that aren't songs above or below them: Home
    /// puts its greeting, quick access and shelves in one header row above its top tracks, and a
    /// playlist has its footer below the songs (#694).
    func testATableRowMapsToItsSongAroundHeaderAndFooterRows() {
        func index(_ row: Int, _ rowsAbove: TrackListSelectionShortcuts.RowsAboveTracks, rows: Int, tracks: Int) -> Int? {
            TrackListSelectionShortcuts.trackIndex(atRow: row, rowsAbove: rowsAbove, rowCount: rows, trackCount: tracks)
        }
        // No header: the songs are the table's first rows, a footer row after them is no song.
        XCTAssertEqual(index(0, .noRows, rows: 10, tracks: 10), 0)
        XCTAssertEqual(index(9, .noRows, rows: 10, tracks: 10), 9)
        XCTAssertNil(index(10, .noRows, rows: 11, tracks: 10), "a footer row was taken for a song")
        // A header row above the songs, as on Home.
        XCTAssertNil(index(0, .allOtherRows, rows: 11, tracks: 10), "the header row was taken for a song")
        XCTAssertEqual(index(1, .allOtherRows, rows: 11, tracks: 10), 0)
        XCTAssertEqual(index(10, .allOtherRows, rows: 11, tracks: 10), 9)
        // Rows the table doesn't have, and a table that doesn't hold all the songs yet.
        XCTAssertNil(index(-1, .noRows, rows: 10, tracks: 10))
        XCTAssertNil(index(11, .allOtherRows, rows: 11, tracks: 10))
        XCTAssertNil(index(0, .allOtherRows, rows: 5, tracks: 10))
    }

    // MARK: - Hosting

    private struct Host {
        let window: NSWindow
        let scrollView: NSScrollView
        let table: NSTableView
        let browser: PlaylistBrowserViewModel
        let playback: PlaybackSessionViewModel
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
        let browserVM = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
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
        return Host(window: window, scrollView: scrollView, table: found, browser: browserVM, playback: playbackHost.playbackViewModel)
    }

    /// A click on `row`, posted to the app's event queue and handed out from it as the app's own
    /// event loop does, so the app sees it as the current event. GitHub's runners don't hand a
    /// posted click to the window; there the table selects the row itself, as its own click does,
    /// and the report says so.
    private func click(_ host: Host, row: Int, modifiers: NSEvent.ModifierFlags = []) {
        defer {
            if modifiers.isEmpty, host.browser.selectedDetailTrackIDs != ["t\(row)"] {
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

    /// A key press posted to the app's event queue and handed out from it, like `click`.
    private func press(_ host: Host, _ key: String, modifiers: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: host.window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key,
                isARepeat: false, keyCode: 0
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
