import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Spotiglass

/// ⌘S hides or shows the sidebar within 50 ms (#672). It took 80-100 ms because one toggle
/// rendered the whole browser (the sidebar, the page and every visible track row) several times
/// over before the first frame: three times to hide it and six to show it. The visibility the
/// toggle set was written back by the split view itself (`.doubleColumn` became `.all`), and
/// `isSidebarShown` re-rendered everything that observes the browser's model. These replay one
/// ⌘S on the real browser window with a playlist open and count what ran.
@MainActor
final class SidebarToggleRenderScopeTests: XCTestCase {
    override func tearDown() {
        ViewBodyTally.counts = nil
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    private static let trackIDs = (1...20).map { "t\($0)" }

    /// The real browser window, wide enough for the sidebar, with a 20-track playlist open.
    private func hostBrowser() async throws -> (CommandPaletteManager, PlaylistBrowserViewModel) {
        let api = MockBrowsingAPI(
            playlistResults: [.success([
                PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "Focus"),
                PlaylistBrowsingTestFixtures.playlist(id: "p2", name: "Daily"),
                PlaylistBrowsingTestFixtures.playlist(id: "p3", name: "Gym"),
            ])],
            trackResults: ["p1": [.success(Self.trackIDs.map(PlaylistBrowsingTestFixtures.track(id:)))]]
        )
        let browserVM = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await browserVM.load()
        await browserVM.selectPlaylist(id: "p1")
        let store = PinnedItemsStore(cache: InMemoryPinnedItemsCache())
        store.bind(userID: "u1")
        let tokens = SidebarToggleTokenProvider()
        let palette = CommandPaletteManager()
        let view = PlaylistBrowserView(
            viewModel: browserVM,
            playbackHost: SpotiglassPlaybackHost(tokenProvider: tokens),
            catalogProvider: SpotifyAPIClient(tokenProvider: tokens, getResponseCache: .shared),
            commandPaletteManager: palette,
            signOut: {}
        )
        .environmentObject(store)
        .environmentObject(LyricsOverlayController())
        let controller = ViewTestHost.host(view, size: CGSize(width: 1_600, height: 1_000))
        await AppKitTestSupport.settle()
        // The browser starts at a width of zero and collapses the sidebar; a widening brings it
        // back, as it does when a real window opens.
        controller.view.window?.setContentSize(NSSize(width: 1_700, height: 1_000))
        await AppKitTestSupport.settle()
        XCTAssertTrue(browserVM.isSidebarShown)
        XCTAssertEqual(palette.isSidebarVisible, true)
        return (palette, browserVM)
    }

    /// Runs one ⌘S (the command it runs) and returns which counted bodies ran because of it: it
    /// waits until the toggle rendered, then until everything it queued has run, so a render that
    /// comes late still counts. The menu's title follows on a timer, waited for too.
    private func bodiesAfterToggling(
        _ palette: CommandPaletteManager, line: UInt = #line
    ) async -> [String: Int] {
        ViewBodyTally.counts = [:]
        let wasVisible = palette.isSidebarVisible
        palette.execute(commandID: CommandPaletteCommandID.toggleSidebar)
        let rendered = await AppKitTestSupport.settle(until: { !(ViewBodyTally.counts ?? [:]).isEmpty })
        XCTAssertTrue(rendered, "the toggle rendered nothing", line: line)
        let followed = await AppKitTestSupport.settle(until: { palette.isSidebarVisible != wasVisible })
        XCTAssertTrue(followed, "the View menu's title never followed", line: line)
        await AppKitTestSupport.settle()
        defer { ViewBodyTally.counts = nil }
        return ViewBodyTally.counts ?? [:]
    }

    private func assertRenderedOnce(_ counts: [String: Int], _ what: String, line: UInt = #line) {
        for view in ["PlaylistBrowserView", "PlaylistBrowserSidebar", "PlaylistBrowserMainDetailColumn", "PlaylistDetailContent"] {
            XCTAssertLessThanOrEqual(counts[view] ?? 0, 1, "\(view) rendered \(counts[view] ?? 0) times to \(what)", line: line)
        }
        for id in Self.trackIDs {
            let runs = counts["TrackListRow:\(id)"] ?? 0
            XCTAssertLessThanOrEqual(runs, 1, "track row \(id) rendered \(runs) times to \(what)", line: line)
        }
    }

