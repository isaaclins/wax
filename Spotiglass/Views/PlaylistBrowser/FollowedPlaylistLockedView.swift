import AppKit
import SwiftUI

/// Shown when Spotify refuses to list the tracks of a followed (non-owned)
/// playlist with HTTP 403. The listing is gone, but the user can still play the
/// whole playlist in-app or open it in Spotify.
struct FollowedPlaylistLockedView: View {
    let error: DisplayError
    let info: LockedPlaylistInfo
    /// Only its Play button uses the session, so it doesn't observe it (#422).
    let playbackViewModel: PlaybackSessionViewModel

    var body: some View {
        ErrorPage(error: error, systemImage: "lock") {
            HStack(spacing: SpotiglassDesign.spacingM) {
                Button {
                    Task { await playbackViewModel.play(contextURI: info.contextURI) }
                } label: {
                    Label(SpotiglassL10n.string("browser.playPlaylist"), systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    guard let url = info.externalURL else { return }
                    NSWorkspace.shared.open(url)
                } label: {
                    Label(SpotiglassL10n.string("browser.openInSpotify"), systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
