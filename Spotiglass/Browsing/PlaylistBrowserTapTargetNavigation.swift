import Foundation

/// Tap-target navigation helpers extracted from ``PlaylistBrowserView`` for unit testing.
enum PlaylistBrowserTapTargetNavigation {
    static func openArtist(
        _ target: ArtistTapTarget,
        origin: BrowserNavigationOrigin,
        selectArtist: @MainActor (String, BrowserNavigationOrigin, String?) async -> Void,
        resolveArtistID: (String) async throws -> String?,
        showFailure: @MainActor (LocalizedText) -> Void
    ) async {
        if let id = target.id {
            await selectArtist(id, origin, target.name)
            return
        }
        do {
            guard let resolvedID = try await resolveArtistID(target.name) else { return }
            await selectArtist(resolvedID, origin, target.name)
        } catch {
            await logFailure(error, opening: target.name, showFailure: showFailure)
        }
    }

    static func openAlbum(
        _ album: AlbumTapTarget,
        artistSubtitle: String,
        artworkURL: URL?,
        origin: BrowserNavigationOrigin,
        selectAlbum: @MainActor (String, String, String, URL?, BrowserNavigationOrigin) async -> Void,
        resolveAlbumID: (String, String) async throws -> String?,
        showFailure: @MainActor (LocalizedText) -> Void
    ) async {
        if let id = album.id {
            await selectAlbum(id, album.name, artistSubtitle, artworkURL, origin)
            return
        }
        do {
            guard let resolvedID = try await resolveAlbumID(album.name, artistSubtitle) else { return }
            await selectAlbum(resolvedID, album.name, artistSubtitle, artworkURL, origin)
        } catch {
            await logFailure(error, opening: album.name, showFailure: showFailure)
        }
    }

    /// A lookup that failed used to leave the tap doing nothing at all (#595): now it says so.
    /// A cancelled one (another tap, the window closing) stays quiet.
    private static func logFailure(
        _ error: Error,
        opening name: String,
        showFailure: @MainActor (LocalizedText) -> Void
    ) async {
        guard !(error is CancellationError), !Task.isCancelled else { return }
        SpotiglassLog.error(.browsing, "Looking up \"\(name)\" to open it failed: \(SpotiglassLog.describe(error))")
        await showFailure(LocalizedText(SpotiglassL10n.format("browser.tapTarget.openFailed", name)))
    }
}
