import XCTest
@testable import Spotiglass

/// Autoplay on Spotify (#617): a queue that behaves like Spotify's (songs added go after the
/// songs queued by hand but before the rest of the album or playlist), sessions through it, and
/// the source built from search and the listener's own playlists.
@MainActor
final class SpotifyAutoplayTests: XCTestCase {
    // MARK: - Sessions on Spotify's queue

    /// An album plays, I queue two songs by hand partway through, Autoplay is on. Nothing is
    /// added while the album or my songs are still ahead, so the album plays to its end in
    /// order with my songs where Spotify put them. After that every song is new, never one
    /// heard before, and the queue never runs dry over a long session.
    func testAnAlbumPlaysToItsEndThenAutoplayKeepsGoingWithNewSongs() async throws {
        let h = makeHarness()
        let album = (1...6).map { Self.track("album-\($0)", artist: "Seed Artist") }
        h.queue.play(album)
        try await h.notePlaying()
        h.autoplay.setEnabled(true)
        await h.autoplay.settle()
        XCTAssertEqual(h.queue.appended, [], "the rest of the album is ahead: nothing is added")

        try await h.next()
        h.queue.queueByHand([Self.track("mine-1", artist: "Own Pick"), Self.track("mine-2", artist: "Own Pick")])
        var played = ["spotify:track:album-1", "spotify:track:album-2"]
        for _ in 0..<40 {
            try await h.next()
            let now = try XCTUnwrap(h.queue.current?.uri)
            XCTAssertFalse(played.contains(now), "\(now) played twice")
            played.append(now)
        }

        XCTAssertEqual(
            Array(played.prefix(8)),
            ["album-1", "album-2", "mine-1", "mine-2", "album-3", "album-4", "album-5", "album-6"].map { "spotify:track:\($0)" },
            "my songs and the album play as Spotify queued them, with nothing of Autoplay's in between"
        )
        XCTAssertTrue(played.dropFirst(8).allSatisfy { $0.contains(":new-") }, "only new songs after the album")
        XCTAssertEqual(h.queue.appended.count, 35, "one song added per new song from the album's last one on")
        XCTAssertEqual(h.queue.addsAheadOfOtherSongs, 0, "no add landed ahead of a song already queued")
        XCTAssertEqual(h.autoplay.status, .on)
    }

    /// A playlist whose last items are podcast episodes: while they are ahead nothing is added,
    /// or Spotify would play the song before them.
    func testEpisodesLeftInThePlaylistCountAsAhead() async throws {
        let h = makeHarness()
        h.queue.play([Self.track("song-1", artist: "Seed Artist"), Self.track("song-2", artist: "Seed Artist")], episodesAfter: 2)
        try await h.notePlaying()
        h.autoplay.setEnabled(true)
        await h.autoplay.settle()
        try await h.next()

        XCTAssertEqual(h.queue.current?.uri, "spotify:track:song-2")
        XCTAssertEqual(h.queue.appended, [], "two episodes are still ahead: nothing is added")
        XCTAssertEqual(h.queue.addsAheadOfOtherSongs, 0)
    }

    /// Turning Autoplay off stops the adds and leaves what it queued.
    func testTurningOffStopsAddingOnSpotify() async throws {
        let h = makeHarness()
        h.queue.play([Self.track("only", artist: "Seed Artist")])
        try await h.notePlaying()
        h.autoplay.setEnabled(true)
        await h.autoplay.settle()
        XCTAssertEqual(h.queue.appended.count, 1)

        h.autoplay.setEnabled(false)
        try await h.next()
        try await h.next()
        XCTAssertEqual(h.queue.appended.count, 1)
    }

    // MARK: - The source

