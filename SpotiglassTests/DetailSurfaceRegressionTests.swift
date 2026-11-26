import AppKit
import SwiftUI
import ViewInspector
import XCTest

@testable import Spotiglass

@MainActor
final class DetailSurfaceRegressionTests: XCTestCase {
    override func tearDown() {
        ViewBodyTally.counts = nil
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    func testArtistRowsUseSharedNativeSelectionAndFeedSelectionMenuState() throws {
        let artist = MusicArtistDetail(
            id: "artist-1",
            name: "Artist",
            imageURL: nil,
            followersTotal: nil,
            genres: [],
            uri: "spotify:artist:artist-1"
        )
        let track = PlaylistBrowsingTestFixtures.fallbackTrack(
            id: "artist-track",
            name: "Artist Track",
            artistId: artist.id
        )
        let detail = ArtistDetailViewModel(artist: artist, tracks: [track], albums: [])
        let browserViewModel = PlaylistBrowserViewModel(
            api: MockBrowsingAPI(playlistResults: [], trackResults: [:]),
            cache: MockBrowsingCache()
        )
        let view = ArtistDetailContent(
            detail: detail,
            browserViewModel: browserViewModel,
            playTrack: { _ in },
            openAlbum: { _ in },
            playAlbumContext: { _ in },
            playback: .nothingPlaying,
            togglePlayPause: {},
            hasPlaybackDevice: true,
            addToQueue: { _ in },
            openArtist: { _ in },
            loadMoreAlbums: {}
        )
        .environmentObject(pinnedStore())

        ViewTestHost.host(view, size: CGSize(width: 800, height: 700))
        XCTAssertNoThrow(try view.inspect().find(TrackListView<PlaybackValueReader<TrackRowPlaybackMark, TrackListRow>>.self))

        browserViewModel.detailState = .loaded(.artist(detail))
        browserViewModel.selectedDetailTrackIDs = [detail.tracks[0].id]
        let selectedRows = browserViewModel.selectedTrackRows

        XCTAssertEqual(selectedRows.map(\.id), [detail.tracks[0].id])
        XCTAssertTrue(
            PlaylistBrowserView.canEnqueueTrackSelection(
                rows: selectedRows,
                hasPlaybackDevice: true
            )
        )
        XCTAssertEqual(
            PlaylistBrowserView.trackSelectionPinState(
                for: selectedRows.compactMap { $0.pinnedTrackItem() },
                isPinned: { _ in false }
            ),
            .pin
        )
    }

    /// On an artist page the table handles the double-click and the song menu of its rows, with
    /// the page's own actions, and the "In your library" songs under the table keep their own
    /// menu: the table's doesn't reach them (#689, #658).
    func testTheArtistPageTableAndItsLibrarySongsEachHaveTheirSongMenu() throws {
        let artist = MusicArtistDetail(
            id: "artist-1", name: "Artist", imageURL: nil, followersTotal: nil, genres: [], uri: "spotify:artist:artist-1"
        )
        let top = PlaylistBrowsingTestFixtures.fallbackTrack(id: "top", name: "Top", artistId: artist.id)
        let saved = PlaylistBrowsingTestFixtures.fallbackTrack(id: "saved", name: "Saved", artistId: artist.id)
        let detail = ArtistDetailViewModel(
            artist: artist, tracks: [top], albums: [], extras: MusicArtistPageExtras(topTracks: [top], libraryTracks: [saved])
        )
        let browserViewModel = PlaylistBrowserViewModel(api: MockBrowsingAPI(playlistResults: [], trackResults: [:]), cache: MockBrowsingCache())
        var played: [String] = []
        let view = ArtistDetailContent(
            detail: detail,
            browserViewModel: browserViewModel,
            playTrack: { played.append($0) },
            openAlbum: { _ in },
            playAlbumContext: { _ in },
            playback: .nothingPlaying,
            togglePlayPause: {},
            hasPlaybackDevice: true,
            addToQueue: { _ in },
            openArtist: { _ in },
            loadMoreAlbums: {}
        )
        .environmentObject(pinnedStore())
        ViewTestHost.host(view, size: CGSize(width: 800, height: 700))

        let table = try view.inspect().find(TrackListView<PlaybackValueReader<TrackRowPlaybackMark, TrackListRow>>.self).actualView()
        let actions = try XCTUnwrap(table.rowActions, "the artist page's table has no double-click or song menu")
        let topRow = detail.tracks[0]
        actions.activate(topRow)
        XCTAssertEqual(played, [topRow.playableURI].compactMap { $0 }, "a double-click didn't play the artist's song")
        let tableMenu = try actions.menuItems([topRow]).inspect().find(TrackOpsMenuItems.self).actualView()
        XCTAssertEqual(tableMenu.targets.map(\.id), [topRow.id], "the table's menu isn't for its row")

        let libraryRow = try view.inspect().find(TrackListRow.self, where: { try $0.actualView().track.id == detail.libraryTracks[0].id }).actualView()
        XCTAssertTrue(libraryRow.handlesClicks, "a library song lost its own double-click and menu")
        let libraryMenu = try XCTUnwrap(libraryRow.trackOpsMenuItems, "a library song has no song menu")()
        XCTAssertEqual(try libraryMenu.inspect().find(TrackOpsMenuItems.self).actualView().targets.map(\.id), [detail.libraryTracks[0].id])
    }

    func testNativeTrackListWritesSelectionBinding() throws {
        let track = TrackRowViewModel.numberedTopTracks([
            PlaylistBrowsingTestFixtures.fallbackTrack(
                id: "selectable-track",
                name: "Selectable Track",
                artistId: "artist-1"
            )
        ])[0]
        var selection: Set<String> = []
        let view = TrackListView(
            tracks: [track],
            selection: Binding(
                get: { selection },
                set: { selection = $0 }
            ),
            rowBuilder: { row, _ in
                TrackListRow(
                    trackNumber: row.listPosition,
                    track: row,
                    playURI: { _ in },
                    togglePlayPause: {},
                    isCurrent: false,
                    isPlaying: false,
                    openArtist: { _ in },
                    drawsRowHighlights: false,
                    isKeyboardFocusable: false
                )
            }
        )
        .environmentObject(pinnedStore())
        let controller = ViewTestHost.host(view, size: CGSize(width: 700, height: 300))
        XCTAssertTrue(
            AppKitTestSupport.pumpRunLoop(until: { (Self.firstTableView(in: controller.view)?.numberOfRows ?? 0) > 0 }),
            "the track list never showed its row"
        )
        let table = try XCTUnwrap(Self.firstTableView(in: controller.view))
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        table.displayIfNeeded()
        AppKitTestSupport.settle()

        XCTAssertEqual(selection, [track.id])
    }

    func testDetailHeaderPlaybackTargetsCoverPlaylistAlbumLikedSongsAndArtist() {
        let playlist = PlaylistDetailViewModel(
            playlist: PlaylistRowViewModel(
                PlaylistBrowsingTestFixtures.playlist(id: "playlist-1", name: "Playlist")
            ),
            tracks: []
        )
        let playlistTarget = DetailHeaderPlayback.target(for: playlist)
        XCTAssertEqual(playlistTarget, .context(uri: "spotify:playlist:playlist-1", playlistID: "playlist-1"))
        XCTAssertTrue(playlistTarget.isPlayable)

        let album = PlaylistDetailViewModel(
            playlist: PlaylistRowViewModel(
                albumDisplayName: "Album",
                artistsDisplay: "Artist",
                totalTrackCount: 1,
                artworkURL: nil,
                albumID: "album-1"
            ),
            tracks: []
        )
        XCTAssertEqual(
            DetailHeaderPlayback.target(for: album),
            .context(uri: "spotify:album:album-1", playlistID: "album-1")
        )

        let likedTrack = TrackRowViewModel.numberedTopTracks([
            PlaylistBrowsingTestFixtures.fallbackTrack(
                id: "liked-track",
                name: "Liked Track",
                artistId: "artist-1"
            )
        ])
        let likedSongs = PlaylistDetailViewModel(
            playlist: PlaylistRowViewModel(
                likedSongsOwnerDisplay: "You",
                totalTrackCount: 1,
                artworkURL: nil
            ),
            tracks: likedTrack
        )
        let likedSongsTarget = DetailHeaderPlayback.target(for: likedSongs)
        XCTAssertEqual(
            likedSongsTarget,
            .tracks(
                uris: ["spotify:track:liked-track"],
                playlistID: SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID
            )
        )
        XCTAssertTrue(likedSongsTarget.isPlayable)
        XCTAssertFalse(
            DetailHeaderPlayback.target(
                for: PlaylistDetailViewModel(
                    playlist: PlaylistRowViewModel(
                        likedSongsOwnerDisplay: "You",
                        totalTrackCount: 0,
                        artworkURL: nil
                    ),
                    tracks: []
                )
            ).isPlayable
        )

        let artist = ArtistDetailViewModel(
            artist: MusicArtistDetail(
                id: "artist-1",
                name: "Artist",
                imageURL: nil,
                followersTotal: nil,
                genres: [],
                uri: "spotify:artist:artist-1"
            ),
            tracks: [],
            albums: []
        )
        XCTAssertEqual(
            DetailHeaderPlayback.target(for: artist),
            .context(uri: "spotify:artist:artist-1")
        )
    }

    /// With Apple Music on screen after Spotify's player started (#373), Play, Shuffle and a song's
    /// play button must not reach Spotify. They used to flip shuffle on the Spotify account and
    /// send it `spotify:playlist:<Apple Music id>` / `applemusic:song:` URIs it rejects.
    func testAppleMusicSpaceNeverStartsSpotifyPlayback() async {
        let playbackAPI = MockPlaybackAPI()
        let playbackViewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: playbackAPI, webCommander: MockWebPlaybackCommander()),
            postShuffleSyncDelay: .seconds(60)
        )
        // Spotify's player, started by the Spotify space before switching.
        playbackViewModel.deviceID = "device-1"
        playbackViewModel.hasTransferredPlaybackToCurrentDevice = true
        playbackViewModel.setTransportStateKnown(true)
        // What the window sets while Apple Music is on screen.
        playbackViewModel.refusesNewPlayback = true
        let appleMusicPlaylist = PlaylistDetailViewModel(
            playlist: PlaylistRowViewModel(PlaylistBrowsingTestFixtures.playlist(id: "p.AbCdEf123", name: "Road Trip")),
            tracks: []
        )
        let target = DetailHeaderPlayback.target(for: appleMusicPlaylist)

