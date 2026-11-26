import Foundation

/// Testable playback-derived values for playlist browser UI (scroll restore, lyrics prefetch, queue hooks).
enum PlaylistBrowserPlaybackHelpers {
    static func anchorTrackIDForPlaylistListScrollRestore(
        detailContent: BrowsingDetailContent?,
        currentPlaybackURI: String?,
        detailLastVisibleTrackID: String?
    ) -> String? {
        guard let content = detailContent else { return detailLastVisibleTrackID }
        switch content {
        case .playlist(let detail):
            if let uri = currentPlaybackURI,
                let row = detail.tracks.first(where: { $0.playableURI == uri })
            {
                return row.id
            }
        case .artist(let detail):
            if let uri = currentPlaybackURI,
                let row = detail.tracks.first(where: { $0.playableURI == uri })
            {
                return row.id
            }
        case .home, .search:
            break
        }
        return detailLastVisibleTrackID
    }

    static func lyricsPrefetchTrack(connectionState: PlaybackConnectionState) -> PlaybackNowPlaying? {
        switch connectionState {
        case .playing(let np):
            return np
        case .paused, .disconnected, .connecting, .ready, .transferring, .unavailable, .error:
            return nil
        }
    }

    static func lyricsHalfwayNextPreloadTaskID(
        prefetchTrack: PlaybackNowPlaying?,
        nextQueueURI: String?
    ) -> String? {
        guard let np = prefetchTrack,
            np.durationMilliseconds > 0,
            np.lyricsTrackKey != nil
        else { return nil }
        let nextURI = nextQueueURI ?? ""
        return "\(np.uri ?? "")|\(np.durationMilliseconds)|\(nextURI)"
    }

    static func queueRelevantPlaybackKey(connectionState: PlaybackConnectionState) -> String {
        switch connectionState {
        case .disconnected:
            "disconnected"
        case .connecting:
            "connecting"
        case .ready(let deviceID):
            "ready:\(deviceID)"
        case .transferring(let deviceID):
            "transferring:\(deviceID)"
        case .playing(let item):
            "playing:\(item.uri ?? "")"
        case .paused(.some(let item)):
            "paused:\(item.uri ?? "")"
        case .paused(.none):
            "paused-empty"
        case .unavailable(let message):
            "unavailable:\(message.string)"
        case .error(let error):
            "error:\(error.title)"
        }
    }

    /// The URI the rows of `detailContent` mark as playing (#396). Home and search hold their
    /// rows elsewhere and match them with ``rowURI(markedAs:connectionState:rows:)``.
    static func currentPlaybackURI(
        connectionState: PlaybackConnectionState,
        detailContent: BrowsingDetailContent?
    ) -> String? {
        let uri = currentPlaybackURI(connectionState: connectionState)
        switch detailContent {
        case .playlist(let detail)?: return rowURI(markedAs: uri, connectionState: connectionState, rows: detail.tracks)
        case .artist(let detail)?: return rowURI(markedAs: uri, connectionState: connectionState, rows: detail.tracks)
        case .home?, .search?, nil: return uri
        }
    }

    /// The URI `rows` mark as playing, given the playing URI (#396). Apple Music names one song
    /// by different ids depending on where it was read (a library `i.` id from search, the
    /// library's persistent id inside an album or playlist), and its player reports the id of
    /// the row the song was started from. So when no row of the list has that URI, a song
    /// started elsewhere is found by what the row shows: title, artists and length. Spotify's
    /// ids are the same everywhere, so its rows match by URI only.
    static func rowURI(
        markedAs uri: String?,
        connectionState: PlaybackConnectionState,
        rows: [TrackRowViewModel]
    ) -> String? {
        guard let uri, uri.hasPrefix(AppleMusicItemMapping.uriScheme + ":"),
            let nowPlaying = nowPlaying(connectionState: connectionState)
        else { return uri }
        guard !rows.contains(where: { $0.playableURI == uri }),
            let row = rows.first(where: { isSameSong($0, as: nowPlaying) })
        else { return uri }
        return row.playableURI
    }

    /// Same title, artists and length (within two seconds: one song's duration differs by a few
    /// milliseconds between the library and the catalog).
    static func isSameSong(_ row: TrackRowViewModel, as nowPlaying: PlaybackNowPlaying) -> Bool {
        // The length first: this runs for every row of the open list on each refresh of the bar,
        // and most rows differ in length, so the text compares rarely run.
        guard row.playableURI != nil,
            abs(row.durationMilliseconds - nowPlaying.durationMilliseconds) <= 2_000
        else { return false }
        return row.title.localizedCaseInsensitiveCompare(nowPlaying.name) == .orderedSame
            && row.subtitle.localizedCaseInsensitiveCompare(nowPlaying.artists.joined(separator: ", ")) == .orderedSame
    }

    private static func nowPlaying(connectionState: PlaybackConnectionState) -> PlaybackNowPlaying? {
        switch connectionState {
        case .playing(let nowPlaying): nowPlaying
        case .paused(let nowPlaying): nowPlaying
        case .disconnected, .connecting, .ready, .transferring, .unavailable, .error: nil
        }
    }

    static func currentPlaybackURI(connectionState: PlaybackConnectionState) -> String? {
        switch connectionState {
        case .playing(let nowPlaying):
            nowPlaying.uri
        case .paused(let nowPlaying):
            nowPlaying?.uri
        case .disconnected, .connecting, .ready, .transferring, .unavailable, .error:
            nil
        }
    }

    static func isCurrentlyPlaying(connectionState: PlaybackConnectionState) -> Bool {
        if case .playing = connectionState { return true }
        return false
    }
}
