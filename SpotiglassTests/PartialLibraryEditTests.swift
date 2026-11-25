import XCTest
@testable import Spotiglass

/// Edits sent as several requests, or followed by a read, that fail part way (#596). Each test
/// replays one failure from the issue: the part that went through must stay visible.
@MainActor
final class PartialLibraryEditTests: XCTestCase {
    // MARK: - Spotify

    /// `POST /v1/playlists/X/items` answers 201, then 503: 100 of 101 songs are in the playlist.
    func testAnAddThatFailsAfterTheFirstBatchSaysHowManyWentInAndReloadsThePlaylist() async throws {
        let http = RoutedHTTPClient()
        var posts = 0
        http.route = { request in
            if request.httpMethod == "POST" {
                posts += 1
                return posts == 1 ? .data(Data(), statusCode: 201) : .json(#"{"error":{"status":503,"message":"Service unavailable"}}"#, statusCode: 503)
            }
            return Self.listing(request, ids: ["already-there"] + (0..<100).map { "t\($0)" })
        }
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: http)
        let playlist = PlaylistBrowsingTestFixtures.playlist(id: "X", name: "Road Trip").with(trackCount: 1)
        let viewModel = PlaylistBrowserViewModel(api: client, cache: DisabledBrowsingCache())
        viewModel.playlistsByID = [playlist.id: playlist]
        viewModel.playlistState = .loaded([PlaylistRowViewModel(playlist)])
        viewModel.sidebarSelection = .playlist(playlist.id)
        viewModel.detailSession = 1
        let rows = TrackRowViewModel.numberedPlaylistRows((0..<101).map { PlaylistBrowsingTestFixtures.track(id: "t\($0)") })

        await viewModel.addRowsToPlaylist(rows, playlistID: playlist.id, playlistName: playlist.name)

        XCTAssertEqual(posts, 2)
        XCTAssertEqual(viewModel.trackMutationToast?.hasPrefix("Added 100 of 101 tracks to Road Trip."), true, viewModel.trackMutationToast ?? "no note")
        XCTAssertEqual(PlaylistBrowsingTestFixtures.playlistTracks(viewModel.detailState).count, 101, "the open playlist was read again")
    }

    /// A move whose add stops after the first batch: the destination has 100 new songs, the
    /// source keeps all of them, and nothing is removed from it.
    func testAMoveWhoseAddFailsPartWayRemovesNothingAndSaysHowManyWentIn() async {
        let http = RoutedHTTPClient()
        var methods: [String] = []
        http.route = { request in
            methods.append(request.httpMethod ?? "")
            if request.httpMethod == "POST" {
                return methods.filter { $0 == "POST" }.count == 1
                    ? .data(Data(), statusCode: 201)
                    : .json(#"{"error":{"status":503,"message":"Service unavailable"}}"#, statusCode: 503)
            }
            return Self.listing(request, ids: (0..<101).map { "t\($0)" })
        }
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: http)
        let source = PlaylistBrowsingTestFixtures.playlist(id: "source", name: "Source")
        let destination = PlaylistBrowsingTestFixtures.playlist(id: "destination", name: "Destination")
        let viewModel = PlaylistBrowserViewModel(api: client, cache: DisabledBrowsingCache())
        viewModel.playlistsByID = [source.id: source, destination.id: destination]
        viewModel.sidebarSelection = .playlist(source.id)
        viewModel.detailSession = 1
        let rows = TrackRowViewModel.numberedPlaylistRows((0..<101).map { PlaylistBrowsingTestFixtures.track(id: "t\($0)") })

        await viewModel.moveRowsBetweenPlaylists(rows, from: source.id, to: destination.id, destinationName: destination.name)

        XCTAssertFalse(methods.contains("DELETE"), "nothing leaves the source when not every song reached the destination")
        XCTAssertEqual(viewModel.trackMutationToast?.hasPrefix("Added 100 of 101 tracks to Destination and removed none from this playlist."), true,
                       viewModel.trackMutationToast ?? "no note")
        XCTAssertEqual(PlaylistBrowsingTestFixtures.playlistTracks(viewModel.detailState).count, 101, "the open source was read again")
    }

