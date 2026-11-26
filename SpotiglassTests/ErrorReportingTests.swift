import XCTest

@testable import Spotiglass

/// One path from a failure to the screen and the log (#608). Before it, the line a user saw and
/// the line in the log were written separately, so a playlist that failed to load, a failed
/// search and a failed Home section showed an error with nothing in the log at all.
@MainActor
final class ErrorReportingTests: XCTestCase {
    /// A failure whose log line can be found again: its description carries a marker.
    private struct ReplayedFailure: Error {
        let marker = "replayed-\(UUID().uuidString)"
    }

    func testAReportIsOneLineWithTheOperationTheErrorAndWhatWasShown() throws {
        let failure = ReplayedFailure()
        let shown = ErrorReporting.report(
            failure,
            while: "loading playlist songs",
            in: .browsing,
            context: [.public("status", 503), .private("playlist", "pl-42")],
            showing: ErrorMessage(title: "Couldn't load this", message: "Try again.", canRetry: true)
        )

        XCTAssertEqual(shown.title, "Couldn't load this")
        XCTAssertEqual(shown.message, "Try again.")
        XCTAssertTrue(shown.canRetry)
        let lines = try SpotiglassLogReader.lines(containing: failure.marker)
        XCTAssertEqual(lines.count, 1, "\(lines)")
        let line = try XCTUnwrap(lines.first)
        XCTAssertTrue(line.contains("[ERROR] [browsing] loading playlist songs failed: "), line)
        XCTAssertTrue(line.contains("shown \"Couldn't load this\" with retry"), line)
        XCTAssertTrue(line.contains("status=503"), line)
        // The file on the Mac keeps the private field, quoted as personal for the bug-report copy.
        XCTAssertTrue(line.contains("playlist=“pl-42”"), line)
    }

    /// #603: what a report marks private never reaches the copy of the log saved for a bug report.
    func testAPrivateFieldIsReplacedInTheBugReportCopy() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("report-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let failure = ReplayedFailure()
        ErrorReporting.report(
            failure,
            while: "looking up a name to open it",
            in: .browsing,
            context: [.public("status", 503), .private("name", "Tame Impala Deep Cuts")],
            showing: ErrorMessage(message: "Couldn't open it.")
        )
        let line = try XCTUnwrap(try SpotiglassLogReader.lines(containing: failure.marker).first)
        // The reported line, as a log folder of its own for the copy to clean.
        let sink = FileLogSink(directory: { directory })
        sink.boot()
        sink.write(level: "ERROR", category: "browsing", message: line, synchronously: true)
        sink.flush()
        let destination = directory.appendingPathComponent("report.txt")
        try BugReportLogCopy.write(from: directory, to: destination, keeping: [])
        let copy = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertFalse(copy.contains("Tame Impala"), copy)
        XCTAssertTrue(copy.contains("status=503"), copy)
    }

    func testAnExpectedFailureIsAnInfoLineAndContextSecretsAreHidden() throws {
        let marker = "expected-\(UUID().uuidString)"
        ErrorReporting.report(
            nil,
            while: "adding a song while rate limited \(marker)",
            in: .playback,
            context: [.public("url", "https://accounts.spotify.com/api/token?code=abc123&state=s")],
            level: .info,
            showing: ErrorMessage(message: "Wait a moment.")
        )
        let line = try XCTUnwrap(try SpotiglassLogReader.lines(containing: marker).first)
        XCTAssertTrue(line.contains("[INFO] [playback]"), line)
        XCTAssertFalse(line.contains("abc123"), line)
    }

    func testRewordingAReportedErrorDoesNotLogItAgain() throws {
        let failure = ReplayedFailure()
        let shown = ErrorReporting.report(
            failure, while: "connecting", in: .playback,
            showing: ErrorMessage(
                message: "Reconnect",
                action: .reconnect
            ))
        let reworded = shown.with {
            $0.action = nil
            $0.isMomentary = true
        }
        XCTAssertNil(reworded.action)
        XCTAssertTrue(reworded.isMomentary)
        XCTAssertEqual(try SpotiglassLogReader.lines(containing: failure.marker).count, 1)
    }

    // MARK: - The failures the audit found shown without a log line

    func testAPlaylistWhoseSongsFailIsShownAndLogged() async throws {
        let failure = ReplayedFailure()
        let owned = MusicPlaylistSummary(
            id: "mine", name: "My Mix", ownerID: "u", ownerName: "Me", imageURL: nil, trackCount: 1, snapshotID: "snap"
        )
        let api = MockBrowsingAPI(playlistResults: [.success([owned])], trackResults: ["mine": [.failure(failure)]])
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())

        await viewModel.load()
        await viewModel.selectPlaylist(id: "mine")

        guard case .error = viewModel.detailState else {
            return XCTFail("Expected the page error, got \(viewModel.detailState)")
        }
        let lines = try SpotiglassLogReader.lines(containing: failure.marker)
        XCTAssertEqual(lines.count, 1, "\(lines)")
        XCTAssertTrue(lines.first?.contains("loading playlist songs failed") == true, "\(lines)")
    }

    func testAFailedSearchIsShownAndLogged() async throws {
        let failure = ReplayedFailure()
        let viewModel = CatalogSearchViewModel()
        viewModel.searchProvider = { _, _, _ in throw failure }

        viewModel.query = "anything"
        viewModel.queryDidChange()
        await viewModel.waitForSearchCompletion()

        guard case .error = viewModel.state else { return XCTFail("Expected the search error, got \(viewModel.state)") }
        let lines = try SpotiglassLogReader.lines(containing: failure.marker)
        XCTAssertEqual(lines.count, 1, "\(lines)")
        XCTAssertTrue(lines.first?.contains("searching failed") == true, "\(lines)")
    }

    func testAFailedHomeSectionIsShownAndLogged() throws {
        let failure = ReplayedFailure()
        let state: HomeSectionState<[TrackRowViewModel]> = PlaylistBrowserViewModel.homeSectionState(
            for: failure,
            while: "loading Home's top tracks"
        )
        guard case .failed(let shown) = state else { return XCTFail("Expected a failed section, got \(state)") }
        XCTAssertFalse(shown.message.isEmpty)
        XCTAssertEqual(try SpotiglassLogReader.lines(containing: failure.marker).count, 1)
    }

    func testAQueueErrorWithoutAPlayerIsShownAndLogged() async throws {
        let operation = "using the queue without a player failed"
        let before = try SpotiglassLogReader.lines(containing: operation).count
        let api = MockPlaybackAPI()
        let playback = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()))
        let queue = QueueViewModel(provider: SpotifyPlaybackProvider(playbackAPI: api), playbackSession: playback)

        await queue.addToQueue(uri: "spotify:track:x")

        XCTAssertNotNil(queue.lastError)
        XCTAssertEqual(try SpotiglassLogReader.lines(containing: operation).count, before + 1)
    }

    func testAPlayerErrorIsShownInTheBarAndLoggedOnce() throws {
        let failure = ReplayedFailure()
        let session = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander())
        )
        session.showPlaybackError(
            failure, while: "moving playback to a device", PlaybackSessionViewModel.displayError(for: failure))

        guard case .error = session.connectionState else {
            return XCTFail("Expected an error, got \(session.connectionState)")
        }
        let lines = try SpotiglassLogReader.lines(containing: failure.marker)
        XCTAssertEqual(lines.count, 1, "\(lines)")
        XCTAssertTrue(lines.first?.contains("[playback] moving playback to a device failed") == true, "\(lines)")
    }
}
