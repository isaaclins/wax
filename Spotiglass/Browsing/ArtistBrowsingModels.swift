import Foundation

struct ArtistAlbumRowViewModel: Equatable, Identifiable {
    let id: String
    /// A nameless album's stand-in is looked up when shown, so it follows a switch (#548).
    private let titleText: LocalizedText
    var title: String { titleText.string }
    let artworkURL: URL?
    let yearText: String?
    /// Worked out when shown, so the row follows a language switch (#548).
    var trackCountText: String {
        SpotiglassL10n.format("browser.trackCount", Int64(totalTracks))
    }
    /// What the service reported, negative counts included, for ``trackCountText``.
    private let totalTracks: Int
    /// Kept as a number so nothing has to scrape digits off the localized
    /// ``trackCountText`` to recover it (#159).
    let totalTrackCount: Int
    let uri: String
    /// Shows the Explicit label songs carry (#580).
    let isExplicit: Bool

    init(_ album: MusicArtistAlbum) {
        id = album.id
        titleText = .musicName(album.name, kind: .album)
        artworkURL = album.imageURL
        yearText = album.releaseYear
        totalTrackCount = max(0, album.totalTracks)
        totalTracks = album.totalTracks
        uri = album.uri
        isExplicit = album.isExplicit
    }
}

struct ArtistDetailViewModel: Equatable {
    let artist: MusicArtistDetail
    let tracks: [TrackRowViewModel]
    let albums: [ArtistAlbumRowViewModel]
    let singles: [ArtistAlbumRowViewModel]
    let compilations: [ArtistAlbumRowViewModel]
    let appearsOn: [ArtistAlbumRowViewModel]
    let canLoadMoreAlbums: Bool
    let isLoadingMoreAlbums: Bool
    /// The "In your library" section: what the listener saved from the artist (#658). Empty
    /// when nothing is saved, and always on Spotify.
    let libraryTracks: [TrackRowViewModel]
    let libraryAlbums: [ArtistAlbumRowViewModel]
    /// What the page was built from, so a page of more albums keeps the section.
    let extras: MusicArtistPageExtras?

    /// `extras` come from a service that lists releases in the order to show them (Apple Music,
    /// newest first), so they keep that order; without them releases go by name, as before.
    init(
        artist: MusicArtistDetail,
        tracks: [MusicTrack],
        albums: [MusicArtistAlbum],
        canLoadMoreAlbums: Bool = false,
        isLoadingMoreAlbums: Bool = false,
        extras: MusicArtistPageExtras? = nil
    ) {
        self.artist = artist
        self.tracks = TrackRowViewModel.numberedTopTracks(tracks)
        let grouped = Dictionary(grouping: albums, by: \.group)
        let ordered: ([MusicArtistAlbum]) -> [ArtistAlbumRowViewModel] = { group in
            let sorted =
                extras != nil
                ? group
                : group.sorted { lhs, rhs in
                    lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
            return sorted.map(ArtistAlbumRowViewModel.init)
        }
        self.albums = ordered(grouped[.album] ?? [])
        self.singles = ordered(grouped[.single] ?? [])
        self.compilations = ordered(grouped[.compilation] ?? [])
        self.appearsOn = ordered(grouped[.appearsOn] ?? [])
        self.canLoadMoreAlbums = canLoadMoreAlbums
        self.isLoadingMoreAlbums = isLoadingMoreAlbums
        self.libraryTracks = TrackRowViewModel.numberedTopTracks(extras?.libraryTracks ?? [])
        self.libraryAlbums = (extras?.libraryAlbums ?? []).map(ArtistAlbumRowViewModel.init)
        self.extras = extras
    }

    var hasLibrarySection: Bool {
        !libraryTracks.isEmpty || !libraryAlbums.isEmpty
    }
}

extension ArtistAlbumRowViewModel {

    func spotifyArtistAlbum(group: MusicArtistAlbumGroup) -> MusicArtistAlbum {
        MusicArtistAlbum(
            id: id,
            name: title,
            imageURL: artworkURL,
            releaseYear: yearText,
            totalTracks: totalTrackCount,
            group: group,
            uri: uri,
            isExplicit: isExplicit
        )
    }

    func pinnedAlbum(group: MusicArtistAlbumGroup) -> PinnedItem {
        .album(spotifyArtistAlbum(group: group))
    }
}
