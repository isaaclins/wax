import Foundation

extension PlaybackNowPlaying {
    /// LRCLIB expects a single artist string; matches Spotify’s multi-artist display.
    var lrcLibArtistQuery: String {
        artistText
    }

    /// Apple Music names a single's album "<title> - Single" (or " - EP"); LRCLIB stores it
    /// without that ending, and its exact lookup misses on the longer name (#657).
    var lrcLibAlbumQuery: String {
        let album = albumName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return album.replacingOccurrences(
            of: #"\s+-\s+(single|ep)$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    var lrcLibDurationSeconds: Int {
        max(1, durationMilliseconds / 1_000)
    }

    /// The key lyrics are cached and looked up under, or `nil` when the item isn't a music
    /// track (episodes, unknown items). Spotify tracks keep their bare track id, so lyrics
    /// cached before Apple Music existed still load. Apple Music songs get an
    /// `applemusic-song-<id>` key so they can never collide with a Spotify id.
    var lyricsTrackKey: String? {
        guard let uri else { return nil }
        let parts = uri.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, !parts[2].isEmpty else { return nil }
        switch (parts[0], parts[1]) {
        case ("spotify", "track"):
            return parts[2]
        case ("applemusic", "song"), ("applemusic", "track"):
            // Library ids contain dots (`i.abc`); the disk cache only keeps letters, digits and `-`.
            return "applemusic-song-" + parts[2].replacingOccurrences(of: ".", with: "-")
        default:
            return nil
        }
    }
}

enum FetchedLyrics: Equatable, Codable {
    case instrumental
    case synced([SyncedLyricLine])
    case unsyncedPlain([String])
}

struct LrcLibClient: Sendable {
    enum FetchMode: Sendable {
        /// Preferred in production: call `get-cached` first and only call `get` when needed.
        case sequentialCachedFirst
        /// Optional pressure mode for experiments; calls both endpoints concurrently.
        case parallel
    }

    enum Failure: Error, Equatable {
        case invalidURL
        case http(Int)
        case rateLimited(retryAfter: TimeInterval?)
        case decoding
        case noLyrics
    }

    private let session: URLSession
    private let baseURL: URL
    private let fetchMode: FetchMode

    init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://lrclib.net")!,
        fetchMode: FetchMode = .sequentialCachedFirst
    ) {
        self.session = session
        self.baseURL = baseURL
        self.fetchMode = fetchMode
    }

    /// Fetches `/api/get-cached` first, then falls back to `/api/get` only when
    /// the cached endpoint has no usable lyrics payload.
    func fetchLyrics(for track: PlaybackNowPlaying) async throws -> FetchedLyrics {
        switch fetchMode {
        case .sequentialCachedFirst:
            return try await fetchLyricsSequentialCachedFirst(for: track)
        case .parallel:
            return try await fetchLyricsParallel(for: track)
        }
    }

    private func fetchLyricsSequentialCachedFirst(for track: PlaybackNowPlaying) async throws -> FetchedLyrics {
        do {
            let cachedResponse = try await get(endpoint: "get-cached", track: track)
            if let cachedResponse, let lyrics = mapResponse(cachedResponse) {
                return lyrics
            }
        } catch let failure as Failure {
            switch failure {
            case .noLyrics:
                break // cached miss/unusable -> try full
            case .decoding:
                break // cached decode issue -> try full
            case let .http(code) where code >= 500:
                break // transient server-side cached error -> try full
            case .rateLimited:
                throw failure // under pressure, do not escalate to full endpoint
            case .invalidURL, .http:
                throw failure
            }
        }

        let fullResponse = try await get(endpoint: "get", track: track)
        if let fullResponse, let lyrics = mapResponse(fullResponse) {
            return lyrics
        }
        return try await searchBestMatch(for: track)
    }

    private func fetchLyricsParallel(for track: PlaybackNowPlaying) async throws -> FetchedLyrics {
        async let cachedResult = getResult(endpoint: "get-cached", track: track)
        async let fullResult = getResult(endpoint: "get", track: track)
        let cached = try await cachedResult
        let full = try await fullResult
        for response in [cached, full] {
            switch response {
            case let .success(dto?):
                if let lyrics = mapResponse(dto) { return lyrics }
            case .success(nil):
                continue
            case let .failure(error):
                if case let .rateLimited(retryAfter) = error {
                    throw Failure.rateLimited(retryAfter: retryAfter)
                }
            }
        }
        for response in [cached, full] {
            if case let .failure(error) = response {
                throw error
            }
        }
        return try await searchBestMatch(for: track)
    }

