import Foundation

/// The reads Spotify Autoplay needs (#617). ``SpotifyAutoplayReads`` makes them; tests answer
/// them from sample songs.
protocol SpotifyAutoplayCatalog: Sendable {
    /// Songs by the artist with this name, Spotify's best match first (`GET /v1/search` with
    /// an `artist:` filter, at most 10).
    func autoplayTracks(byArtistNamed name: String) async throws -> [MusicTrack]
    /// The songs of each of the listener's playlists that Wax already keeps on disk, one array
    /// per playlist. Reads no network.
    func autoplayLibraryPlaylists() async -> [[MusicTrack]]
}

/// Autoplay suggestions for Spotify (#617). Spotify closed Recommendations and Related Artists
/// to apps registered after 27 Nov 2024, and artist top tracks to development-mode apps in
/// February 2026, and every Wax install registers its own app. So this builds them from what
/// stays open:
///
/// - the artists of the recent queue;
/// - the artists that share the listener's own playlists with them (the co-occurrence "More
///   from your library" uses), read from the playlists Wax already keeps on disk;
/// - songs by those artists: the ones in those playlists, and the ones a search with an
///   `artist:` filter finds.
///
/// Searches stay inside Spotify's rate limits: each artist is searched once per session, at
/// most ``searchesPerLook`` new ones each time Autoplay looks, and none for a while after
/// Spotify answers 429.
@MainActor
final class SpotifyAutoplaySource: QueueAutoplaySource {
    /// How many of the recent artists are looked at, the most weighted first.
    static let seedArtistLimit = 6
    /// How many artists that share playlists with each recent artist contribute songs.
    static let relatedArtistLimit = 6
    /// How many songs of each artist are candidates.
    static let songsPerArtist = 10
    /// New artist searches each time Autoplay looks (once per new song at most).
    static let searchesPerLook = 3
    /// A recent artist's own songs count less than a related artist's, so the queue moves on
    /// to other artists instead of playing one artist's songs.
    static let ownSongsFactor = 0.6
    /// How long the playlists read from disk are used before they are read again.
    static let libraryMaxAge: Duration = .seconds(15 * 60)
    /// How long searches pause after a 429 that gave no `Retry-After`.
    static let rateLimitPause: Duration = .seconds(60)

    private let catalog: any SpotifyAutoplayCatalog
    private let now: () -> ContinuousClock.Instant

    init(
        catalog: any SpotifyAutoplayCatalog,
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.catalog = catalog
        self.now = now
    }

    /// Search results by normalized artist name, for the whole session.
    private var searchedTracks: [String: [MusicTrack]] = [:]
    private var library: SpotifyAutoplayLibraryIndex?
    private var libraryReadAt: ContinuousClock.Instant?
    private var searchesPausedUntil: ContinuousClock.Instant?

    func candidates(for seeds: [QueueAutoplaySeed]) async throws -> [QueueAutoplayCandidate] {
        let seedArtists = Array(QueueAutoplayArtistWeights.weights(seeds).prefix(Self.seedArtistLimit))
        guard !seedArtists.isEmpty else { return [] }
        let library = await currentLibrary()
        try Task.checkCancellation()
        let artists = Self.artistsToSuggestFrom(seedArtists: seedArtists, library: library)
        try await search(artists)
        return Self.score(artists: artists, library: library, searchedTracks: searchedTracks)
    }

    // MARK: - Pure parts

    /// An artist whose songs Autoplay may add, and how strongly the recent queue points at it.
    struct WeightedSourceArtist: Equatable {
        /// The name as Spotify spells it.
        let name: String
        let weight: Double
    }

    /// The recent artists (their own songs at ``ownSongsFactor``) and, for each, the artists
    /// that share most of the listener's playlists with them, most weighted first.
    static func artistsToSuggestFrom(
        seedArtists: [QueueAutoplayArtistWeights.WeightedArtist],
        library: SpotifyAutoplayLibraryIndex
    ) -> [WeightedSourceArtist] {
        var weightByKey: [String: Double] = [:]
        var nameByKey: [String: String] = [:]
        var order: [String] = []
        func add(_ name: String, _ weight: Double) {
            let key = QueueAutoplayIdentity.normalized(name)
            guard !key.isEmpty else { return }
            if weightByKey[key] == nil {
                order.append(key)
                nameByKey[key] = name
            }
            weightByKey[key, default: 0] += weight
        }
        for seed in seedArtists {
            add(seed.name, seed.weight * ownSongsFactor)
            for related in library.relatedArtists(of: seed.name).prefix(relatedArtistLimit) {
                add(related.name, seed.weight * related.similarity)
            }
        }
        return order.enumerated()
            .sorted { lhs, rhs in
                let left = weightByKey[lhs.element] ?? 0
                let right = weightByKey[rhs.element] ?? 0
                return left != right ? left > right : lhs.offset < rhs.offset
            }
            .compactMap { _, key in
                nameByKey[key].map { WeightedSourceArtist(name: $0, weight: weightByKey[key] ?? 0) }
            }
    }