    /// Artists that share my playlists with the artist playing are suggested, the one sharing
    /// the most first, ahead of the same artist's own songs; songs a search finds where the
    /// artist only features are left out.
    func testPlaylistNeighboursLeadAndSearchKeepsOnlySongsTheArtistLeads() async throws {
        let catalog = SampleSpotifyAutoplayCatalog()
        catalog.playlists = [
            [Self.track("p1-a", artist: "Seed Artist"), Self.track("p1-b", artist: "Close Friend")],
            [Self.track("p2-a", artist: "Seed Artist"), Self.track("p2-b", artist: "Close Friend"), Self.track("p2-c", artist: "Distant")],
            [Self.track("p3-a", artist: "Unrelated")],
        ]
        catalog.searchResults["Close Friend"] = [
            Self.track("cf-hit", artist: "Close Friend"),
            Self.track("cf-feature", artists: ["Someone Else", "Close Friend"]),
        ]
        let source = SpotifyAutoplaySource(catalog: catalog)

        let candidates = try await source.candidates(for: [QueueAutoplaySeed(track: Self.track("seed", artist: "Seed Artist"))])
        let ordered = QueueAutoplayRanking.ordered(candidates, excluded: []).map(\.id)

        XCTAssertFalse(ordered.contains("cf-feature"), "the artist only features on it")
        XCTAssertFalse(ordered.contains("p3-a"), "an artist in none of the seed artist's playlists")
        XCTAssertEqual(Array(ordered.prefix(2)), ["cf-hit", "p1-b"], "the artist sharing most playlists leads")
        XCTAssertLessThan(
            try XCTUnwrap(ordered.firstIndex(of: "p2-b")),
            try XCTUnwrap(ordered.firstIndex(of: "p1-a")),
            "a neighbour's songs come before the same artist's own"
        )
    }

    /// A long session stays inside Spotify's rate limits: each artist is searched once, at
    /// most three new searches per look, and the playlists are read from disk once.
    func testEachArtistIsSearchedOnceAndAtMostThreePerLook() async throws {
        let catalog = SampleSpotifyAutoplayCatalog()
        let artists = (1...8).map { "Artist \($0)" }
        catalog.playlists = [artists.enumerated().map { Self.track("p-\($0.offset)", artist: $0.element) }]
        let source = SpotifyAutoplaySource(catalog: catalog)
        let seeds = [QueueAutoplaySeed(track: Self.track("seed", artist: "Artist 1"))]

        _ = try await source.candidates(for: seeds)
        XCTAssertEqual(catalog.searches.count, 3)
        for _ in 0..<20 { _ = try await source.candidates(for: seeds) }
        XCTAssertEqual(catalog.searches.count, Set(catalog.searches).count, "an artist was searched twice")
        XCTAssertEqual(catalog.searches.count, 7, "the seed artist and its six playlist neighbours")
        XCTAssertEqual(catalog.playlistReads, 1)
    }

    /// Spotify answers 429: searches pause, the songs from my playlists still come, and
    /// searches resume once the pause is over.
    func testARateLimitPausesSearchesButKeepsSuggestingFromPlaylists() async throws {
        let catalog = SampleSpotifyAutoplayCatalog()
        catalog.playlists = [[Self.track("p-seed", artist: "Seed Artist"), Self.track("p-friend", artist: "Friend")]]
        catalog.searchErrors = [SpotifyAPIError.rateLimited(retryAfter: 120)]
        var clock = ContinuousClock.now
        let source = SpotifyAutoplaySource(catalog: catalog, now: { clock })
        let seeds = [QueueAutoplaySeed(track: Self.track("seed", artist: "Seed Artist"))]

        let first = try await source.candidates(for: seeds)
        XCTAssertEqual(Set(first.map(\.track.id)), ["p-seed", "p-friend"])
        XCTAssertEqual(catalog.searches.count, 1)

        clock = clock.advanced(by: .seconds(60))
        _ = try await source.candidates(for: seeds)
        XCTAssertEqual(catalog.searches.count, 1, "still inside the Retry-After")

        clock = clock.advanced(by: .seconds(61))
        _ = try await source.candidates(for: seeds)
        XCTAssertEqual(catalog.searches.count, 3)
    }

    /// The control says what Spotify's Autoplay is built from and where its songs go.
    func testSpotifyTextSaysWhatAutoplayUsesAndWhereSongsGo() {
        XCTAssertEqual(QueueAutoplayStatusLine.key(for: .on, service: .spotify), "queue.autoplay.status.on.spotify")
        XCTAssertEqual(QueueAutoplayStatusLine.key(for: .on, service: .appleMusic), "queue.autoplay.status.on")
        XCTAssertEqual(QueueAutoplayButton.helpKey(isEnabled: false, service: .spotify), "queue.autoplay.help.off.spotify")
        XCTAssertEqual(QueueAutoplayButton.helpKey(isEnabled: true, service: .appleMusic), "queue.autoplay.help.on")
        for key in ["queue.autoplay.status.on.spotify", "queue.autoplay.help.off.spotify", "queue.autoplay.help.on.spotify"] {
            XCTAssertNotEqual(SpotiglassL10n.string(key), key, "\(key) has no text")
        }
        XCTAssertNotEqual(SpotiglassL10n.string("queue.autoplay.help.off.spotify"), SpotiglassL10n.string("queue.autoplay.help.off"))
        XCTAssertEqual(QueueAutoplay.fillTarget(for: .spotify), 1)
    }