    func testHidingAndShowingTheSidebarRendersTheBrowserOnce() async throws {
        let (palette, browser) = try await hostBrowser()

        let hide = await bodiesAfterToggling(palette)
        XCTAssertFalse(browser.isSidebarShown, "⌘S hides the sidebar")
        XCTAssertEqual(palette.isSidebarVisible, false, "the View menu says Show Sidebar")
        assertRenderedOnce(hide, "hide the sidebar")

        let show = await bodiesAfterToggling(palette)
        XCTAssertTrue(browser.isSidebarShown, "⌘S shows it again")
        XCTAssertEqual(palette.isSidebarVisible, true, "the View menu says Hide Sidebar")
        assertRenderedOnce(show, "show the sidebar")

        // And again: the second round is where the split view's own write used to come back.
        assertRenderedOnce(await bodiesAfterToggling(palette), "hide the sidebar a second time")
        assertRenderedOnce(await bodiesAfterToggling(palette), "show the sidebar a second time")
        XCTAssertTrue(browser.isSidebarShown)
    }

    /// The View menu's Show/Hide Sidebar title comes from the palette manager, and the window
    /// observes the manager: a change of it re-rendered the whole window and rebuilt the menu
    /// bar in the same pass as the sidebar's first frame, 20-30 ms more before it showed. The
    /// title now follows on a timer, which a real key press only reaches once that frame is
    /// committed (`scripts/latency-test.sh` times that part in the Release app).
    func testTheMenusSidebarStateFollowsTheSidebarInsteadOfHoldingUpItsFrame() async throws {
        let (palette, browser) = try await hostBrowser()
        var announced = 0
        let watch = palette.objectWillChange.sink { announced += 1 }
        defer { watch.cancel() }

        palette.execute(commandID: CommandPaletteCommandID.toggleSidebar)
        XCTAssertEqual(announced, 0, "the manager changed in the key press, before the sidebar's frame")
        XCTAssertEqual(palette.isSidebarVisible, true)

        let followed = await AppKitTestSupport.settle(until: { palette.isSidebarVisible == false })
        XCTAssertTrue(followed, "the View menu says Show Sidebar")
        XCTAssertFalse(browser.isSidebarShown)
        XCTAssertEqual(announced, 1, "the View menu hears it once")
    }

    // MARK: - A rename waiting for the sidebar (#478)

    private let emptyPlaylist = MusicPlaylistSummary(
        id: "mine", name: "Road Trip", ownerID: "me", ownerName: "Me", imageURL: nil, trackCount: 0, snapshotID: "s1"
    )

    private func browserWithEmptyPlaylist() -> PlaylistBrowserViewModel {
        let api = MockBrowsingAPI(
            playlistResults: [.success([emptyPlaylist])], trackResults: [emptyPlaylist.id: [.success([])]]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        viewModel.currentUserID = "me"
        viewModel.playlistsByID = [emptyPlaylist.id: emptyPlaylist]
        viewModel.playlistState = .loaded([PlaylistRowViewModel(emptyPlaylist)])
        return viewModel
    }

    /// The sidebar row of an empty playlist takes its rename, and waits while the sidebar is
    /// hidden. `isSidebarShown` no longer re-renders the browser by itself, so the row still has
    /// to hear that the sidebar came back.
    func testARenameWaitingForTheHiddenSidebarReachesItsRowWhenTheSidebarShows() async {
        let viewModel = browserWithEmptyPlaylist()
        viewModel.isSidebarShown = false
        await viewModel.openPlaylistForNameEditing(emptyPlaylist)
        XCTAssertNil(viewModel.sidebarPlaylistNameEditRequestID, "a hidden sidebar's row can't edit")

        var announced = 0
        let watch = viewModel.objectWillChange.sink { announced += 1 }
        viewModel.isSidebarShown = true
        watch.cancel()

        XCTAssertEqual(announced, 1, "the sidebar's rows hear that it shows")
        XCTAssertEqual(viewModel.sidebarPlaylistNameEditRequestID, emptyPlaylist.id)
    }

    func testTheSidebarShowingOrHidingWithNoRenameWaitingAnnouncesNothing() {
        let viewModel = browserWithEmptyPlaylist()
        var announced = 0
        let watch = viewModel.objectWillChange.sink { announced += 1 }
        viewModel.isSidebarShown = false
        viewModel.isSidebarShown = true
        watch.cancel()
        XCTAssertEqual(announced, 0, "nothing else reads it, so nothing else re-renders")
    }
}

private final class SidebarToggleTokenProvider: PlaybackAccessTokenProviding, SpotifyAccessTokenProviding {
    func playbackAccessToken() async throws -> String { "sidebar-toggle-token" }
    func refreshedPlaybackAccessToken() async throws -> String { "sidebar-toggle-token" }
    func accessToken() async throws -> String { "sidebar-toggle-token" }
    func refreshAccessTokenAfterUnauthorized(rejectedToken: String) async throws -> String { "sidebar-toggle-token" }
}