    /// `DELETE /v1/playlists/X/items` answers 200, then 503: 100 of 101 songs left the playlist.
    func testARemovalThatFailsAfterTheFirstBatchSaysHowManyWentAndReloadsThePlaylist() async {
        let http = RoutedHTTPClient()
        var deletes = 0
        http.route = { request in
            if request.httpMethod == "DELETE" {
                deletes += 1
                return deletes == 1 ? .json(#"{"snapshot_id": "s2"}"#) : .json(#"{"error":{"status":503,"message":"Service unavailable"}}"#, statusCode: 503)
            }
            return Self.listing(request, ids: ["t100"])
        }
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: http)
        let playlist = PlaylistBrowsingTestFixtures.playlist(id: "X", name: "Road Trip").with(trackCount: 101)
        let viewModel = PlaylistBrowserViewModel(api: client, cache: DisabledBrowsingCache())
        viewModel.playlistsByID = [playlist.id: playlist]
        viewModel.playlistState = .loaded([PlaylistRowViewModel(playlist)])
        viewModel.sidebarSelection = .playlist(playlist.id)
        viewModel.detailSession = 1
        let rows = TrackRowViewModel.numberedPlaylistRows((0..<101).map { PlaylistBrowsingTestFixtures.track(id: "t\($0)") })

        await viewModel.removeRowsFromPlaylist(rows, playlistID: playlist.id, playlistName: playlist.name)

        XCTAssertEqual(deletes, 2)
        XCTAssertEqual(viewModel.trackMutationToast?.hasPrefix("Removed 100 of 101 tracks from Road Trip."), true, viewModel.trackMutationToast ?? "no note")
        XCTAssertEqual(PlaylistBrowsingTestFixtures.playlistTracks(viewModel.detailState).count, 1, "the open playlist was read again")
    }

    /// `PUT /v1/me/tracks` in batches of 50: the first goes in, the second fails.
    func testALikeThatFailsAfterTheFirstBatchMarksOnlyThoseLiked() async {
        let http = RoutedHTTPClient()
        var puts = 0
        http.route = { request in
            if request.httpMethod == "PUT" {
                puts += 1
                return puts == 1 ? .data(Data(), statusCode: 200) : .json(#"{"error":{"status":503,"message":"Service unavailable"}}"#, statusCode: 503)
            }
            return .json("[]")
        }
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: http)
        let viewModel = PlaylistBrowserViewModel(api: client, cache: DisabledBrowsingCache())
        let rows = TrackRowViewModel.numberedPlaylistRows((0..<51).map { PlaylistBrowsingTestFixtures.track(id: "t\($0)") })

        await viewModel.favoriteRows(rows)

        XCTAssertEqual(viewModel.trackMutationToast?.hasPrefix("Added 50 of 51 tracks to Liked Songs."), true, viewModel.trackMutationToast ?? "no note")
        XCTAssertEqual(viewModel.savedTrackStates["t0"], true)
        XCTAssertEqual(viewModel.savedTrackStates["t49"], true)
        XCTAssertNil(viewModel.savedTrackStates["t50"], "the song whose request failed is asked again")
    }

    /// `DELETE /v1/me/tracks` in batches of 50: the first goes through, the second fails.
    func testAnUnlikeThatFailsAfterTheFirstBatchMarksOnlyThoseUnliked() async {
        let http = RoutedHTTPClient()
        var deletes = 0
        http.route = { request in
            if request.httpMethod == "DELETE" {
                deletes += 1
                return deletes == 1 ? .data(Data(), statusCode: 200) : .json(#"{"error":{"status":503,"message":"Service unavailable"}}"#, statusCode: 503)
            }
            return .json("[]")
        }
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: http)
        let viewModel = PlaylistBrowserViewModel(api: client, cache: DisabledBrowsingCache())
        let rows = TrackRowViewModel.numberedPlaylistRows((0..<51).map { PlaylistBrowsingTestFixtures.track(id: "t\($0)") })
        for index in 0..<51 { viewModel.savedTrackStates["t\(index)"] = true }

        await viewModel.unfavoriteRows(rows)

        XCTAssertEqual(deletes, 2)
        XCTAssertEqual(viewModel.trackMutationToast?.hasPrefix("Removed 50 of 51 tracks from Liked Songs."), true, viewModel.trackMutationToast ?? "no note")
        XCTAssertEqual(viewModel.savedTrackStates["t0"], false)
        XCTAssertEqual(viewModel.savedTrackStates["t49"], false)
        XCTAssertNil(viewModel.savedTrackStates["t50"], "the song whose request failed is asked again")
    }