        await DetailHeaderPlayback.shuffleAndPlay(target: target, using: playbackViewModel)
        await DetailHeaderPlayback.play(target: target, using: playbackViewModel)
        await playbackViewModel.playFromPlaylist(
            clickedURI: "applemusic:song:1", playableURIs: ["applemusic:song:1"], playlistID: "p.AbCdEf123"
        )
        await playbackViewModel.play(uri: "applemusic:song:1")

        XCTAssertEqual(playbackAPI.actions, [])
    }

    func testShuffleHeaderEnablesShuffleBeforePlayingContext() async {
        let playbackAPI = MockPlaybackAPI()
        let playbackViewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: playbackAPI, webCommander: MockWebPlaybackCommander()),
            postShuffleSyncDelay: .seconds(60)
        )
        playbackViewModel.deviceID = "device-1"
        playbackViewModel.hasTransferredPlaybackToCurrentDevice = true
        playbackViewModel.setTransportStateKnown(true)

        await DetailHeaderPlayback.shuffleAndPlay(
            target: .context(uri: "spotify:playlist:playlist-1"),
            using: playbackViewModel
        )

        XCTAssertEqual(
            playbackAPI.actions.filter {
                $0.hasPrefix("setShuffle:") || $0.hasPrefix("play-context:")
            },
            [
                "setShuffle:device-1:true",
                "play-context:device-1:spotify:playlist:playlist-1",
            ]
        )
    }

    func testLikedSongsHeaderPlaysItsLoadedURIList() async {
        let playbackAPI = MockPlaybackAPI()
        let playbackViewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: playbackAPI, webCommander: MockWebPlaybackCommander()))
        playbackViewModel.deviceID = "device-1"
        playbackViewModel.hasTransferredPlaybackToCurrentDevice = true

        await DetailHeaderPlayback.play(
            target: .tracks(
                uris: ["spotify:track:first", "spotify:track:second"],
                playlistID: SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID
            ),
            using: playbackViewModel
        )

        XCTAssertEqual(
            playbackAPI.actions,
            ["play-list:device-1:spotify:track:first,spotify:track:second"]
        )
    }

    func testEachDetailHeaderExposesPlayAndShuffleDisabledWithoutDevice() throws {
        let store = pinnedStore()
        let playlist = PlaylistDetailViewModel(
            playlist: PlaylistRowViewModel(
                PlaylistBrowsingTestFixtures.playlist(id: "playlist-1", name: "Playlist")
            ),
            tracks: []
        )
        let album = PlaylistDetailViewModel(
            playlist: PlaylistRowViewModel(
                albumDisplayName: "Album",
                artistsDisplay: "Artist",
                totalTrackCount: 0,
                artworkURL: nil,
                albumID: "album-1"
            ),
            tracks: []
        )
        let likedSongs = PlaylistDetailViewModel(
            playlist: PlaylistRowViewModel(
                likedSongsOwnerDisplay: "You",
                totalTrackCount: 0,
                artworkURL: nil
            ),
            tracks: []
        )
        let artist = ArtistDetailViewModel(
            artist: MusicArtistDetail(
                id: "artist-1",
                name: "Artist",
                imageURL: nil,
                followersTotal: nil,
                genres: [],
                uri: "spotify:artist:artist-1"
            ),
            tracks: [],
            albums: []
        )

        let views: [AnyView] = [
            AnyView(playlistView(detail: playlist).environmentObject(store)),
            AnyView(playlistView(detail: album).environmentObject(store)),
            AnyView(playlistView(detail: likedSongs).environmentObject(store)),
            AnyView(artistView(detail: artist).environmentObject(store)),
        ]
        for view in views {
            ViewTestHost.tearDownAll()
            ViewTestHost.host(view, size: CGSize(width: 800, height: 500))
            let inspected = try view.inspect()
            XCTAssertTrue(
                try inspected.find(button: SpotiglassL10n.string("playback.play")).isDisabled()
            )
            XCTAssertTrue(
                try inspected.find(button: SpotiglassL10n.string("menu.playback.shuffle")).isDisabled()
            )
        }
    }

    /// The track table handles the double-click and the song menu for all of its rows, and a
    /// new selection builds again only the rows whose selection it changed (#689). Each row used to carry
    /// its own double-click gesture and menu: the gesture took the click from the table, and the
    /// menu was built on every mouse-down. And the selection reached the rows through the list,
    /// so a click on a freshly opened 2,000-song playlist went through all of them.
    func testTheTableDoubleClicksAndOpensTheSongMenuForItsRows() async throws {
        let tracks = TrackRowViewModel.numberedTopTracks((0..<6).map {
            PlaylistBrowsingTestFixtures.fallbackTrack(id: "t\($0)", name: "Track \($0)", artistId: "a")
        })
        final class Record {
            var selection: Set<String> = []
            var activated: [String] = []
            var builds: [String] = []
            var prepared: [String] = []
        }
        let record = Record()
        let view = TrackListSelectionHarness(record: { record.selection = $0 }) { selection in
            TrackListView(
                tracks: tracks,
                selection: selection,
                rowBuilder: { row, isSelected in
                    record.builds.append("\(row.id)\(isSelected ? "+" : "-")")
                    return TrackListRow(
                        trackNumber: row.listPosition, track: row, playURI: { _ in }, togglePlayPause: {},
                        isCurrent: false, isPlaying: false, openArtist: { _ in }, isSelected: isSelected,
                        drawsRowHighlights: false, isKeyboardFocusable: false, handlesClicks: false
                    )
                },
                rowActions: TrackListRowActions(
                    invocation: { .play(uri: $0.id) },
                    playURI: { record.activated.append($0) },
                    togglePlayPause: {},
                    menuItems: { targets in AnyView(Button("Rows \(targets.map(\.id).joined(separator: ","))") {}) },
                    prepareMenus: { record.prepared += $0.map(\.id) }
                ),
                rowContentKey: AnyHashable("list")
            )
        }
        .environmentObject(pinnedStore())
        let controller = ViewTestHost.host(view, size: CGSize(width: 700, height: 400), takesClicks: true)
        let window = try XCTUnwrap(controller.view.window)
        // Hosting sizes the window to the list, which wants next to no room.
        window.setContentSize(NSSize(width: 700, height: 400))
        window.orderFrontRegardless()
        var found: NSTableView?
        XCTAssertTrue(AppKitTestSupport.pumpRunLoop(until: {
            found = Self.firstTableView(in: controller.view)
            return found.map { $0.numberOfRows == tracks.count && $0.visibleRect.height > 0 } ?? false
        }), "the table never showed the songs")
        let table = try XCTUnwrap(found)
        await AppKitTestSupport.settle()
        XCTAssertGreaterThan(table.visibleRect.height, table.rect(ofRow: tracks.count - 1).maxY - 1, "not every row is on screen")
        let row = { (id: String) in try XCTUnwrap(tracks.firstIndex { $0.id == id }) }
        // What a menu shows from the network (whether a song is liked) is asked for as its row comes
        // on screen: built when it opens, a menu showed "Add to Liked Songs" greyed out the first time.
        XCTAssertTrue(
            AppKitTestSupport.pumpRunLoop(until: { Set(record.prepared) == Set(tracks.map(\.id)) }),
            "the menus of the rows on screen weren't prepared: \(record.prepared)"
        )

        /// A click as a mouse makes it: the button goes down and up before the app handles either,
        /// so the table, which waits for the mouse-up on a mouse-down (it may be a drag), finds it.
        func click(_ index: Int, clickCount: Int) {
            let rect = table.rect(ofRow: index)
            let point = table.convert(NSPoint(x: rect.minX + rect.width * 0.4, y: rect.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount,
                    pressure: type == .leftMouseUp ? 0 : 1
                ) else { return XCTFail("no \(type) event") }
                NSApp.postEvent(event, atStart: false)
            }
            while let next = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(next)
            }
        }
        func doubleClick(_ index: Int) {
            click(index, clickCount: 1)
            click(index, clickCount: 2)
            AppKitTestSupport.settle()
        }
        func select(_ ids: Set<String>) throws {
            table.selectRowIndexes(IndexSet(try ids.map { try row($0) }), byExtendingSelection: false)
            XCTAssertTrue(AppKitTestSupport.pumpRunLoop(until: { record.selection == ids }), "the selection never reached the binding")
        }
        /// The titles of the menu a right-click on `index` opens.
        func menuTitles(_ index: Int) throws -> [String] {
            let rect = table.rect(ofRow: index)
            let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            var view = window.contentView?.hitTest(point)
            while let current = view {
                if let menu = current.menu(for: event) {
                    menu.delegate?.menuNeedsUpdate?(menu)
                    return menu.items.map(\.title)
                }
                view = current.superview
            }
            return []
        }

        // A selection change as the table makes it on a click (the clicks themselves are in
        // LongListScrollCostTests, on the real playlist page).
        try select(["t1"])
        XCTAssertTrue(window.firstResponder === table, "a new selection left the table without the keyboard")
        await AppKitTestSupport.settle()
        record.builds = []
        try select(["t2"])
        XCTAssertTrue(
            AppKitTestSupport.pumpRunLoop(until: { Set(record.builds).isSuperset(of: ["t1-", "t2+"]) }),
            "the rows the selection changed weren't built again: \(record.builds)"
        )
        await AppKitTestSupport.settle()
        // That the list of rows itself isn't built again on a selection is checked on the real
        // playlist page, for every click (LongListScrollCostTests): this small host sometimes draws
        // all its rows again depending on what ran before it.

        // The keyboard leaves through AppKit, which SwiftUI's own focus state didn't notice: it still
        // said the table had it, and the next selection never gave it back.
        window.makeFirstResponder(nil)
        try select(["t3"])
        XCTAssertTrue(window.firstResponder === table, "the table didn't get the keyboard back")

        // A double-click on a selected row plays it. The first click of the two selects the row; a
        // posted click doesn't always get that far in a test (GitHub's runners don't hand it to the
        // window at all), so the row is selected first. The table watches the mouse-downs as they
        // go by and leaves them alone: SwiftUI's own double-click held each one back until its
        // mouse-up, and the table then waited for a mouse-up that had already come (#689).
        try select(["t4"])
        doubleClick(try row("t4"))
        XCTAssertEqual(record.activated, ["t4"], "a double-click didn't play its row once")
        // Not through something lying over the table, such as a banner or a toast over that row.
        let contentView = try XCTUnwrap(window.contentView)
        let cover = NSView(frame: table.convert(table.rect(ofRow: try row("t4")), to: contentView))
        contentView.addSubview(cover)
        record.activated = []
        doubleClick(try row("t4"))
        cover.removeFromSuperview()
        XCTAssertEqual(record.activated, [], "a double-click on a view over the table played the row under it")

        // A right-click on a row of a selection acts on the selection, anywhere else on that row.
        try select(["t1", "t3"])
        XCTAssertTrue(try menuTitles(try row("t3")).contains("Rows t1,t3"), "the menu on a selected row isn't for the selection")
        XCTAssertTrue(try menuTitles(try row("t5")).contains("Rows t5"), "the menu on another row isn't for that row")
        XCTAssertTrue(try menuTitles(try row("t5")).contains(SpotiglassL10n.string("browser.track.play")), "the menu has no Play")
    }

    private static func firstTableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let found = firstTableView(in: subview) { return found }
        }
        return nil
    }

    private func pinnedStore() -> PinnedItemsStore {
        let store = PinnedItemsStore(cache: InMemoryPinnedItemsCache())
        store.bind(userID: "detail-surface-tests")
        return store
    }

    private func browserViewModel() -> PlaylistBrowserViewModel {
        PlaylistBrowserViewModel(
            api: MockBrowsingAPI(playlistResults: [], trackResults: [:]),
            cache: MockBrowsingCache()
        )
    }

    private func playlistView(detail: PlaylistDetailViewModel) -> PlaylistDetailContent {
        PlaylistDetailContent(
            detail: detail,
            playURI: { _ in },
            playback: .nothingPlaying,
            togglePlayPause: {},
            hasPlaybackDevice: false,
            addToQueue: { _ in },
            openArtist: { _ in },
            browserViewModel: browserViewModel()
        )
    }

    private func artistView(detail: ArtistDetailViewModel) -> ArtistDetailContent {
        ArtistDetailContent(
            detail: detail,
            browserViewModel: browserViewModel(),
            playTrack: { _ in },
            openAlbum: { _ in },
            playAlbumContext: { _ in },
            playback: .nothingPlaying,
            togglePlayPause: {},
            hasPlaybackDevice: false,
            addToQueue: { _ in },
            openArtist: { _ in },
            loadMoreAlbums: {}
        )
    }
}

/// A selection kept in view state, as the app's lists keep theirs, reported to the test.
private struct TrackListSelectionHarness<Content: View>: View {
    let record: (Set<String>) -> Void
    @ViewBuilder let content: (Binding<Set<String>>) -> Content
    @State private var selection: Set<String> = []

    var body: some View {
        content($selection)
            .onChange(of: selection) { record(selection) }
    }
}
