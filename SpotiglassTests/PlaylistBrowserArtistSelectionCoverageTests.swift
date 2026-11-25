import XCTest
@testable import Spotiglass

@MainActor
final class PlaylistBrowserArtistSelectionCoverageTests: XCTestCase {
    func testSelectArtistUsesCachedSnapshotWithoutNetwork() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "t1")])]]
        )
        let vm = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await vm.load()

        let artist = MusicArtistDetail(
            id: "artist-1",
            name: "Cached Artist",
            imageURL: nil,
            followersTotal: 10,
            genres: [],
            uri: "spotify:artist:artist-1"
        )
        let snapshot = PlaylistBrowserViewModel.ArtistDetailSnapshot(
            artistDetail: artist,
            albums: [],
            tracks: [],
            usedStaleCache: false,
            paging: nil
        )
        vm.cachedArtistSnapshots["artist-1"] = PlaylistBrowserViewModel.CachedArtistSnapshot(
            snapshot: snapshot,
            fetchedAt: Date()
        )

        await vm.selectArtist(id: "artist-1")
        guard case let .loaded(.artist(detail)) = vm.detailState else {
            return XCTFail("expected cached artist detail")
        }
        XCTAssertEqual(detail.artist.name, "Cached Artist")
    }

    func testCachedArtistNavigationClearsPreviousTrackSelection() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: [:]
        )
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        let artist = MusicArtistDetail(
            id: "artist-cached-selection",
            name: "Cached Selection",
            imageURL: nil,
            followersTotal: nil,
            genres: [],
            uri: "spotify:artist:artist-cached-selection"
        )
        let matchingTrack = PlaylistBrowsingTestFixtures.fallbackTrack(
            id: "same-id",
            name: "Matching Track",
            artistId: artist.id
        )
        viewModel.cachedArtistSnapshots[artist.id] = PlaylistBrowserViewModel.CachedArtistSnapshot(
            snapshot: PlaylistBrowserViewModel.ArtistDetailSnapshot(
                artistDetail: artist,
                albums: [],
                tracks: [matchingTrack],
                usedStaleCache: false,
                paging: nil
            ),
            fetchedAt: Date()
        )
        viewModel.selectedDetailTrackIDs = [matchingTrack.id]

        await viewModel.selectArtist(id: artist.id)

        XCTAssertTrue(viewModel.selectedDetailTrackIDs.isEmpty)
        XCTAssertTrue(viewModel.selectedTrackRows.isEmpty)
    }

    /// A selection across the top songs and the "In your library" section acts on all of it (#658).
    func testASelectionIncludingLibrarySectionSongsTargetsThemToo() async {
        let api = MockBrowsingAPI(playlistResults: [.success([])], trackResults: [:])
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        let artist = MusicArtistDetail(
            id: "artist-library-selection", name: "Library Selection", imageURL: nil,
            followersTotal: nil, genres: [], uri: "applemusic:artist:artist-library-selection"
        )
        let top = PlaylistBrowsingTestFixtures.fallbackTrack(id: "top-1", name: "Top", artistId: artist.id)
        let saved = PlaylistBrowsingTestFixtures.fallbackTrack(id: "saved-1", name: "Saved", artistId: artist.id)
        viewModel.cachedArtistSnapshots[artist.id] = PlaylistBrowserViewModel.CachedArtistSnapshot(
            snapshot: PlaylistBrowserViewModel.ArtistDetailSnapshot(
                artistDetail: artist, albums: [], tracks: [top], usedStaleCache: false, paging: nil,
                extras: MusicArtistPageExtras(topTracks: [top], libraryTracks: [saved])
            ),
            fetchedAt: Date()
        )
        await viewModel.selectArtist(id: artist.id)

        XCTAssertEqual(viewModel.effectiveTrackTargets(forRowID: saved.id).map(\.id), [saved.id])
        viewModel.selectedDetailTrackIDs = [top.id, saved.id]
        XCTAssertEqual(viewModel.effectiveTrackTargets(forRowID: saved.id).map(\.id), [top.id, saved.id])
    }

    private func apiWithOneAlbum(albumTracks: @escaping (String, String?, Int) async throws -> [MusicTrack]) -> MockBrowsingAPI {
        MockBrowsingAPI(
            playlistResults: [.success([])],
            trackResults: [:],
            artistAlbumsPageHandler: { _, _, _, _, _ in
                MusicArtistAlbumsPage(
                    items: [MusicArtistAlbum(id: "al1", name: "Album", imageURL: nil, releaseYear: "2024", totalTracks: 3, group: .album, uri: "applemusic:album:al1")],
                    next: nil
                )
            },
            albumTracksHandler: albumTracks
        )
    }

    /// Apple Music's top songs are the page's songs; nothing else is asked for them (#658).
    func testAnArtistPageUsesTheServicesTopSongs() async {
        let api = apiWithOneAlbum { _, _, _ in XCTFail("no stand-in songs needed"); return [] }
        let top = PlaylistBrowsingTestFixtures.fallbackTrack(id: "top-1", name: "Top", artistId: "a1")
        api.artistPageExtrasHandler = { _ in MusicArtistPageExtras(topTracks: [top]) }
        let vm = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await vm.selectArtist(id: "a1")

        guard case let .loaded(.artist(detail)) = vm.detailState else { return XCTFail("the page opens") }
        XCTAssertEqual(detail.tracks.map(\.id), ["top-1"])
    }

    /// The service's extras failing leaves the page as it would be without them.
    func testAnArtistPageOpensWhenItsExtrasCantBeRead() async {
        let song = PlaylistBrowsingTestFixtures.fallbackTrack(id: "album-song", name: "Song", artistId: "a1")
        let api = apiWithOneAlbum { _, _, _ in [song] }
        api.artistPageExtrasHandler = { _ in throw URLError(.notConnectedToInternet) }
        let vm = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await vm.selectArtist(id: "a1")

        guard case let .loaded(.artist(detail)) = vm.detailState else { return XCTFail("the page opens") }
        XCTAssertEqual(detail.tracks.map(\.id), ["album-song"])
        XCTAssertFalse(detail.hasLibrarySection)
    }

    /// With no top songs and no stand-in songs either, an Apple Music page opens without songs,
    /// while Spotify's fails as before.
    func testAnAppleMusicArtistPageOpensWithoutSongsWhenNoneCanBeFound() async {
        let api = apiWithOneAlbum { _, _, _ in throw URLError(.timedOut) }
        let saved = PlaylistBrowsingTestFixtures.fallbackTrack(id: "saved-1", name: "Saved", artistId: "a1")
        api.artistPageExtrasHandler = { _ in MusicArtistPageExtras(libraryTracks: [saved]) }
        let vm = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await vm.selectArtist(id: "a1")

        guard case let .loaded(.artist(detail)) = vm.detailState else { return XCTFail("the page opens") }
        XCTAssertTrue(detail.tracks.isEmpty)
        XCTAssertEqual(detail.libraryTracks.map(\.id), ["saved-1"])

        let spotify = PlaylistBrowserViewModel(api: apiWithOneAlbum { _, _, _ in throw URLError(.timedOut) }, cache: MockBrowsingCache())
        await spotify.selectArtist(id: "a1")
        guard case .error = spotify.detailState else { return XCTFail("Spotify's page fails as before") }
    }

    func testSelectArtistLoadsFromNetworkOnMiss() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: ["one": [.success([PlaylistBrowsingTestFixtures.track(id: "t1")])]],
            searchHandler: { _, _ in
                MusicSearchResults(
                    tracks: [PlaylistBrowsingTestFixtures.fallbackTrack(id: "search", name: "Search", artistId: "artist-net")],
                    artists: [],
                    albums: [],
                    playlists: []
                )
            },
            artistAlbumsHandler: { id, _, _ in
                XCTAssertEqual(id, "artist-net")
                return []
            }
        )
        let vm = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await vm.load()

        await vm.selectArtist(id: "artist-net")
        guard case let .loaded(.artist(detail)) = vm.detailState else {
            return XCTFail("expected loaded artist")
        }
        XCTAssertEqual(detail.artist.id, "artist-net")
        XCTAssertFalse(detail.tracks.isEmpty)
    }

    func testSelectArtistCoalescesRapidRepeatRequests() async {
        let searchStarted = AsyncSignal()
        let releaseSearch = AsyncSignal()
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: [:],
            searchHandler: { _, _ in
                searchStarted.signal()
                await releaseSearch.wait()
                return MusicSearchResults(tracks: [], artists: [], albums: [], playlists: [])
            },
            artistAlbumsHandler: { _, _, _ in [] }
        )
        let vm = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await vm.load()

        async let first: Void = vm.selectArtist(id: "coalesce")
        // the first artist request should be in flight before the duplicate
        await searchStarted.wait()
        await vm.selectArtist(id: "coalesce")
        releaseSearch.signal()
        await first
        XCTAssertGreaterThanOrEqual(vm.artistFetchMetrics.coalescedRequests, 1)
    }

    func testSelectArtistForceRefreshBypassesCache() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: [:],
            artistAlbumsHandler: { _, _, _ in [] }
        )
        let vm = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await vm.load()

        let artist = MusicArtistDetail(
            id: "force-1",
            name: "Name From The Cache",
            imageURL: nil,
            followersTotal: 0,
            genres: [],
            uri: "spotify:artist:force-1"
        )
        let snapshot = PlaylistBrowserViewModel.ArtistDetailSnapshot(
            artistDetail: artist,
            albums: [],
            tracks: [],
            usedStaleCache: false,
            paging: nil
        )
        vm.cachedArtistSnapshots["force-1"] = PlaylistBrowserViewModel.CachedArtistSnapshot(
            snapshot: snapshot,
            fetchedAt: Date()
        )

        await vm.selectArtist(id: "force-1", forceRefresh: true)
        guard case let .loaded(.artist(detail)) = vm.detailState else {
            return XCTFail("expected loaded artist after force refresh")
        }
        XCTAssertEqual(detail.artist.id, "force-1")
        XCTAssertEqual(detail.artist.name, "Artist force-1", "a forced refresh showed the cached artist")
        XCTAssertEqual(api.artistAlbumsPageCallCount, 1, "a forced refresh must ask the network")
    }

    /// A snapshot older than the cache's lifetime isn't shown: opening the artist asks the
    /// network again and shows what it answers, then keeps that answer as the new snapshot.
    func testSelectArtistRefetchesOnceTheCachedSnapshotIsOlderThanItsLifetime() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: [:],
            artistAlbumsHandler: { _, _, _ in [] }
        )
        let opened = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let ttl: TimeInterval = 90
        let vm = PlaylistBrowserViewModel(
            api: api,
            cache: MockBrowsingCache(),
            now: { opened },
            artistDetailCacheTTL: ttl
        )
        await vm.load()

        let cachedArtist = MusicArtistDetail(
            id: "stale-art",
            name: "Name From The Old Snapshot",
            imageURL: nil,
            followersTotal: 0,
            genres: [],
            uri: "spotify:artist:stale-art"
        )
        vm.cachedArtistSnapshots["stale-art"] = PlaylistBrowserViewModel.CachedArtistSnapshot(
            snapshot: PlaylistBrowserViewModel.ArtistDetailSnapshot(
                artistDetail: cachedArtist,
                albums: [],
                tracks: [],
                usedStaleCache: false,
                paging: nil
            ),
            fetchedAt: opened.addingTimeInterval(-(ttl + 1))
        )

        await vm.selectArtist(id: "stale-art")

        guard case let .loaded(.artist(detail)) = vm.detailState else {
            return XCTFail("expected the refetched artist, got \(vm.detailState)")
        }
        XCTAssertEqual(detail.artist.name, "Artist stale-art", "the expired snapshot was shown instead of asking again")
        XCTAssertEqual(api.artistAlbumsPageCallCount, 1, "an expired snapshot must be fetched again")
        XCTAssertEqual(vm.cachedArtistSnapshots["stale-art"]?.fetchedAt, opened, "the new answer replaces the old snapshot")
        XCTAssertEqual(vm.cachedArtistSnapshots["stale-art"]?.snapshot.artistDetail.name, "Artist stale-art")
    }

    /// The same snapshot one second before it expires is still shown without asking.
    func testSelectArtistKeepsTheCachedSnapshotUntilItsLifetimeEnds() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: [:],
            artistAlbumsHandler: { _, _, _ in [] }
        )
        let opened = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let ttl: TimeInterval = 90
        let vm = PlaylistBrowserViewModel(
            api: api,
            cache: MockBrowsingCache(),
            now: { opened },
            artistDetailCacheTTL: ttl
        )
        await vm.load()
        vm.cachedArtistSnapshots["fresh-art"] = PlaylistBrowserViewModel.CachedArtistSnapshot(
            snapshot: PlaylistBrowserViewModel.ArtistDetailSnapshot(
                artistDetail: MusicArtistDetail(
                    id: "fresh-art", name: "Cached Name", imageURL: nil, followersTotal: 0, genres: [], uri: "spotify:artist:fresh-art"
                ),
                albums: [],
                tracks: [],
                usedStaleCache: false,
                paging: nil
            ),
            fetchedAt: opened.addingTimeInterval(-(ttl - 1))
        )

        await vm.selectArtist(id: "fresh-art")

        guard case let .loaded(.artist(detail)) = vm.detailState else {
            return XCTFail("expected the cached artist, got \(vm.detailState)")
        }
        XCTAssertEqual(detail.artist.name, "Cached Name")
        XCTAssertEqual(api.artistAlbumsPageCallCount, 0, "a snapshot inside its lifetime needs no network")
    }

    func testSelectArtistWithDisplayNameUsesBreadcrumbLabel() async {
        let api = MockBrowsingAPI(
            playlistResults: [.success([PlaylistBrowsingTestFixtures.playlist(id: "one", name: "One")])],
            trackResults: [:],
            artistAlbumsHandler: { _, _, _ in [] }
        )
        let vm = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await vm.load()
        await vm.selectArtist(id: "named", displayName: "Display")
        guard case let .loaded(.artist(detail)) = vm.detailState else {
            return XCTFail("expected artist detail")
        }
        XCTAssertEqual(detail.artist.id, "named")
    }
}
