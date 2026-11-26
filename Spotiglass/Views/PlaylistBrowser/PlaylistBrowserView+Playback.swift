import SwiftUI

extension PlaylistBrowserView {
    /// The bar's Lyrics button and View › Show Lyrics (#486).
    var isLyricsPresentedBinding: Binding<Bool> {
        lyricsOverlay.presentedBinding
    }

    /// Only a space that plays its own music offers Play and Shuffle: the Apple Music space must
    /// not reach Spotify's player just because Spotify's space started it earlier (#373).
    var hasPlaybackDevice: Bool {
        playbackMode == .live && playbackDeviceID != nil
    }
}