    /// A new playlist with 101 songs: the first 100 go in, the second request answers 503.
    func testAPlaylistCreatedWithSomeOfItsSongsSaysHowManyWentIn() async {
        let http = RoutedHTTPClient()
        var itemPosts = 0
        http.route = { request in
            switch request.url?.path {
            case "/v1/me/playlists" where request.httpMethod == "POST":
                return .json("""
                {"id": "P", "name": "New Mix", "owner": {"id": "user-1", "display_name": "User"},
                 "images": [], "items": {"total": 0}, "snapshot_id": "s1"}
                """, statusCode: 201)
            case "/v1/playlists/P/items" where request.httpMethod == "POST":
                itemPosts += 1
                return itemPosts == 1 ? .data(Data(), statusCode: 201) : .json(#"{"error":{"status":503,"message":"Service unavailable"}}"#, statusCode: 503)
            default:
                return .json(#"{"error":{"status":404,"message":"Not found"}}"#, statusCode: 404)
            }
        }
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: http)
        let viewModel = PlaylistBrowserViewModel(api: client, cache: DisabledBrowsingCache())
        viewModel.currentUserID = "user-1"
        viewModel.playlistState = .loaded([])
        let rows = TrackRowViewModel.numberedPlaylistRows((0..<101).map { PlaylistBrowsingTestFixtures.track(id: "t\($0)") })

        await viewModel.createPlaylistWithRows(name: "New Mix", rows: rows)

        XCTAssertEqual(itemPosts, 2)
        XCTAssertEqual(viewModel.playlistState.currentValue?.map(\.id), ["P"])
        XCTAssertEqual(viewModel.playlistsByID["P"]?.trackCount, 100)
        XCTAssertEqual(viewModel.trackMutationToast?.hasPrefix("Created New Mix, but only 100 of 101 tracks could be added."), true,
                       viewModel.trackMutationToast ?? "no note")
    }

    /// `POST /v1/me/playlists` creates P, then `POST /v1/playlists/P/items` answers 503.
    func testAPlaylistCreatedWhoseSongsFailedStillShowsInTheSidebar() async {
        let http = RoutedHTTPClient()
        http.route = { request in
            switch request.url?.path {
            case "/v1/me/playlists" where request.httpMethod == "POST":
                return .json("""
                {"id": "P", "name": "New Mix", "owner": {"id": "user-1", "display_name": "User"},
                 "images": [], "items": {"total": 0}, "snapshot_id": "s1"}
                """, statusCode: 201)
            default:
                return .json(#"{"error":{"status":503,"message":"Service unavailable"}}"#, statusCode: 503)
            }
        }
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: http)
        let viewModel = PlaylistBrowserViewModel(api: client, cache: DisabledBrowsingCache())
        viewModel.currentUserID = "user-1"
        viewModel.playlistState = .loaded([])
        let rows = TrackRowViewModel.numberedPlaylistRows([PlaylistBrowsingTestFixtures.track(id: "t1")])

        await viewModel.createPlaylistWithRows(name: "New Mix", rows: rows)

        XCTAssertEqual(viewModel.playlistState.currentValue?.map(\.id), ["P"])
        XCTAssertEqual(viewModel.playlistsByID["P"]?.trackCount, 0)
        XCTAssertEqual(viewModel.trackMutationToast?.hasPrefix("Created New Mix, but its tracks couldn't be added."), true,
                       viewModel.trackMutationToast ?? "no note")
    }

    /// One failed batch out of one changed nothing: it fails like before, with no count.
    func testAFailureBeforeAnyBatchWentThroughIsAPlainFailure() async throws {
        do {
            try await MusicLibraryPartialEditError.sendingBatches([[1, 2], [3]], step: "test") { _ in
                throw URLError(.timedOut)
            }
            XCTFail("expected a failure")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }
    }

    // MARK: - Apple Music

    private func appleMusicEditor() -> (AppleMusicLibraryEditor, MockLibraryLookup, MockCloudLibrary) {
        let lookup = MockLibraryLookup()
        let cloud = MockCloudLibrary()
        let editor = AppleMusicLibraryEditor(
            lookup: lookup,
            cloud: cloud,
            musicApp: MockMusicApp(),
            pending: AppleMusicPendingLibraryEdits(),
            songReferences: AppleMusicSongReferenceRegistry()
        )
        return (editor, lookup, cloud)
    }

    /// I have a "Mix"; the read of my playlists fails while a new "Mix" is created. The old one
    /// must not count as the new one arriving.
    func testANewPlaylistNamedLikeAnOldOneStaysWhenTheNameCheckFails() async throws {
        let (editor, _, cloud) = appleMusicEditor()
        cloud.createdPlaylistID = "p.new"
        let source = EditTestContentSource()
        source.playlists = [try AppleMusicFixtures.playlist(id: "-1", name: "Mix")]
        let provider = AppleMusicBrowsingProvider(source: source, editor: editor)
        _ = try await provider.libraryPlaylists(limit: 100)

        source.playlistsError = URLError(.notConnectedToInternet)
        _ = try await provider.createPlaylist(userID: "", name: "Mix", isPublic: false, trackURIs: [])
        source.playlistsError = nil

        let listed = try await provider.libraryPlaylists(limit: 100)
        XCTAssertEqual(listed.map(\.id), ["p.new", "-1"], "the new Mix stays until the library lists a second one")
    }

    /// With no read to fall back on, nothing is created: a retry can't make a second playlist.
    func testANewPlaylistIsNotCreatedWhenItsNameCannotBeCheckedAtAll() async throws {
        let (editor, _, cloud) = appleMusicEditor()
        let source = EditTestContentSource()
        source.playlistsError = URLError(.notConnectedToInternet)
        let provider = AppleMusicBrowsingProvider(source: source, editor: editor)

        do {
            _ = try await provider.createPlaylist(userID: "", name: "Mix", isPublic: false, trackURIs: [])
            XCTFail("expected a failure")
        } catch {}
        XCTAssertEqual(cloud.calls, [])
    }

    /// The save went through, then the catalog lookup of the song failed: Liked Songs still
    /// lists it, from the row I liked.
    func testASavedSongShowsInLikedSongsWhenItsLookupFails() async throws {
        let (editor, lookup, cloud) = appleMusicEditor()
        lookup.catalogTracksError = URLError(.timedOut)
        let provider = AppleMusicBrowsingProvider(source: EditTestContentSource(), editor: editor)
        let row = TrackRowViewModel(
            MusicPlaylistTrackItem(id: "699902614", content: .track(MusicTrack(
                id: "699902614", name: "Computer Love", artists: ["Kraftwerk"], albumArtworkURL: nil,
                durationMilliseconds: 1000, isExplicit: false, isPlayable: true, linkedFromID: nil,
                uri: "applemusic:song:699902614"
            ))),
            listPosition: 1
        )

        try await provider.saveTracks(ids: ["699902614"], shown: [try XCTUnwrap(row.shownTrack)])

        XCTAssertEqual(cloud.calls.first, "addToLibrary(songs:699902614 albums:)")
        let liked = editor.pending.applied(toLibrarySongs: [], isComplete: false)
        XCTAssertEqual(liked.map(\.id), ["699902614"])
        XCTAssertEqual(liked.first?.name, "Computer Love")
    }

    // MARK: - Helpers

    /// A Spotify playlist items page with these track IDs, or the playlist itself.
    private static func listing(_ request: URLRequest, ids: [String]) -> QueueHTTPClient.Response {
        guard request.url?.path.hasSuffix("/items") == true else {
            return .json(#"{"id": "X", "name": "Road Trip", "owner": {"id": "user-1"}, "images": [], "items": {"total": \#(ids.count)}, "snapshot_id": "s2"}"#)
        }
        let items = ids.map { id in
            """
            {"is_local": false, "item": {"type": "track", "id": "\(id)", "name": "\(id)", "artists": [{"name": "Artist"}],
             "album": {"name": "Album", "images": []}, "duration_ms": 1000, "explicit": false, "is_playable": true,
             "uri": "spotify:track:\(id)"}}
            """
        }
        return .json(#"{"limit": 100, "next": null, "offset": 0, "total": \#(ids.count), "items": [\#(items.joined(separator: ","))]}"#)
    }
}

/// Answers each request from `route`, so a test can fail one request of an edit.
final class RoutedHTTPClient: HTTPClient, @unchecked Sendable {
    var route: (URLRequest) -> QueueHTTPClient.Response = { _ in .data(Data(), statusCode: 404) }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = route(request)
        let http = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"),
            statusCode: response.statusCode,
            httpVersion: nil,
            headerFields: response.headers
        )!
        return (response.data, http)
    }
}
