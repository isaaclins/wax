import XCTest
@testable import Spotiglass

@MainActor
final class PlaylistBrowserPlaybackHelpersTests: XCTestCase {
    func testLyricsPrefetchTrackOnlyWhenPlaying() {
        let np = PlaybackNowPlaying(
            name: "N", artists: ["A"], albumName: nil, albumID: nil, albumArtURL: nil,
            durationMilliseconds: 60_000, positionMilliseconds: 0, uri: "spotify:track:1"
        )
        XCTAssertEqual(
            PlaylistBrowserPlaybackHelpers.lyricsPrefetchTrack(connectionState: .playing(np)),
            np
        )
        XCTAssertNil(
            PlaylistBrowserPlaybackHelpers.lyricsPrefetchTrack(connectionState: .paused(np))
        )
        XCTAssertNil(
            PlaylistBrowserPlaybackHelpers.lyricsPrefetchTrack(connectionState: .disconnected)
        )
    }

    func testLyricsHalfwayNextPreloadTaskID() {
        let np = PlaybackNowPlaying(
            name: "N", artists: ["A"], albumName: nil, albumID: nil, albumArtURL: nil,
            durationMilliseconds: 120_000, positionMilliseconds: 0, uri: "spotify:track:abc"
        )
        XCTAssertEqual(
            PlaylistBrowserPlaybackHelpers.lyricsHalfwayNextPreloadTaskID(
                prefetchTrack: np,
                nextQueueURI: "spotify:track:next"
            ),
            "spotify:track:abc|120000|spotify:track:next"
        )
        XCTAssertEqual(
            PlaylistBrowserPlaybackHelpers.lyricsHalfwayNextPreloadTaskID(
                prefetchTrack: np,
                nextQueueURI: nil
            ),
            "spotify:track:abc|120000|"
        )
        XCTAssertNil(
            PlaylistBrowserPlaybackHelpers.lyricsHalfwayNextPreloadTaskID(
                prefetchTrack: PlaybackNowPlaying(
                    name: "N", artists: [], albumName: nil, albumID: nil, albumArtURL: nil,
                    durationMilliseconds: 0, positionMilliseconds: 0, uri: nil
                ),
                nextQueueURI: "x"
            )
        )
    }

    func testQueueRelevantPlaybackKeyAndCurrentURI() {
        let np = PlaybackNowPlaying(
            name: "N", artists: ["A"], albumName: nil, albumID: nil, albumArtURL: nil,
            durationMilliseconds: 1, positionMilliseconds: 0, uri: "spotify:track:u"
        )
        XCTAssertEqual(
            PlaylistBrowserPlaybackHelpers.queueRelevantPlaybackKey(connectionState: .playing(np)),
            "playing:spotify:track:u"
        )
        XCTAssertEqual(
            PlaylistBrowserPlaybackHelpers.currentPlaybackURI(connectionState: .playing(np)),
            "spotify:track:u"
        )
        XCTAssertEqual(
            PlaylistBrowserPlaybackHelpers.currentPlaybackURI(connectionState: .paused(np)),
            "spotify:track:u"
        )
        XCTAssertNil(
            PlaylistBrowserPlaybackHelpers.currentPlaybackURI(connectionState: .disconnected)
        )
        XCTAssertTrue(
            PlaylistBrowserPlaybackHelpers.isCurrentlyPlaying(connectionState: .playing(np))
        )
        XCTAssertFalse(
            PlaylistBrowserPlaybackHelpers.isCurrentlyPlaying(connectionState: .paused(np))
        )
    }
}