    // MARK: - Harness

    @MainActor
    private struct Harness {
        let queue: SpotifyLikeQueue
        let autoplay: QueueAutoplay
        let clock: TestClock

        func notePlaying() async throws {
            autoplay.nowPlayingChanged(queue.current.map { QueueAutoplaySeed(track: $0) })
            await autoplay.settle()
        }

        /// The song ends a few minutes later and the next one starts.
        func next() async throws {
            clock.now = clock.now.advanced(by: .seconds(200))
            queue.advance()
            try await notePlaying()
        }
    }

    final class TestClock {
        var now = ContinuousClock.now
    }

    private func makeHarness() -> Harness {
        let queue = SpotifyLikeQueue()
        let clock = TestClock()
        let autoplay = QueueAutoplay(
            source: SampleAutoplaySource(),
            flag: StoredFlag(key: "test.spotify.autoplay", defaultValue: false, defaults: nil),
            fillTarget: QueueAutoplay.fillTarget(for: .spotify),
            service: .spotify,
            now: { clock.now },
            songCommandSent: { nil }
        )
        autoplay.player = queue
        return Harness(queue: queue, autoplay: autoplay, clock: clock)
    }

    static func track(_ id: String, artist: String) -> MusicTrack {
        track(id, artists: [artist])
    }

    static func track(_ id: String, artists: [String]) -> MusicTrack {
        MusicTrack(
            id: id, name: id, artists: artists, albumArtworkURL: nil, durationMilliseconds: 200_000,
            isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:\(id)"
        )
    }
}

/// Spotify's queue as the Web API exposes it: what plays after the current song is the songs
/// queued by hand, then the rest of the context. Adding puts a song at the end of the queued
/// ones, ahead of the context.
@MainActor
final class SpotifyLikeQueue: QueueAutoplayPlayer {
    private(set) var current: MusicTrack?
    private var userQueue: [MusicTrack] = []
    private var context: [MusicTrack] = []
    /// Podcast episodes left in the context after its songs.
    private var contextEpisodes = 0
    private(set) var appended: [String] = []
    /// Adds that went in while the context still had songs ahead: they cut ahead of them.
    private(set) var addsAheadOfOtherSongs = 0

    func play(_ tracks: [MusicTrack], episodesAfter: Int = 0) {
        current = tracks.first
        context = Array(tracks.dropFirst())
        contextEpisodes = episodesAfter
        userQueue = []
    }

    func queueByHand(_ tracks: [MusicTrack]) {
        userQueue += tracks
    }

    func advance() {
        if !userQueue.isEmpty {
            current = userQueue.removeFirst()
        } else if !context.isEmpty {
            current = context.removeFirst()
        } else {
            current = nil
        }
    }

    func autoplayUpcoming() async throws -> QueueAutoplayUpcoming {
        let tracks = userQueue + context
        return QueueAutoplayUpcoming(tracks: tracks, itemCount: tracks.count + contextEpisodes)
    }

    func autoplayAppend(_ track: MusicTrack, isWanted: @escaping @MainActor () -> Bool) async throws {
        guard isWanted() else { throw CancellationError() }
        if !context.isEmpty || contextEpisodes > 0 { addsAheadOfOtherSongs += 1 }
        userQueue.append(track)
        appended.append(track.uri)
    }
}

/// Answers Spotify Autoplay's reads from sample songs and records them.
final class SampleSpotifyAutoplayCatalog: SpotifyAutoplayCatalog, @unchecked Sendable {
    var playlists: [[MusicTrack]] = []
    var searchResults: [String: [MusicTrack]] = [:]
    var searchErrors: [Error] = []
    private(set) var searches: [String] = []
    private(set) var playlistReads = 0

    func autoplayTracks(byArtistNamed name: String) async throws -> [MusicTrack] {
        searches.append(name)
        if !searchErrors.isEmpty { throw searchErrors.removeFirst() }
        return searchResults[name] ?? []
    }

    func autoplayLibraryPlaylists() async -> [[MusicTrack]] {
        playlistReads += 1
        return playlists
    }
}
