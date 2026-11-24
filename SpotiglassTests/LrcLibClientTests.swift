import XCTest

@testable import Spotiglass

private final class LRCLIBStubURLProtocol: URLProtocol {
    static var requestCount = 0
    static var requestedEndpoints: [String] = []
    static var responseByEndpoint: [String: (statusCode: Int, body: String)] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1" && (request.url?.path.contains("/api/") == true)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        let endpoint = request.url?.path.split(separator: "/").last.map(String.init) ?? "unknown"
        Self.requestedEndpoints.append(endpoint)
        let configured = Self.responseByEndpoint[endpoint]
            ?? (statusCode: 200, body: #"{"instrumental":false,"syncedLyrics":"[00:01.00]Test","plainLyrics":null}"#)
        let body = Data(configured.body.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: configured.statusCode, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Fails every LRCLIB request the way URLSession does offline: a `URLError` whose userInfo
/// carries the failing URL, query and all.
private final class LRCLIBOfflineURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1" && (request.url?.path.contains("/api/") == true)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let error = URLError(.notConnectedToInternet, userInfo: [
            NSURLErrorFailingURLErrorKey: url,
            NSURLErrorFailingURLStringErrorKey: url.absoluteString
        ])
        client?.urlProtocol(self, didFailWithError: error)
    }

    override func stopLoading() {}
}

/// Answers like LRCLIB did for the two songs in #657: `get-cached` has neither, `get` finds a
/// song only under LRCLIB's own title, artist and album (so "Las +593 - Single" misses), and
/// `search` returns the real results (lyrics cut to their first line).
private final class LRCLIBReplayURLProtocol: URLProtocol {
    struct Stored {
        let title: String
        let artist: String
        let album: String
        let body: String
    }

    static var requestedEndpoints: [String] = []
    static var stored: [Stored] = []
    static var searchBody = "[]"

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1" && (request.url?.path.contains("/api/") == true)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let endpoint = url.path.split(separator: "/").last.map(String.init) ?? "unknown"
        Self.requestedEndpoints.append(endpoint)
        let query = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        var status = 404
        var body = #"{"message":"Failed to find specified track","name":"TrackNotFound","statusCode":404}"#
        switch endpoint {
        case "get":
            if let hit = Self.stored.first(where: {
                $0.title == query["track_name"] && $0.artist == query["artist_name"] && $0.album == query["album_name"]
            }) {
                status = 200
                body = hit.body
            }
        case "search":
            status = 200
            body = Self.searchBody
        default:
            break
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class LrcLibClientTests: XCTestCase {
    override func tearDown() {
        LRCLIBStubURLProtocol.requestCount = 0
        LRCLIBStubURLProtocol.requestedEndpoints = []
        LRCLIBStubURLProtocol.responseByEndpoint = [:]
        LRCLIBReplayURLProtocol.requestedEndpoints = []
        LRCLIBReplayURLProtocol.stored = []
        LRCLIBReplayURLProtocol.searchBody = "[]"
        super.tearDown()
    }

    func testFetchLyricsUsesCachedEndpointOnlyWhenUsable() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LRCLIBStubURLProtocol.self] + (config.protocolClasses ?? [])
        let session = URLSession(configuration: config)
        // Use http + loopback so App Transport Security does not block the request before our URLProtocol runs.
        let base = URL(string: "http://127.0.0.1:1")!
        let client = LrcLibClient(session: session, baseURL: base)
        let track = PlaybackNowPlaying(
            name: "Song",
            artists: ["A"],
            albumName: "Album",
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: 0,
            uri: "spotify:track:abc123def456"
        )

        let lyrics: FetchedLyrics
        do {
            lyrics = try await client.fetchLyrics(for: track)
        } catch {
            return XCTFail("fetchLyrics threw: \(error)")
        }

        guard case let .synced(lines) = lyrics else {
            return XCTFail("expected synced lyrics, got \(lyrics)")
        }
        XCTAssertFalse(lines.isEmpty)
        XCTAssertEqual(LRCLIBStubURLProtocol.requestCount, 1)
        XCTAssertEqual(LRCLIBStubURLProtocol.requestedEndpoints, ["get-cached"])
    }

