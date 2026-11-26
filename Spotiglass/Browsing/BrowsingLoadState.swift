import Foundation

/// Identifies a playlist the user follows but does not own, whose track listing
/// Spotify's Web API now refuses (HTTP 403). Carries just enough to still offer
/// playback and an "open in Spotify" fallback.
struct LockedPlaylistInfo: Equatable {
    let playlistID: String
    let name: String
    var contextURI: String { "spotify:playlist:\(playlistID)" }
    var externalURL: URL? { URL(string: "https://open.spotify.com/playlist/\(playlistID)") }
}

enum BrowsingLoadState<Value: Equatable>: Equatable {
    case loading
    case loaded(Value)
    /// The message is looked up when shown, so it follows a language switch (#548).
    case empty(LocalizedText)
    case staleCache(Value, DisplayError?)
    case refreshing(Value)
    case error(DisplayError)

    var currentValue: Value? {
        switch self {
        case let .loaded(value), let .staleCache(value, _), let .refreshing(value):
            value
        case .loading, .empty, .error:
            nil
        }
    }
}