    /// Each song's score is its artist's weight, a bit less the further down that artist's
    /// list it is: the songs a search found first, then the ones from the listener's playlists.
    static func score(
        artists: [WeightedSourceArtist],
        library: SpotifyAutoplayLibraryIndex,
        searchedTracks: [String: [MusicTrack]]
    ) -> [QueueAutoplayCandidate] {
        var scoreByURI: [String: Double] = [:]
        var trackByURI: [String: MusicTrack] = [:]
        var order: [String] = []
        for artist in artists {
            let key = QueueAutoplayIdentity.normalized(artist.name)
            var songs: [MusicTrack] = []
            var seen: Set<String> = []
            for track in (searchedTracks[key] ?? []) + library.tracks(byArtistKey: key)
            where seen.insert(track.uri).inserted {
                songs.append(track)
            }
            for (position, track) in songs.prefix(songsPerArtist).enumerated() {
                if trackByURI[track.uri] == nil {
                    trackByURI[track.uri] = track
                    order.append(track.uri)
                }
                scoreByURI[track.uri, default: 0] += artist.weight / (1 + 0.15 * Double(position))
            }
        }
        return order.compactMap { uri in
            trackByURI[uri].map { QueueAutoplayCandidate(track: $0, score: scoreByURI[uri] ?? 0) }
        }
    }

    /// Search answers whose lead artist is the artist searched for: the `artist:` filter also
    /// matches songs where they only feature.
    static func songsLed(by name: String, in tracks: [MusicTrack]) -> [MusicTrack] {
        let key = QueueAutoplayIdentity.normalized(name)
        return tracks.filter { $0.artists.first.map(QueueAutoplayIdentity.normalized) == key }
    }

    // MARK: - Reads

    private func currentLibrary() async -> SpotifyAutoplayLibraryIndex {
        if let library, let libraryReadAt, libraryReadAt.duration(to: now()) < Self.libraryMaxAge {
            return library
        }
        let playlists = await catalog.autoplayLibraryPlaylists()
        // Indexing a big library is real work: it stays off the main thread.
        let index = await Task.detached(priority: .utility) {
            SpotifyAutoplayLibraryIndex(playlists: playlists)
        }.value
        library = index
        libraryReadAt = now()
        return index
    }

    private func search(_ artists: [WeightedSourceArtist]) async throws {
        var searches = 0
        for artist in artists where searches < Self.searchesPerLook {
            let key = QueueAutoplayIdentity.normalized(artist.name)
            guard searchedTracks[key] == nil else { continue }
            if let searchesPausedUntil, now() < searchesPausedUntil { return }
            try Task.checkCancellation()
            searches += 1
            do {
                let found = try await catalog.autoplayTracks(byArtistNamed: artist.name)
                searchedTracks[key] = Self.songsLed(by: artist.name, in: found)
            } catch let SpotifyAPIError.rateLimited(retryAfter) {
                // The songs from the playlists still go on; searches wait.
                let pause = retryAfter.map { Duration.milliseconds(Int64($0 * 1000)) } ?? Self.rateLimitPause
                searchesPausedUntil = now().advanced(by: max(pause, Self.rateLimitPause))
                SpotiglassLog.info(.playback, "Spotify Autoplay: searches pause for \(pause) after a 429")
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // One failed search costs that artist's search songs this time, not the look.
                SpotiglassLog.error(.playback, "Spotify Autoplay search failed: \(String(describing: error))")
            }
        }
    }
}

/// The listener's playlists as Autoplay reads them: which artists share playlists, and the
/// songs by each artist in them.
struct SpotifyAutoplayLibraryIndex: Equatable {
    struct RelatedArtist: Equatable {
        let name: String
        /// 1 for the artist sharing the most playlists with the one asked about, down to 0.3.
        let similarity: Double
    }