    func testFetchLyricsExpandsRepeatedTimestampsAndPreservesThemInDiskCache() async throws {
        LRCLIBStubURLProtocol.responseByEndpoint["get-cached"] = (
            statusCode: 200,
            body: #"{"instrumental":false,"syncedLyrics":"[00:10.00][00:20.00]Chorus\n[00:30.00]Next","plainLyrics":null}"#
        )
        let client = makeClient()
        let lyrics = try await client.fetchLyrics(for: sampleTrack())
        let expected: FetchedLyrics = .synced([
            SyncedLyricLine(id: 0, startTimeMs: 10_000, words: "Chorus"),
            SyncedLyricLine(id: 1, startTimeMs: 20_000, words: "Chorus"),
            SyncedLyricLine(id: 2, startTimeMs: 30_000, words: "Next")
        ])
        XCTAssertEqual(lyrics, expected)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpotiglassLyricsExpandedCache-\(UUID().uuidString)")
        let disk = try LyricsDiskCache(directory: directory)
        try disk.save(trackKey: "abc123def456", lyrics: lyrics)
        XCTAssertEqual(disk.load(trackKey: "abc123def456"), expected)
        try? FileManager.default.removeItem(at: directory)
    }

    func testFetchLyricsFallsBackToGetWhenGetCachedMissing() async throws {
        LRCLIBStubURLProtocol.responseByEndpoint["get-cached"] = (statusCode: 404, body: "")
        LRCLIBStubURLProtocol.responseByEndpoint["get"] = (
            statusCode: 200,
            body: #"{"instrumental":false,"syncedLyrics":"[00:01.00]Fallback","plainLyrics":null}"#
        )

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LRCLIBStubURLProtocol.self] + (config.protocolClasses ?? [])
        let session = URLSession(configuration: config)
        let base = URL(string: "http://127.0.0.1:1")!
        let client = LrcLibClient(session: session, baseURL: base)
        let track = PlaybackNowPlaying(
            name: "Song",
            artists: ["A"],
            albumName: "Album",
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: 0,
            uri: "spotify:track:abc123def456"
        )

