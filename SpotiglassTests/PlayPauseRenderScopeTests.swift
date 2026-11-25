import AppKit
import SwiftUI
import XCTest
@testable import Spotiglass

/// Play/pause and a new track re-render only what shows them (#422): the bar, the playing row
/// (old and new) and the sidebar's now-playing playlist. Before, every view observing the player
/// session ran its body again: the browser, the sidebar, the detail column and every visible
/// track and playlist row, though only the playing ones looked any different.
@MainActor
final class PlayPauseRenderScopeTests: XCTestCase {
    override func tearDown() {
        ViewBodyTally.counts = nil
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    private static let trackIDs = (1...20).map { "t\($0)" }

    /// How long the play/pause icon's swap animates (`PlaybackControlsView`).
    private static let iconSwap = Duration.milliseconds(180)

    private static func nowPlaying(_ trackID: String) -> PlaybackNowPlaying {
        PlaybackNowPlaying(
            name: "Track \(trackID)",
            artists: ["Artist"],
            albumName: "Album",
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: 10_000,
            uri: "spotify:track:\(trackID)"
        )
    }

    /// The real browser window with a 20-track playlist open and its third track playing.
    private func hostBrowserPlaying() async throws -> PlaybackSessionViewModel {
        try await hostBrowser(
            tracks: Self.trackIDs.map(PlaylistBrowsingTestFixtures.track(id:)),
            playing: .playing(Self.nowPlaying("t3"))
        )
    }

    /// The real browser window with playlist "p1" of `tracks` open and active, playing `state`.
    private func hostBrowser(
        tracks: [MusicPlaylistTrackItem],
        playing state: PlaybackConnectionState,
        provider: (any MusicPlaybackProvider)? = nil
    ) async throws -> PlaybackSessionViewModel {
        let playlists = [
            PlaylistBrowsingTestFixtures.playlist(id: "p1", name: "Focus"),
            PlaylistBrowsingTestFixtures.playlist(id: "p2", name: "Daily"),
            PlaylistBrowsingTestFixtures.playlist(id: "p3", name: "Gym"),
        ]
        // The same library every time it's asked, as the service answers: the browser loads it
        // again once the window is up.
        let api = MockBrowsingAPI(
            playlistResults: [],
            trackResults: ["p1": [.success(tracks)]],
            playlistsHandler: { playlists }
        )
        let browserVM = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        await browserVM.load()
        await browserVM.selectPlaylist(id: "p1")
        XCTAssertEqual(PlaylistBrowsingTestFixtures.playlistTracks(browserVM.detailState).count, tracks.count)

        let store = PinnedItemsStore(cache: InMemoryPinnedItemsCache())
        store.bind(userID: "u1")
        let tokens = RenderScopeTokenProvider()
        let playbackHost = provider.map { SpotiglassPlaybackHost(provider: $0) } ?? SpotiglassPlaybackHost(tokenProvider: tokens)
        let playback = playbackHost.playbackViewModel
        let view = PlaylistBrowserView(
            viewModel: browserVM,
            playbackHost: playbackHost,
            catalogProvider: SpotifyAPIClient(tokenProvider: tokens, getResponseCache: .shared),
            commandPaletteManager: CommandPaletteManager(),
            signOut: {}
        )
        .environmentObject(store)
        .environmentObject(LyricsOverlayController())
        let controller = ViewTestHost.host(view, size: CGSize(width: 1_600, height: 1_400))
        await AppKitTestSupport.settle()
        // The browser starts at a width of zero and collapses the sidebar; a widening brings it
        // back, as it does when a real window opens.
        controller.view.window?.setContentSize(NSSize(width: 1_700, height: 1_400))
        await AppKitTestSupport.settle()

        playback.activePlaylistID = "p1"
        playback.setConnectionState(state)
        await AppKitTestSupport.settle()
        return playback
    }

    /// Runs `change` and returns which counted bodies ran because of it: it waits until the
    /// change rendered, however late a busy machine gets to it, then until everything the change
    /// queued has run, so a body that runs late still counts and one that never runs had its chance.
    /// Async, so the main-actor work the change starts runs while it waits, as it does in the app.
    private func bodies(file: StaticString = #filePath, line: UInt = #line, after change: () -> Void) async -> [String: Int] {
        ViewBodyTally.counts = [:]
        change()
        let rendered = await AppKitTestSupport.settle(until: { !(ViewBodyTally.counts ?? [:]).isEmpty })
        XCTAssertTrue(rendered, "the change rendered nothing", file: file, line: line)
        await AppKitTestSupport.settle()
        defer { ViewBodyTally.counts = nil }
        return ViewBodyTally.counts ?? [:]
    }

    private func trackRows(in counts: [String: Int]) -> Set<String> {
        Set(counts.keys.filter { $0.hasPrefix("TrackListRow:") }.map { String($0.dropFirst("TrackListRow:".count)) })
    }

    private func playlistRows(in counts: [String: Int]) -> Set<String> {
        Set(counts.keys.filter { $0.hasPrefix("PlaylistListRow:") }.map { String($0.dropFirst("PlaylistListRow:".count)) })
    }

    private func assertOnlyTheRowsChanged(
        _ counts: [String: Int],
        tracks: Set<String>,
        playlists: Set<String>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for container in [
            "PlaylistBrowserView",
            "PlaylistBrowserSidebar",
            "PlaylistsSidebarSectionContent",
            "PlaylistBrowserMainDetailColumn",
            "PlaylistDetailContent",
        ] {
            XCTAssertNil(counts[container], "\(container) re-rendered", file: file, line: line)
        }
        XCTAssertEqual(trackRows(in: counts), tracks, "track rows that re-rendered", file: file, line: line)
        XCTAssertEqual(playlistRows(in: counts), playlists, "sidebar rows that re-rendered", file: file, line: line)
    }

    func testPlayPauseRerendersOnlyThePlayingRowAndThePlayingPlaylist() async throws {
        let playback = try await hostBrowserPlaying()
        let paused = await bodies { playback.setConnectionState(.paused(Self.nowPlaying("t3"))) }
        assertOnlyTheRowsChanged(paused, tracks: ["t3"], playlists: ["p1"])

        let resumed = await bodies { playback.setConnectionState(.playing(Self.nowPlaying("t3"))) }
        assertOnlyTheRowsChanged(resumed, tracks: ["t3"], playlists: ["p1"])
    }

    func testANewTrackRerendersOnlyTheOldAndTheNewPlayingRow() async throws {
        let playback = try await hostBrowserPlaying()

        let next = await bodies { playback.setConnectionState(.playing(Self.nowPlaying("t4"))) }
        assertOnlyTheRowsChanged(next, tracks: ["t3", "t4"], playlists: [])

        // Starting another playlist moves the sidebar's playing mark from one row to the other.
        let otherPlaylist = await bodies {
            playback.activePlaylistID = "p2"
            playback.setConnectionState(.playing(Self.nowPlaying("t5")))
        }
        assertOnlyTheRowsChanged(otherPlaylist, tracks: ["t4", "t5"], playlists: ["p1", "p2"])
    }

    /// An Apple Music song started from another list is found among the rows by title, artists
    /// and length (#396). One change of the player looks for it once for the whole list: done by
    /// each row, one pause on a list of 1000 songs held the main thread for 0.3 to 0.5 s.
    func testAPauseLooksForTheAppleMusicPlayingRowOncePerList() async throws {
        let rowCount = 300
        // On screen: a row the table hasn't drawn has nothing to redraw (#645). Looking for it
        // still goes through every row first, for a row with the catalog id.
        let matched = 4
        func song(_ index: Int) -> MusicPlaylistTrackItem {
            MusicPlaylistTrackItem(id: "r\(index)", content: .track(MusicTrack(
                id: "r\(index)",
                name: "Song \(index)",
                artists: ["Artist"],
                albumArtworkURL: nil,
                albumName: nil,
                durationMilliseconds: 180_000,
                isExplicit: false,
                isPlayable: true,
                linkedFromID: nil,
                uri: "applemusic:song:\(index)"
            )))
        }
        // Played from Search: the player reports the catalog id, which no row of the list has.
        func state(playing: Bool) -> PlaybackConnectionState {
            let nowPlaying = PlaybackNowPlaying(
                name: "Song \(matched)",
                artists: ["Artist"],
                albumName: "Album",
                albumID: nil,
                albumArtURL: nil,
                durationMilliseconds: 180_000,
                positionMilliseconds: 10_000,
                uri: "applemusic:song:i.fromSearch"
            )
            return playing ? .playing(nowPlaying) : .paused(nowPlaying)
        }
        let playback = try await hostBrowser(tracks: (0..<rowCount).map(song), playing: state(playing: true))

        for playing in [false, true] {
            let counts = await bodies { playback.setConnectionState(state(playing: playing)) }
            XCTAssertEqual(counts["TrackListPlaybackMarks.markedURI"], 1, "searches for the playing row")
            XCTAssertEqual(trackRows(in: counts), ["r\(matched)"], "the row found by title shows the change")
        }
    }

    /// #645: the bar and the playing row must show a press within 50 ms. The real browser window
    /// in Apple Music mode with a list as long as my Liked Songs (2,543 songs, #413) open and its
    /// playing song found by title, as for a song started from Search: the press goes through the
    /// bar's own call, until the bar and the row have drawn the new state.
    ///
    /// What made a press slow was work for every song of the list: the table had built a view for
    /// each one to count them, and each of those views worked out its playing mark again on every
    /// press (2,544 per press, 27 to 51 ms). Timing that against 50 ms failed on a busy machine by
    /// under a millisecond (#662), so this counts that work instead: a press may only reach the
    /// rows the window shows, plus the few the table keeps ready, however long the list is.
    func testAPressReachesOnlyTheRowsOnScreenOfALongList() async throws {
        let rowCount = 2_543
        // On screen, as the song you just pressed play on is.
        let matched = 5
        func song(_ index: Int) -> MusicPlaylistTrackItem {
            MusicPlaylistTrackItem(id: "r\(index)", content: .track(MusicTrack(
                id: "r\(index)", name: "Song \(index)", artists: ["Artist"], albumArtworkURL: nil, albumName: nil,
                durationMilliseconds: 180_000, isExplicit: false, isPlayable: true, linkedFromID: nil,
                uri: "applemusic:song:\(index)"
            )))
        }
        let playingURI = "applemusic:song:i.fromSearch"
        let nowPlaying = PlaybackNowPlaying(
            name: "Song \(matched)", artists: ["Artist"], albumName: "Album", albumID: nil, albumArtURL: nil,
            durationMilliseconds: 180_000, positionMilliseconds: 0, uri: playingURI
        )
        // The player reads the song back as MusicKit does: with its catalog id, which no row of
        // the list has, and its own title, artists and length.
        let player = ScriptedAppleMusicPlayer()
        player.songs[playingURI] = MusicTrack(
            id: playingURI, name: nowPlaying.name, artists: nowPlaying.artists, albumArtworkURL: nil,
            albumName: nil, durationMilliseconds: 180_000, isExplicit: false, isPlayable: true, linkedFromID: nil,
            uri: playingURI
        )
        let provider = AppleMusicPlaybackProvider(player: player)
        // The bar shows Play before a song starts, as the app's does, then the song plays.
        let playback = try await hostBrowser(tracks: (0..<rowCount).map(song), playing: .paused(nowPlaying), provider: provider)
        playback.deviceID = AppleMusicPlaybackProvider.deviceID
        playback.setActivePlaybackDeviceID(AppleMusicPlaybackProvider.deviceID)
        // Started in the player, as a song from Search is: a press then has a song to pause and
        // resume, and the player's reads agree with what the bar shows (#693).
        try await provider.play(.items(uris: [playingURI], startURI: nil), deviceID: AppleMusicPlaybackProvider.deviceID)
        playback.setConnectionState(.playing(nowPlaying))
        await AppKitTestSupport.settle()
        let window = try XCTUnwrap(ViewTestHost.windows.last)
        // The table keeps a few rows ready above and below the window, so allow a margin.
        let rowsThatFit = Int((window.contentLayoutRect.height / TrackListRow.listRowHeight).rounded(.up))

        for press in 1...6 {
            ViewBodyTally.counts = [:]
            let pressedAt = ContinuousClock.now
            playback.requestTogglePlayPause()
            XCTAssertEqual(PlaylistBrowserPlaybackHelpers.isCurrentlyPlaying(connectionState: playback.connectionState), press.isMultiple(of: 2))
            let drawn = await AppKitTestSupport.settle(until: {
                (ViewBodyTally.counts?["PlaybackControlsView"] ?? 0) > 0
                    && (ViewBodyTally.counts?["TrackListRow:r\(matched)"] ?? 0) > 0
            })
            window.displayIfNeeded()
            let counts = ViewBodyTally.counts ?? [:]
            XCTAssertTrue(drawn, "press \(press): the bar and the playing row didn't redraw")
            XCTAssertEqual(trackRows(in: counts), ["r\(matched)"], "press \(press): rows that re-rendered")
            let rowsReached = counts["TrackListPlaybackMarks.rowMark"] ?? 0
            XCTAssertGreaterThan(rowsReached, 0, "press \(press): no row heard of it")
            XCTAssertLessThanOrEqual(
                rowsReached,
                4 * rowsThatFit,
                "press \(press) reached \(rowsReached) of \(rowCount) rows, though about \(rowsThatFit) fit in the window"
            )
            ViewBodyTally.counts = nil
            // The player takes the press after MusicKit's measured lag, on its own clock: once
            // the press reached it, that time passes, so its reads report the new state.
            let command = press.isMultiple(of: 2) ? "resume" : "pause"
            let sentSoFar = { player.commands.filter { $0 == command }.count }
            let sent = await AppKitTestSupport.settle(until: { sentSoFar() >= (press + 1) / 2 })
            XCTAssertTrue(sent, "press \(press): the \(command) never reached the player")
            XCTAssertEqual(sentSoFar(), (press + 1) / 2, "press \(press): the \(command) reached the player more than once")
            player.advance(by: ScriptedAppleMusicPlayer.lag[command] ?? 0)
            // The next press comes once this press's icon swap is over, as a person's would: the
            // swap is a 0.18 s animation on the wall clock (`PlaybackControlsView`), so its end is
            // that time after the press, and its last frame has drawn once the window settled.
            let swapped = await AppKitTestSupport.settle(until: { pressedAt.duration(to: .now) >= Self.iconSwap })
            XCTAssertTrue(swapped)
            await AppKitTestSupport.settle()
        }
    }
}

@MainActor
private final class RenderScopeTokenProvider: PlaybackAccessTokenProviding, SpotifyAccessTokenProviding {
    func playbackAccessToken() async throws -> String { "render-scope-token" }
    func refreshedPlaybackAccessToken() async throws -> String { "render-scope-token" }
    func accessToken() async throws -> String { "render-scope-token" }
    func refreshAccessTokenAfterUnauthorized(rejectedToken: String) async throws -> String { "render-scope-token" }
}

extension TrackRowPlaybackSource {
    /// A player that never connects: every row shows as not playing.
    static var nothingPlaying: TrackRowPlaybackSource {
        TrackRowPlaybackSource(session: PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander())))
    }
}
