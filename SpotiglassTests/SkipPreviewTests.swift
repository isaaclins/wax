import XCTest
@testable import Spotiglass

/// Next and previous name the new song at once, before Spotify answers (#687).
@MainActor
final class SkipPreviewTests: XCTestCase {
    private static func song(_ id: String, position: Int = 0) -> PlaybackNowPlaying {
        PlaybackNowPlaying(
            name: "Song \(id)",
            artists: ["Artist"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: position,
            uri: "spotify:track:\(id)"
        )
    }

    private struct Fixture {
        let session: PlaybackSessionViewModel
        let api: MockPlaybackAPI
        let clock: ManualPlaybackClock
    }

    /// A session playing song B with A before it and C, D after it, as Spotify's page reports.
    private func makeSession() -> Fixture {
        let api = MockPlaybackAPI()
        let clock = ManualPlaybackClock()
        let session = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander()),
            clock: clock,
            skipCommandMinimumSpacing: .zero
        )
        session.handle(.ready(deviceID: "device-1"))
        session.handle(.stateChanged(
            Self.song("b", position: 40_000),
            isPaused: false,
            nextTracks: [Self.song("c"), Self.song("d")],
            previousTracks: [Self.song("a")]
        ))
        return Fixture(session: session, api: api, clock: clock)
    }

    private var shownURI: (PlaybackSessionViewModel) -> String? { { $0.currentNowPlaying?.uri } }

    // The real failure: the skip is on its way to Spotify (its request hasn't answered) and
    // Spotify's page still reports the old song. Before, the bar kept B the whole time.
    func testNextShowsTheNextSongBeforeSpotifyAnswersAndKeepsItThroughStaleReports() async {
        let fixture = makeSession()
        let started = AsyncSignal()
        let release = AsyncSignal()
        fixture.api.onNext = {
            started.signal()
            await release.wait()
        }

        let skip = Task { await fixture.session.next() }
        await started.wait()
        XCTAssertEqual(shownURI(fixture.session), "spotify:track:c")
        XCTAssertEqual(fixture.session.currentNowPlaying?.positionMilliseconds, 0)
        XCTAssertTrue(PlaylistBrowserPlaybackHelpers.isCurrentlyPlaying(connectionState: fixture.session.connectionState))

        // Spotify's page reports B again (its 4 s heartbeat, or a report sent before the skip).
        fixture.session.handle(.stateChanged(
            Self.song("b", position: 41_000),
            isPaused: false,
            nextTracks: [Self.song("c"), Self.song("d")],
            previousTracks: [Self.song("a")]
        ))
        XCTAssertEqual(shownURI(fixture.session), "spotify:track:c", "a report of the song the skip left must not put it back")

        release.signal()
        await skip.value
        // Spotify has it: its report settles the bar, position included.
        fixture.session.handle(.stateChanged(
            Self.song("c", position: 300),
            isPaused: false,
            nextTracks: [Self.song("d")],
            previousTracks: [Self.song("a"), Self.song("b")]
        ))
        XCTAssertEqual(shownURI(fixture.session), "spotify:track:c")
        XCTAssertEqual(fixture.session.currentNowPlaying?.positionMilliseconds, 300)
        XCTAssertNil(fixture.session.skipPreview)
        XCTAssertEqual(fixture.api.actions.filter { $0.hasPrefix("next:") }, ["next:device-1"])
    }

    func testPreviousShowsTheSongBeforeAtOnce() async {
        let fixture = makeSession()
        let started = AsyncSignal()
        let release = AsyncSignal()
        fixture.api.onPrevious = {
            started.signal()
            await release.wait()
        }

        let skip = Task { await fixture.session.previous() }
        await started.wait()
        XCTAssertEqual(shownURI(fixture.session), "spotify:track:a")
        release.signal()
        await skip.value
    }

    func testSpotifyGoingToAnotherSongWinsOverTheGuess() async {
        let fixture = makeSession()
        await fixture.session.next()
        XCTAssertEqual(shownURI(fixture.session), "spotify:track:c")

        // The queue changed meanwhile (another device added a song): Spotify plays X.
        fixture.session.handle(.stateChanged(Self.song("x"), isPaused: false, nextTracks: []))
        XCTAssertEqual(shownURI(fixture.session), "spotify:track:x")
        XCTAssertNil(fixture.session.skipPreview)
    }

    func testTwoNextsBeforeSpotifyAnswersGoTwoSongsOn() async {
        let fixture = makeSession()
        await fixture.session.next()
        fixture.session.clearPendingSkipCommand()
        await fixture.session.next()
        XCTAssertEqual(shownURI(fixture.session), "spotify:track:d")

        // Spotify reports the first skip: C is one the skips moved past, so D stays.
        fixture.session.handle(.stateChanged(Self.song("c"), isPaused: false, nextTracks: [Self.song("d")]))
        XCTAssertEqual(shownURI(fixture.session), "spotify:track:d")
        fixture.session.handle(.stateChanged(Self.song("d"), isPaused: false, nextTracks: []))
        XCTAssertEqual(shownURI(fixture.session), "spotify:track:d")
        XCTAssertNil(fixture.session.skipPreview)
    }

    func testAFailedSkipGoesBackToTheSongSpotifyHas() async {
        let fixture = makeSession()
        fixture.api.nextError = MusicPlaybackError(service: .spotify, reason: .server, detail: "503")

        await fixture.session.next()

        XCTAssertNil(fixture.session.skipPreview)
        XCTAssertEqual(fixture.session.failedCommand?.restoreState.nowPlayingURIForTests, "spotify:track:b")
    }

    func testWithoutAnAnswerTheBarShowsWhatSpotifyLastReported() async {
        let fixture = makeSession()
        await fixture.session.next()
        fixture.session.handle(.stateChanged(Self.song("b", position: 45_000), isPaused: false, nextTracks: []))
        XCTAssertEqual(shownURI(fixture.session), "spotify:track:c")

        let wait = fixture.session.skipPreviewTimeoutTask
        XCTAssertNotNil(wait)
        fixture.clock.advance(by: PlaybackSessionViewModel.skipPreviewTimeout)
        await wait?.value
        XCTAssertEqual(shownURI(fixture.session), "spotify:track:b", "after the wait the bar shows Spotify's own latest report")
        XCTAssertEqual(fixture.session.currentNowPlaying?.positionMilliseconds, 45_000)
    }

    func testNothingChangesWhenTheNextSongIsntKnown() async {
        let fixture = makeSession()
        fixture.session.handle(.stateChanged(Self.song("b"), isPaused: false, nextTracks: [], previousTracks: []))

        await fixture.session.next()

        XCTAssertEqual(shownURI(fixture.session), "spotify:track:b")
        XCTAssertNil(fixture.session.skipPreview)
        XCTAssertEqual(fixture.api.actions.filter { $0.hasPrefix("next:") }, ["next:device-1"])
    }

    func testBridgeReadsThePreviousSongs() throws {
        let event = try SpotifyPlaybackBridgeParser.parse([
            "name": "state_changed",
            "payload": [
                "paused": false,
                "track": ["name": "B", "artists": ["Artist"], "durationMilliseconds": 1000, "positionMilliseconds": 0, "uri": "spotify:track:b"],
                "nextTracks": [],
                "previousTracks": [
                    ["name": "A", "artists": ["Artist"], "durationMilliseconds": 1000, "positionMilliseconds": 0, "uri": "spotify:track:a"]
                ]
            ]
        ])
        guard case let .stateChanged(_, _, _, previousTracks) = event else {
            return XCTFail("expected state_changed")
        }
        XCTAssertEqual(previousTracks.map(\.uri), ["spotify:track:a"])
    }
}

private extension PlaybackConnectionState {
    var nowPlayingURIForTests: String? {
        switch self {
        case let .playing(song): song.uri
        case let .paused(song): song?.uri
        default: nil
        }
    }
}