    /// The exact lookups missed: search LRCLIB by title and artist and take the closest
    /// result that is the same song (#657). Nothing close enough is still "no lyrics".
    private func searchBestMatch(for track: PlaybackNowPlaying) async throws -> FetchedLyrics {
        let results: [LrcLibSearchResultDTO]? = try await request(
            endpoint: "search",
            queryItems: [
                URLQueryItem(name: "track_name", value: LrcLibMatch.searchTitle(track.name)),
                URLQueryItem(name: "artist_name", value: track.lrcLibArtistQuery)
            ]
        )
        let candidates = (results ?? []).compactMap { result -> LrcLibMatch.Candidate? in
            guard let lyrics = mapResponse(result.response) else { return nil }
            return LrcLibMatch.Candidate(
                title: result.trackName ?? "",
                artist: result.artistName ?? "",
                durationSeconds: result.duration,
                lyrics: lyrics
            )
        }
        guard let best = LrcLibMatch.best(
            among: candidates,
            title: track.name,
            artists: track.artists,
            durationMilliseconds: track.durationMilliseconds
        ) else {
            throw Failure.noLyrics
        }
        return best.lyrics
    }

    private func getResult(
        endpoint: String,
        track: PlaybackNowPlaying
    ) async throws -> Result<LrcLibResponseDTO?, Failure> {
        do {
            return .success(try await get(endpoint: endpoint, track: track))
        } catch let failure as Failure {
            return .failure(failure)
        } catch {
            throw error
        }
    }

    private struct LrcLibResponseDTO: Decodable {
        let instrumental: Bool?
        let syncedLyrics: String?
        let plainLyrics: String?
    }

    private struct LrcLibSearchResultDTO: Decodable {
        let trackName: String?
        let artistName: String?
        let duration: Double?
        let instrumental: Bool?
        let syncedLyrics: String?
        let plainLyrics: String?

        var response: LrcLibResponseDTO {
            LrcLibResponseDTO(instrumental: instrumental, syncedLyrics: syncedLyrics, plainLyrics: plainLyrics)
        }
    }