        let lyrics = try await client.fetchLyrics(for: track)
        guard case let .synced(lines) = lyrics else {
            return XCTFail("expected synced lyrics fallback, got \(lyrics)")
        }
        XCTAssertEqual(lines.first?.words, "Fallback")
        XCTAssertEqual(LRCLIBStubURLProtocol.requestCount, 2)
        XCTAssertEqual(LRCLIBStubURLProtocol.requestedEndpoints, ["get-cached", "get"])
    }

    func testFetchLyricsFallsBackToGetWhenCachedDecodingFails() async throws {
        LRCLIBStubURLProtocol.responseByEndpoint["get-cached"] = (statusCode: 200, body: #"{"instrumental": "broken"}"#)
        LRCLIBStubURLProtocol.responseByEndpoint["get"] = (
            statusCode: 200,
            body: #"{"instrumental":false,"syncedLyrics":"[00:01.00]FromFull","plainLyrics":null}"#
        )

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LRCLIBStubURLProtocol.self] + (config.protocolClasses ?? [])
        let session = URLSession(configuration: config)
        let base = URL(string: "http://127.0.0.1:1")!
        let client = LrcLibClient(session: session, baseURL: base)
        let track = PlaybackNowPlaying(
            name: "Song",
            artists: ["A"],
            albumName: "Album",
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: 0,
            uri: "spotify:track:abc123def456"
        )

        let lyrics = try await client.fetchLyrics(for: track)
        guard case let .synced(lines) = lyrics else {
            return XCTFail("expected synced lyrics fallback, got \(lyrics)")
        }
        XCTAssertEqual(lines.first?.words, "FromFull")
        XCTAssertEqual(LRCLIBStubURLProtocol.requestedEndpoints, ["get-cached", "get"])
    }

    func testFetchLyricsRateLimitedCachedDoesNotEscalateToFullEndpoint() async {
        LRCLIBStubURLProtocol.responseByEndpoint["get-cached"] = (statusCode: 429, body: "")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LRCLIBStubURLProtocol.self] + (config.protocolClasses ?? [])
        let session = URLSession(configuration: config)
        let base = URL(string: "http://127.0.0.1:1")!
        let client = LrcLibClient(session: session, baseURL: base)
        let track = PlaybackNowPlaying(
            name: "Song",
            artists: ["A"],
            albumName: "Album",
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: 0,
            uri: "spotify:track:abc123def456"
        )

        do {
            _ = try await client.fetchLyrics(for: track)
            XCTFail("Expected rate-limited failure")
        } catch let failure as LrcLibClient.Failure {
            guard case .rateLimited = failure else {
                return XCTFail("Expected .rateLimited, got \(failure)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(LRCLIBStubURLProtocol.requestedEndpoints, ["get-cached"])
    }

    func testParallelFetchModeUsesBothEndpoints() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LRCLIBStubURLProtocol.self] + (config.protocolClasses ?? [])
        let session = URLSession(configuration: config)
        let base = URL(string: "http://127.0.0.1:1")!
        let client = LrcLibClient(session: session, baseURL: base, fetchMode: .parallel)
        let track = sampleTrack()

        let lyrics = try await client.fetchLyrics(for: track)
        guard case let .synced(lines) = lyrics else {
            return XCTFail("expected synced lyrics, got \(lyrics)")
        }
        XCTAssertFalse(lines.isEmpty)
        XCTAssertEqual(Set(LRCLIBStubURLProtocol.requestedEndpoints), Set(["get-cached", "get"]))
    }

    func testFetchLyricsInstrumentalAndPlain() async throws {
        LRCLIBStubURLProtocol.responseByEndpoint["get-cached"] = (
            statusCode: 200,
            body: #"{"instrumental":true,"syncedLyrics":null,"plainLyrics":null}"#
        )
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LRCLIBStubURLProtocol.self] + (config.protocolClasses ?? [])
        let client = LrcLibClient(session: session(configuration: config), baseURL: URL(string: "http://127.0.0.1:1")!)
        let instrumental = try await client.fetchLyrics(for: sampleTrack())
        XCTAssertEqual(instrumental, .instrumental)

        LRCLIBStubURLProtocol.responseByEndpoint = [
            "get-cached": (statusCode: 404, body: ""),
            "get": (statusCode: 200, body: #"{"instrumental":false,"syncedLyrics":null,"plainLyrics":"Line A\nLine B"}"#),
        ]
        let plain = try await client.fetchLyrics(for: sampleTrack())
        guard case let .unsyncedPlain(lines) = plain else {
            return XCTFail("expected plain lyrics")
        }
        XCTAssertEqual(lines, ["Line A", "Line B"])
    }

    func testFetchLyricsServerErrorOnCachedFallsBackToFull() async throws {
        LRCLIBStubURLProtocol.responseByEndpoint["get-cached"] = (statusCode: 503, body: "")
        LRCLIBStubURLProtocol.responseByEndpoint["get"] = (
            statusCode: 200,
            body: #"{"instrumental":false,"syncedLyrics":"[00:01.00]After503","plainLyrics":null}"#
        )
        let client = makeClient()
        let lyrics = try await client.fetchLyrics(for: sampleTrack())
        guard case let .synced(lines) = lyrics else {
            return XCTFail("expected synced fallback")
        }
        XCTAssertEqual(lines.first?.words, "After503")
    }

    func testNowPlayingLrcLibQueries() {
        let np = PlaybackNowPlaying(
            name: "Song",
            artists: ["A", "B"],
            albumName: "  Album  ",
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 500,
            positionMilliseconds: 0,
            uri: "spotify:track:track-id"
        )
        XCTAssertEqual(np.lrcLibArtistQuery, "A, B")
        XCTAssertEqual(np.lrcLibAlbumQuery, "Album")
        for (appleMusic, lrcLib) in [
            ("Las +593 - Single", "Las +593"), ("Happy Birthday - single", "Happy Birthday"),
            ("Night Moves - EP", "Night Moves"), ("Singles - Deluxe", "Singles - Deluxe"), ("EP", "EP")
        ] {
            let album = PlaybackNowPlaying(
                name: "Song", artists: ["A"], albumName: appleMusic, albumID: nil, albumArtURL: nil,
                durationMilliseconds: 1_000, positionMilliseconds: 0, uri: nil
            ).lrcLibAlbumQuery
            XCTAssertEqual(album, lrcLib, "Album \(appleMusic)")
        }
        XCTAssertEqual(np.lrcLibDurationSeconds, 1)
        XCTAssertEqual(np.lyricsTrackKey, "track-id")
        XCTAssertNil(
            PlaybackNowPlaying(
                name: "X", artists: [], albumName: nil, albumID: nil, albumArtURL: nil,
                durationMilliseconds: 1, positionMilliseconds: 0, uri: "not-spotify"
            ).lyricsTrackKey
        )
    }

    private func sampleTrack() -> PlaybackNowPlaying {
        PlaybackNowPlaying(
            name: "Song",
            artists: ["A"],
            albumName: "Album",
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: 0,
            uri: "spotify:track:abc123def456"
        )
    }

    /// Offline, `"\(error)"` printed the LRCLIB URL with the song, artist and album, though the
    /// log says it names the endpoint only (#602, #603).
    func testAnOfflineFetchLogsTheEndpointAndCodeButNotTheSong() async throws {
        let marker = "Song\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LRCLIBOfflineURLProtocol.self] + (config.protocolClasses ?? [])
        let client = LrcLibClient(session: URLSession(configuration: config), baseURL: URL(string: "http://127.0.0.1:1")!)
        let track = PlaybackNowPlaying(
            name: marker,
            artists: ["A"],
            albumName: "Album",
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: 0,
            uri: "spotify:track:abc123def456"
        )

        do {
            _ = try await client.fetchLyrics(for: track)
            XCTFail("An offline fetch must fail")
        } catch {}

        XCTAssertEqual(try SpotiglassLogReader.lines(containing: marker), [], "The song reached the log")
        XCTAssertFalse(
            try SpotiglassLogReader.lines(containing: "LRCLIB get-cached failed: URLError \(URLError.notConnectedToInternet.rawValue)").isEmpty,
            "The endpoint and the URLError code must be in the log"
        )
    }

    // MARK: - #657: songs LRCLIB has that the exact lookup missed

    private static let lasMas593Synced = #"{"instrumental":false,"plainLyrics":"¡Cómo no, cómo no, seguimos continuando!","syncedLyrics":"[00:01.09] ¡Cómo no, cómo no, seguimos continuando!"}"#

    private static let lasMas593Search = #"[{"id":34273917,"trackName":"Las +593","artistName":"Machaka","albumName":"Las +593","duration":164.0,"instrumental":false,"plainLyrics":"¡Cómo no, cómo no, seguimos continuando!","syncedLyrics":"[00:01.09] ¡Cómo no, cómo no, seguimos continuando!"}]"#

    /// The real `search?track_name=Happy Birthday&artist_name=Tempo & El Alfa` answer: the
    /// "Tempo & El Alfa" entry is a 3:40 upload, the 2:36 song is under other artist spellings.
    private static let happyBirthdaySearch = #"""
    [{"id":3136537,"trackName":"Happy Birthday","artistName":"Tempo, El Alfa","albumName":"Happy Birthday","duration":156.0,"instrumental":false,"plainLyrics":"Yo lo que ando es","syncedLyrics":"[00:01.19] Yo lo que ando es"},
     {"id":15776679,"trackName":"Happy Birthday","artistName":"Tempo • El Alfa","albumName":"Happy Birthday","duration":156.0,"instrumental":false,"plainLyrics":"Yo lo que ando es","syncedLyrics":"[00:01.19] Yo lo que ando es"},
     {"id":39315038,"trackName":"Happy Birthday","artistName":"Tempo & El Alfa","albumName":"Happy Birthday - Single","duration":220.0,"instrumental":false,"plainLyrics":"Wrong length","syncedLyrics":"[00:01.19]Wrong length"},
     {"id":3136536,"trackName":"Happy Birthday","artistName":"Tempo feat. El Alfa","albumName":"Happy Birthday - Single","duration":156.0,"instrumental":false,"plainLyrics":"Yo lo que ando es","syncedLyrics":"[00:01.19] Yo lo que ando es"},
     {"id":35200874,"trackName":"Happy Birthday","artistName":"Tempo et El Alfa","albumName":"Happy Birthday","duration":156.0,"instrumental":false,"plainLyrics":"Yo lo que ando e'","syncedLyrics":"[00:00.73] Yo lo que ando e'"}]
    """#

    private func makeReplayClient() -> LrcLibClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LRCLIBReplayURLProtocol.self] + (config.protocolClasses ?? [])
        return LrcLibClient(session: URLSession(configuration: config), baseURL: URL(string: "http://127.0.0.1:1")!)
    }

    private func appleMusicTrack(_ name: String, artist: String, album: String, durationMilliseconds: Int) -> PlaybackNowPlaying {
        PlaybackNowPlaying(
            name: name, artists: [artist], albumName: album, albumID: nil, albumArtURL: nil,
            durationMilliseconds: durationMilliseconds, positionMilliseconds: 0, uri: "applemusic:song:1234567890"
        )
    }

    func testASingleIsFoundUnderLRCLIBsAlbumNameWithoutTheSingleEnding() async throws {
        LRCLIBReplayURLProtocol.stored = [
            .init(title: "Las +593", artist: "Machaka", album: "Las +593", body: Self.lasMas593Synced)
        ]
        LRCLIBReplayURLProtocol.searchBody = Self.lasMas593Search
        let track = appleMusicTrack("Las +593", artist: "Machaka", album: "Las +593 - Single", durationMilliseconds: 164_000)

        let lyrics = try await makeReplayClient().fetchLyrics(for: track)

        guard case let .synced(lines) = lyrics else { return XCTFail("expected synced lyrics, got \(lyrics)") }
        XCTAssertEqual(lines.first?.words, "¡Cómo no, cómo no, seguimos continuando!")
        XCTAssertEqual(LRCLIBReplayURLProtocol.requestedEndpoints, ["get-cached", "get"])
    }

    func testASongTheExactLookupMissesIsFoundBySearchWithTheRightLength() async throws {
        // LRCLIB keeps the 2:36 song as "Tempo, El Alfa"; Apple Music names it "Tempo & El Alfa".
        LRCLIBReplayURLProtocol.stored = [
            .init(title: "Happy Birthday", artist: "Tempo, El Alfa", album: "Happy Birthday", body: "{}")
        ]
        LRCLIBReplayURLProtocol.searchBody = Self.happyBirthdaySearch
        let track = appleMusicTrack(
            "Happy Birthday", artist: "Tempo & El Alfa", album: "Happy Birthday - Single", durationMilliseconds: 156_480
        )

        let lyrics = try await makeReplayClient().fetchLyrics(for: track)

        guard case let .synced(lines) = lyrics else { return XCTFail("expected synced lyrics, got \(lyrics)") }
        XCTAssertEqual(lines.first?.words, "Yo lo que ando es", "The 3:40 upload's lyrics must not win")
        XCTAssertEqual(LRCLIBReplayURLProtocol.requestedEndpoints, ["get-cached", "get", "search"])
    }

    func testSearchResultsThatAreAnotherSongStillSayNoLyrics() async {
        LRCLIBReplayURLProtocol.searchBody = Self.happyBirthdaySearch
        let cases = [
            appleMusicTrack("Happy Birthday", artist: "Tempo & El Alfa", album: "Happy Birthday", durationMilliseconds: 190_000),
            appleMusicTrack("Happy Birthday", artist: "Stevie Wonder", album: "Hotter Than July", durationMilliseconds: 156_000),
            appleMusicTrack("Happy Birthday Remix", artist: "Tempo & El Alfa", album: "Happy Birthday", durationMilliseconds: 156_000)
        ]
        for track in cases {
            do {
                let lyrics = try await makeReplayClient().fetchLyrics(for: track)
                XCTFail("\(track.name) by \(track.artistText) (\(track.durationMilliseconds) ms) got another song's lyrics: \(lyrics)")
            } catch let failure as LrcLibClient.Failure {
                XCTAssertEqual(failure, .noLyrics)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSearchPrefersSyncedLyricsAndTheSameArtists() {
        let plain = LrcLibMatch.Candidate(title: "Song", artist: "A & B", durationSeconds: 180, lyrics: .unsyncedPlain(["plain"]))
        let syncedFewerArtists = LrcLibMatch.Candidate(
            title: "Song", artist: "A", durationSeconds: 181.5,
            lyrics: .synced([SyncedLyricLine(id: 0, startTimeMs: 0, words: "fewer")])
        )
        let syncedSameArtists = LrcLibMatch.Candidate(
            title: "song (feat. B)", artist: "A feat. B", durationSeconds: 181.9,
            lyrics: .synced([SyncedLyricLine(id: 0, startTimeMs: 0, words: "same")])
        )
        let best = LrcLibMatch.best(
            among: [plain, syncedFewerArtists, syncedSameArtists], title: "Song", artists: ["A", "B"], durationMilliseconds: 180_000
        )
        XCTAssertEqual(best, syncedSameArtists)
        XCTAssertEqual(
            LrcLibMatch.best(among: [plain], title: "Song", artists: ["A", "B"], durationMilliseconds: 180_000), plain,
            "Plain lyrics still count when nothing synced matches"
        )
        XCTAssertNil(
            LrcLibMatch.best(among: [plain], title: "Song", artists: ["C"], durationMilliseconds: 180_000),
            "Another artist's song never matches"
        )
    }

    private func makeClient() -> LrcLibClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LRCLIBStubURLProtocol.self] + (config.protocolClasses ?? [])
        return LrcLibClient(session: URLSession(configuration: config), baseURL: URL(string: "http://127.0.0.1:1")!)
    }

    private func session(configuration: URLSessionConfiguration) -> URLSession {
        URLSession(configuration: configuration)
    }
}
