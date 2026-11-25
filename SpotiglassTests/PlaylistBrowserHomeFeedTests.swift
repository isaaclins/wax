import SwiftUI
import ViewInspector
import XCTest
@testable import Spotiglass

@MainActor
final class PlaylistBrowserHomeFeedTests: XCTestCase {
    private func recentlyPlayedTrack(id: String, albumID: String, albumName: String) -> MusicTrack {
        MusicTrack(
            id: id,
            name: "Track \(id)",
            artists: ["Artist"],
            artistRefs: [MusicArtistRef(id: "ar", name: "Artist")],
            albumArtworkURL: nil,
            albumName: albumName,
            albumID: albumID,
            durationMilliseconds: 180_000,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: "spotify:track:\(id)"
        )
    }

    func testQuickAccessListsLikedSongsThenPlaylists() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([
                PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One"),
                PlaylistBrowsingTestFixtures.playlist(id: "two", name: "Two"),
            ])],
            trackResults: [:]
        )
        let vm = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await vm.load()

        let cards = vm.homeQuickAccessCards
        XCTAssertEqual(cards.first?.destination, .likedSongs)
        XCTAssertEqual(cards.map(\.title), ["Liked Songs", "One", "Two"])
        XCTAssertEqual(cards.dropFirst().map(\.destination), [.playlist(id: "one"), .playlist(id: "two")])
    }

    /// Library rows outlive a language switch (the cache is fresh for 30 minutes), so the Home
    /// card must resolve my Apple Music library's "You" where it's shown, like the sidebar (#398).
    func testQuickAccessShowsMyLibraryOwnerInTheAppLanguage() async throws {
        let api = MockBrowsingAPI(
            playlistResults: [.success([
                MusicPlaylistSummary(
                    id: "p.mine", name: "Road", ownerID: AppleMusicBrowsingProvider.libraryUserID,
                    ownerName: "You", imageURL: nil, trackCount: 3, snapshotID: "applemusic"
                ),
                PlaylistBrowsingTestFixtures.playlist(id: "spotify", name: "Spotify"),
            ])],
            trackResults: [:]
        )
        let vm = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await vm.load()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("home-owner-\(UUID().uuidString).json")
        let store = SpotiglassSettingsStore(fileURL: url)
        try store.mutate { $0.appearance.language = .german }
        SpotiglassL10n.settingsStore = store
        defer { SpotiglassL10n.settingsStore = nil }

        XCTAssertEqual(vm.homeQuickAccessCards.dropFirst().map(\.subtitle), ["Du", "Owner"])
    }

    func testHomeTopTrackOptionsUseTheRowTargetWithoutMove() throws {
        let track = TrackRowViewModel.numberedTopTracks([
            recentlyPlayedTrack(id: "home-track", albumID: "home-album", albumName: "Home Album")
        ])[0]
        let browserViewModel = PlaylistBrowserViewModel(
            api: MockBrowsingAPI(playlistResults: [], trackResults: [:]),
            cache: MockBrowsingCache()
        )
        browserViewModel.detailState = .loaded(.home)
        let menu = TrackOpsMenuItems(
            targets: [track],
            browserViewModel: browserViewModel,
            sourcePlaylistID: nil
        )
        .environmentObject(PinnedItemsStore(cache: InMemoryPinnedItemsCache()))

        XCTAssertNoThrow(try menu.inspect().find(text: SpotiglassL10n.string("browser.addToPlaylist")))
        XCTAssertThrowsError(
            try menu.inspect().find(text: SpotiglassL10n.string("browser.moveToPlaylist"))
        )
    }

    func testSelectingHomeLoadsTopTracksAndMarksHomeContent() async {
        let api = MockBrowsingAPI(playlistResults: [.success([])], trackResults: [:])
        api.topTracksHandler = { _, _ in
            [self.recentlyPlayedTrack(id: "t1", albumID: "al1", albumName: "Album 1")]
        }
        let vm = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await vm.load()
        await vm.selectSidebar(.home)

        XCTAssertEqual(vm.detailState, .loaded(.home))
        XCTAssertEqual(vm.homeTopTracks.value?.map(\.title), ["Track t1"])
        XCTAssertEqual(api.topTracksCallCount, 2)
    }

    /// Selected top tracks on Home are what the menu bar's Add to Queue and Pin act on, as in every
    /// other track list. Home kept its own selection, so with two top tracks selected those
    /// commands stayed greyed out and the right-click menu only saw its own row (#173).
    func testSelectedHomeTopTracksAreWhatTheMenuBarActsOn() async throws {
        let api = MockBrowsingAPI(playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])], trackResults: [:])
        api.topTracksHandler = { _, _ in
            ["t1", "t2", "t3"].map { self.recentlyPlayedTrack(id: $0, albumID: "al-\($0)", albumName: "Album \($0)") }
        }
        let vm = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await vm.load()
        await vm.selectSidebar(.home)
        let rows = try XCTUnwrap(vm.homeTopTracks.value)
        XCTAssertEqual(rows.map(\.title), ["Track t1", "Track t2", "Track t3"])

        // As the track table writes it when the listener clicks the third row, then ⌘-clicks the first.
        vm.selectedDetailTrackIDs = [rows[2].id, rows[0].id]

        XCTAssertEqual(vm.selectedTrackRows.map(\.title), ["Track t1", "Track t3"])
        XCTAssertTrue(PlaylistBrowserView.canEnqueueTrackSelection(rows: vm.selectedTrackRows, hasPlaybackDevice: true))
        XCTAssertEqual(vm.effectiveTrackTargets(forRowID: rows[2].id).map(\.title), ["Track t1", "Track t3"])

        // Leaving Home drops the selection, like leaving any other list.
        await vm.selectSidebar(.playlist("one"))
        XCTAssertTrue(vm.selectedDetailTrackIDs.isEmpty)
    }

    /// A Home refresh that drops a selected song takes it out of the selection, so the menu bar
    /// doesn't offer Add to Queue for a song that is no longer listed (#173).
    func testRefreshingHomeDropsSelectedTopTracksThatAreGone() async throws {
        var refreshed = false
        let api = MockBrowsingAPI(
            playlistResults: [.success([]), .success([])],
            trackResults: [:]
        )
        api.topTracksHandler = { _, _ in
            (refreshed ? ["t2", "t3"] : ["t1", "t2"]).map { self.recentlyPlayedTrack(id: $0, albumID: "al-\($0)", albumName: "Album \($0)") }
        }
        let vm = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await vm.load()
        await vm.selectSidebar(.home)
        let rows = try XCTUnwrap(vm.homeTopTracks.value)
        vm.selectedDetailTrackIDs = Set(rows.map(\.id))

        refreshed = true
        await vm.reloadHomeSections(forceRefresh: true)

        let kept = try XCTUnwrap(vm.homeTopTracks.value).filter { vm.selectedDetailTrackIDs.contains($0.id) }
        XCTAssertEqual(kept.map(\.title), ["Track t2"])
        XCTAssertEqual(vm.selectedDetailTrackIDs.count, 1, "the dropped song's id stayed selected")
    }

    /// The menu bar's Add to Queue follows the top tracks through the real browser: on with a
    /// selected top track, off while a refresh reloads them and after a refresh fails, when there
    /// is nothing left to add (#173).
    func testMenuBarAddToQueueFollowsHomeTopTracksThroughARefresh() async throws {
        ViewBodyTally.counts = [:]
        defer {
            ViewBodyTally.counts = nil
            ViewTestHost.tearDownAll()
        }
        var refresh: CheckedContinuation<Void, Never>?
        var failRefresh = false
        let api = MockBrowsingAPI(playlistResults: [.success([]), .success([])], trackResults: [:])
        api.topTracksHandler = { _, _ in
            if failRefresh {
                await withCheckedContinuation { refresh = $0 }
                throw URLError(.notConnectedToInternet)
            }
            return ["t1", "t2"].map { self.recentlyPlayedTrack(id: $0, albumID: "al-\($0)", albumName: "Album \($0)") }
        }
        let browserVM = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await browserVM.loadIfNeeded()
        await browserVM.selectSidebar(.home)
        let rows = try XCTUnwrap(browserVM.homeTopTracks.value)

        let playbackHost = SpotiglassPlaybackHost(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander())
        )
        let playback = playbackHost.playbackViewModel
        playback.deviceID = "device-1"
        playback.hasTransferredPlaybackToCurrentDevice = true
        playback.setTransportStateKnown(true)
        playback.setConnectionState(.paused(PlaybackNowPlaying(
            name: "Midnight City", artists: ["M83"], albumName: "Hurry Up, We're Dreaming", albumID: nil,
            albumArtURL: nil, durationMilliseconds: 243_000, positionMilliseconds: 60_000, uri: "spotify:track:t9"
        )))
        let palette = CommandPaletteManager()
        let store = PinnedItemsStore(cache: InMemoryPinnedItemsCache())
        store.bind(userID: "u1")
        _ = ViewTestHost.host(
            PlaylistBrowserView(
                viewModel: browserVM,
                playbackHost: playbackHost,
                catalogProvider: api,
                commandPaletteManager: palette,
                signOut: {}
            )
            .environmentObject(store)
            .environmentObject(LyricsOverlayController()),
            size: CGSize(width: 1_200, height: 800)
        )

        // As the app does once the browser is up: its own load runs, then a row is clicked.
        XCTAssertTrue(AppKitTestSupport.pumpRunLoop(until: { ViewBodyTally.counts?["TrackListRow:\(rows[0].id)"] != nil }), "Home's rows never came on screen")
        browserVM.selectedDetailTrackIDs = [rows[0].id]
        XCTAssertTrue(
            AppKitTestSupport.pumpRunLoop(until: { palette.canEnqueueTrackSelection }),
            "Add to Queue stayed off for a selected top track: selection \(browserVM.selectedDetailTrackIDs), rows \(browserVM.selectedTrackRows.count), page \(String(describing: browserVM.detailState.currentValue))"
        )

        failRefresh = true
        let reload = Task { await browserVM.reloadHomeSections(forceRefresh: true) }
        // The reload runs on the main actor, which this test holds while it pumps the run loop, so
        // it gets its turn by awaiting.
        let asked = Date().addingTimeInterval(mustHappenTimeout)
        while refresh == nil, Date() < asked { await Task.yield() }
        XCTAssertNotNil(refresh, "the refresh never asked for top tracks")
        XCTAssertTrue(AppKitTestSupport.pumpRunLoop(until: { !palette.canEnqueueTrackSelection }), "Add to Queue stayed on while the top tracks reloaded")

        refresh?.resume()
        await reload.value
        XCTAssertTrue(AppKitTestSupport.pumpRunLoop(until: { browserVM.homeTopTracks.value == nil }))
        // Give the failed refresh's last updates their turn before checking that nothing turned
        // Add to Queue back on: the run loop, then the main actor this async test holds.
        AppKitTestSupport.settle()
        await ViewTestHost.renderPendingUpdates()
        XCTAssertFalse(palette.canEnqueueTrackSelection, "Add to Queue came back on after the refresh failed")
    }

    func testManualHomeRefreshFetchesChangedSectionsOutsideFreshCache() async {
        let firstRecentlyPlayed = recentlyPlayedTrack(id: "recent-1", albumID: "album-1", albumName: "Album 1")
        let secondRecentlyPlayed = recentlyPlayedTrack(id: "recent-2", albumID: "album-2", albumName: "Album 2")
        let firstTopTrack = recentlyPlayedTrack(id: "top-1", albumID: "top-album-1", albumName: "Top Album 1")
        let secondTopTrack = recentlyPlayedTrack(id: "top-2", albumID: "top-album-2", albumName: "Top Album 2")
        var recentlyPlayedInvocation = 0
        var topTracksInvocation = 0
        let api = MockBrowsingAPI(
            playlistResults: [
                .success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")]),
                .success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])
            ],
            trackResults: [:]
        )
        api.recentlyPlayedHandler = { _ in
            recentlyPlayedInvocation += 1
            return recentlyPlayedInvocation == 1 ? [firstRecentlyPlayed] : [secondRecentlyPlayed]
        }
        api.topTracksHandler = { _, _ in
            topTracksInvocation += 1
            return topTracksInvocation == 1 ? [firstTopTrack] : [secondTopTrack]
        }
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.unifiedRefreshMainSurface()

        XCTAssertEqual(viewModel.homeRecentlyPlayed.value?.map(\.id), ["album-2"])
        XCTAssertEqual(viewModel.homeTopTracks.value?.map(\.id), ["top-2"])
        XCTAssertEqual(api.recentlyPlayedCacheModes, [.freshOnly, .bypassCache])
        XCTAssertEqual(api.topTracksCacheModes, [.freshOnly, .bypassCache])
    }

    func testRecentlyPlayedDedupesByAlbum() async {
        let api = MockBrowsingAPI(playlistResults: [.success([])], trackResults: [:])
        api.recentlyPlayedHandler = { _ in
            [
                self.recentlyPlayedTrack(id: "t1", albumID: "al1", albumName: "Album 1"),
                self.recentlyPlayedTrack(id: "t2", albumID: "al1", albumName: "Album 1"),
                self.recentlyPlayedTrack(id: "t3", albumID: "al2", albumName: "Album 2"),
            ]
        }
        let vm = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await vm.load()
        await vm.selectSidebar(.home)

        XCTAssertEqual(vm.homeRecentlyPlayed.value?.map(\.id), ["al1", "al2"])
        XCTAssertEqual(
            vm.homeRecentlyPlayed.value?.first?.destination,
            .album(id: "al1", title: "Album 1", subtitle: "Artist", artworkURL: nil)
        )
    }

    func testSectionDegradesToUnavailableWhenScopeMissing() async {
        let api = MockBrowsingAPI(playlistResults: [.success([])], trackResults: [:])
        api.topTracksHandler = { _, _ in
            throw SpotifyAPIError.insufficientScope(requiredScopes: ["user-top-read"], message: nil, details: nil)
        }
        api.recentlyPlayedHandler = { _ in
            throw SpotifyAPIError.forbidden(message: nil, details: nil)
        }
        let vm = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await vm.load()
        await vm.selectSidebar(.home)

        XCTAssertEqual(vm.homeTopTracks, .unavailable)
        XCTAssertEqual(vm.homeRecentlyPlayed, .unavailable)
    }

    func testGreetingVariesByHour() {
        let api = MockBrowsingAPI(playlistResults: [.success([])], trackResults: [:])
        let vm = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!

        func greeting(_ hour: Int, _ minute: Int = 0) -> String {
            let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: hour, minute: minute))!
            return vm.homeGreeting(now: date, calendar: calendar)
        }

        // #464: Home said "Good evening" at 03:31.
        XCTAssertEqual(greeting(3, 31), "Hello, night owl")
        XCTAssertEqual(greeting(0, 0), "Hello, night owl")
        XCTAssertEqual(greeting(4, 59), "Hello, night owl")
        XCTAssertEqual(greeting(5, 0), "Good morning")
        XCTAssertEqual(greeting(11, 59), "Good morning")
        XCTAssertEqual(greeting(12, 0), "Good afternoon")
        XCTAssertEqual(greeting(17, 59), "Good afternoon")
        XCTAssertEqual(greeting(18, 0), "Good evening")
        XCTAssertEqual(greeting(23, 59), "Good evening")
    }

    func testHomeGreetingScheduleWakesAtEachChange() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
        }

        // #464: Home opened at 23:00 and left on screen must change at midnight, then at 05:00.
        let entries = Array(HomeGreetingSchedule(calendar: calendar).entries(from: at(9, 23), mode: .normal).prefix(6))
        XCTAssertEqual(entries, [at(9, 23), at(10, 0), at(10, 5), at(10, 12), at(10, 18), at(11, 0)])

        // A change time itself moves on to the next one.
        XCTAssertEqual(PlaylistBrowserViewModel.nextHomeGreetingChange(after: at(10, 5), calendar: calendar), at(10, 12))

        let vm = PlaylistBrowserViewModel(api: MockBrowsingAPI(playlistResults: [.success([])], trackResults: [:]), cache: MockBrowsingCache())
        XCTAssertEqual(vm.homeGreeting(now: entries[0], calendar: calendar), "Good evening")
        XCTAssertEqual(vm.homeGreeting(now: entries[1], calendar: calendar), "Hello, night owl")
        XCTAssertEqual(vm.homeGreeting(now: entries[2], calendar: calendar), "Good morning")
    }

    @MainActor
    func testHomeGreetingClockStartsOverWhenTheTimeZoneOrClockChanges() {
        // Review of #479: Home opened in Zurich and carried to New York kept waking at Zurich's
        // change times, so it missed New York's midnight and kept saying "Good evening".
        func calendar(_ zone: String) -> Calendar {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone)!
            return calendar
        }
        var systemCalendar = calendar("Europe/Zurich")
        let center = NotificationCenter()
        let clock = HomeGreetingClock(notificationCenter: center, currentCalendar: { systemCalendar })
        XCTAssertEqual(clock.generation, 0)
        XCTAssertEqual(clock.calendar.timeZone.identifier, "Europe/Zurich")

        // 23:00 in New York is 05:00 in Zurich: still evening there, and its next change is New York's midnight.
        let newYorkEvening = calendar("America/New_York").date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 23))!
        systemCalendar = calendar("America/New_York")
        center.post(name: .NSSystemTimeZoneDidChange, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(clock.generation, 1)
        XCTAssertEqual(clock.calendar.timeZone.identifier, "America/New_York")
        let next = PlaylistBrowserViewModel.nextHomeGreetingChange(after: newYorkEvening, calendar: clock.calendar)
        XCTAssertEqual(next, newYorkEvening.addingTimeInterval(3600))
        let vm = PlaylistBrowserViewModel(api: MockBrowsingAPI(playlistResults: [.success([])], trackResults: [:]), cache: MockBrowsingCache())
        XCTAssertEqual(vm.homeGreeting(now: newYorkEvening, calendar: clock.calendar), "Good evening")
        XCTAssertEqual(vm.homeGreeting(now: next, calendar: clock.calendar), "Hello, night owl")

        center.post(name: .NSSystemClockDidChange, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(clock.generation, 2)
    }

    func testHomeGreetingUsesPageTitleStyleWhileSectionsUseSectionStyle() {
        let greeting = HomeSectionHeader(title: "Good morning", style: .pageTitle)
        let section = HomeSectionHeader(title: "Recently played")

        XCTAssertEqual(greeting.style, .pageTitle)
        XCTAssertEqual(section.style, .section)
        XCTAssertEqual(greeting.style.textStyle, .largeTitle)
        XCTAssertEqual(section.style.textStyle, .title2)
        XCTAssertEqual(greeting.style.font, .largeTitle.weight(.bold))
        XCTAssertEqual(section.style.font, .title2.weight(.bold))
    }
}