    /// Normalized artist names in each playlist.
    private let playlistArtists: [Set<String>]
    /// The playlists each artist is in, by index into ``playlistArtists``.
    private let playlistsByArtist: [String: [Int]]
    private let nameByKey: [String: String]
    private let tracksByArtistKey: [String: [MusicTrack]]

    init(playlists: [[MusicTrack]]) {
        var playlistArtists: [Set<String>] = []
        var nameByKey: [String: String] = [:]
        var tracksByArtistKey: [String: [MusicTrack]] = [:]
        var seenURIs: Set<String> = []
        for playlist in playlists {
            var artists: Set<String> = []
            for track in playlist where track.isPlayable != false {
                for name in track.artists {
                    let key = QueueAutoplayIdentity.normalized(name)
                    guard !key.isEmpty else { continue }
                    artists.insert(key)
                    if nameByKey[key] == nil { nameByKey[key] = name }
                }
                if let lead = track.artists.first.map(QueueAutoplayIdentity.normalized), !lead.isEmpty,
                    seenURIs.insert(track.uri).inserted
                {
                    tracksByArtistKey[lead, default: []].append(track)
                }
            }
            if !artists.isEmpty { playlistArtists.append(artists) }
        }
        var playlistsByArtist: [String: [Int]] = [:]
        for (index, artists) in playlistArtists.enumerated() {
            for artist in artists { playlistsByArtist[artist, default: []].append(index) }
        }
        self.playlistArtists = playlistArtists
        self.playlistsByArtist = playlistsByArtist
        self.nameByKey = nameByKey
        self.tracksByArtistKey = tracksByArtistKey
    }

    /// The artists that appear in the same playlists as `name`, most shared playlists first.
    func relatedArtists(of name: String) -> [RelatedArtist] {
        let key = QueueAutoplayIdentity.normalized(name)
        var shared: [String: Int] = [:]
        for index in playlistsByArtist[key] ?? [] {
            for other in playlistArtists[index] where other != key { shared[other, default: 0] += 1 }
        }
        guard let most = shared.values.max() else { return [] }
        return shared
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .compactMap { other, count in
                nameByKey[other].map {
                    RelatedArtist(name: $0, similarity: max(0.3, Double(count) / Double(most)))
                }
            }
    }

    func tracks(byArtistKey key: String) -> [MusicTrack] {
        tracksByArtistKey[key] ?? []
    }
}

/// Spotify Autoplay's live reads: search through the Web API, playlists from Wax's disk cache.
struct SpotifyAutoplayReads: SpotifyAutoplayCatalog, @unchecked Sendable {
    let api: SpotifyAPIClient
    let cache: SpotifyLocalCache?

    func autoplayTracks(byArtistNamed name: String) async throws -> [MusicTrack] {
        let quoted = name.replacingOccurrences(of: "\"", with: "")
        // from_token: Spotify then says which songs play in the listener's country.
        return try await api.searchTracks(
            query: "artist:\"\(quoted)\"",
            limit: SpotifyAutoplaySource.songsPerArtist,
            market: "from_token"
        )
    }

    func autoplayLibraryPlaylists() async -> [[MusicTrack]] {
        guard let cache else { return [] }
        return await Task.detached(priority: .utility) {
            Self.playlists(in: cache)
        }.value
    }

    private static func playlists(in cache: SpotifyLocalCache) -> [[MusicTrack]] {
        // try?: a cache file that can't be read only leaves its songs out; search still works.
        if let summaries = try? cache.loadPlaylistsBundle()?.playlists, !summaries.isEmpty {
            let playlists = summaries.compactMap { summary -> [MusicTrack]? in
                // try?: as above, an unreadable playlist file leaves that playlist out.
                guard let items = try? cache.loadTracksIgnoringAge(playlistID: summary.id, snapshotID: summary.snapshotID)
                else { return nil }
                return items.compactMap(\.continuationTrack)
            }
            if !playlists.isEmpty { return playlists }
        }
        // Playlists "More from your library" collected, when the list itself isn't on disk.
        // try?: as above.
        return ((try? cache.loadLibraryContinuationIndexIgnoringAge())?.playlists ?? []).map(\.tracks)
    }
}