    private func mapResponse(_ dto: LrcLibResponseDTO) -> FetchedLyrics? {
        if dto.instrumental == true {
            return .instrumental
        }
        if let raw = dto.syncedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let lines = LrcLineParser.parseSyncedLines(raw)
            if !lines.isEmpty {
                return .synced(lines)
            }
        }
        if let raw = dto.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let plainLines = raw
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !plainLines.isEmpty {
                return .unsyncedPlain(plainLines)
            }
        }
        return nil
    }

    private func get(endpoint: String, track: PlaybackNowPlaying) async throws -> LrcLibResponseDTO? {
        try await request(
            endpoint: endpoint,
            queryItems: [
                URLQueryItem(name: "track_name", value: track.name),
                URLQueryItem(name: "artist_name", value: track.lrcLibArtistQuery),
                URLQueryItem(name: "album_name", value: track.lrcLibAlbumQuery),
                URLQueryItem(name: "duration", value: String(track.lrcLibDurationSeconds))
            ]
        )
    }

    private func request<Response: Decodable>(endpoint: String, queryItems: [URLQueryItem]) async throws -> Response? {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("api/\(endpoint)"),
            resolvingAgainstBaseURL: false
        ) else {
            throw Failure.invalidURL
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw Failure.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue(AppMetadata.spotiglassHTTPUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 45

        // The log names the endpoint, never the song: the query is the user's listening (#603).
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if !(error is CancellationError) {
                SpotiglassLog.error(.api, "LRCLIB \(endpoint) failed: \(SpotiglassLog.describe(error))")
            }
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            SpotiglassLog.error(.api, "LRCLIB \(endpoint) answered without an HTTP response")
            throw Failure.http(-1)
        }
        if http.statusCode == 404 {
            SpotiglassLog.debug(.api, "LRCLIB \(endpoint) -> status=404 (no lyrics)")
            return nil
        }
        if http.statusCode == 429 {
            let retryAfter = parseRetryAfterSeconds(from: http)
            SpotiglassLog.error(
                .api,
                "LRCLIB \(endpoint) -> status=429 (Retry-After \(retryAfter.map { "\(Int($0.rounded())) s" } ?? "not sent"))"
            )
            throw Failure.rateLimited(retryAfter: retryAfter)
        }
        guard (200 ... 299).contains(http.statusCode) else {
            SpotiglassLog.error(.api, "LRCLIB \(endpoint) -> status=\(http.statusCode)")
            throw Failure.http(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            SpotiglassLog.error(.api, "LRCLIB \(endpoint) -> status=\(http.statusCode), \(SpotiglassLog.describe(error))")
            throw Failure.decoding
        }
    }

    private func parseRetryAfterSeconds(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(raw) {
            return max(0, seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }
}

/// Decides whether an LRCLIB search result is the song that is playing (#657). A result counts
/// only with the same title, the same artists (one list may name fewer, e.g. without the
/// featured artist) and a length within two seconds; synced lyrics win over plain ones.
enum LrcLibMatch {
    struct Candidate: Equatable {
        let title: String
        let artist: String
        let durationSeconds: Double?
        let lyrics: FetchedLyrics
    }

    static let durationToleranceSeconds: Double = 2

    static func best(
        among candidates: [Candidate],
        title: String,
        artists: [String],
        durationMilliseconds: Int
    ) -> Candidate? {
        guard durationMilliseconds > 0 else { return nil }
        let wantedTitle = normalizedTitle(title)
        let wantedArtists = artistSet(artists)
        guard !wantedTitle.isEmpty, !wantedArtists.isEmpty else { return nil }
        let wantedSeconds = Double(durationMilliseconds) / 1_000

        typealias Scored = (candidate: Candidate, kind: Int, exactArtists: Bool, gap: Double)
        let scored: [Scored] = candidates.compactMap { candidate in
            guard let seconds = candidate.durationSeconds else { return nil }
            let gap = abs(seconds - wantedSeconds)
            guard gap <= durationToleranceSeconds else { return nil }
            guard normalizedTitle(candidate.title) == wantedTitle else { return nil }
            let theirArtists = artistSet([candidate.artist])
            guard !theirArtists.isEmpty,
                  theirArtists.isSubset(of: wantedArtists) || wantedArtists.isSubset(of: theirArtists) else { return nil }
            return (candidate, kindRank(candidate.lyrics), theirArtists == wantedArtists, gap)
        }
        return scored.min { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            if lhs.exactArtists != rhs.exactArtists { return lhs.exactArtists }
            return lhs.gap < rhs.gap
        }?.candidate
    }

    /// The title sent to the search: without a "(feat. ...)" part, which LRCLIB often leaves out.
    static func searchTitle(_ title: String) -> String {
        title.replacingOccurrences(of: featuringPattern, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizedTitle(_ title: String) -> String {
        fold(searchTitle(title))
    }

    /// Each artist once, however the names are joined ("Tempo & El Alfa", "Tempo, El Alfa",
    /// "Tempo feat. El Alfa" and ["Tempo", "El Alfa"] are the same two artists).
    static func artistSet(_ names: [String]) -> Set<String> {
        var result = Set<String>()
        for name in names {
            let parts = fold(name).replacingOccurrences(
                of: artistSeparatorPattern,
                with: "\u{1F}",
                options: [.regularExpression, .caseInsensitive]
            )
            for part in parts.split(separator: "\u{1F}") {
                let artist = part.trimmingCharacters(in: .whitespaces)
                if !artist.isEmpty { result.insert(artist) }
            }
        }
        return result
    }

    private static let featuringPattern = #"\s*[\(\[](feat\.?|ft\.?|featuring|with)\s[^\)\]]*[\)\]]"#
    private static let artistSeparatorPattern = #"\s*(,|&|\+|•|·|;|/)\s*|\s+(feat\.?|ft\.?|featuring|with|and|y|e|et)\s+"#

    private static func kindRank(_ lyrics: FetchedLyrics) -> Int {
        switch lyrics {
        case .synced: return 0
        case .unsyncedPlain: return 1
        case .instrumental: return 2
        }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
