import Foundation
import MusicKit
import os

/// The catalog copy of a saved artist or album, once found, by the ID the page was opened with.
/// Memory only and bounded: a page opened again doesn't look it up again, and the page's header,
/// releases and top songs, which ask at the same time, share one lookup.
final class AppleMusicCatalogMatches: @unchecked Sendable {
    /// The app's one set, which its providers are given: an album page's Play reads the match its
    /// page found (#658). Tests give each provider its own.
    static let shared = AppleMusicCatalogMatches()
    static let maxEntries = 500
    private let lock = NSLock()
    private var matches = LRUDictionary<String, String>(capacity: AppleMusicCatalogMatches.maxEntries)
    private var lookups: [String: Task<String?, Error>] = [:]

    func catalogID(for id: String) -> String? {
        lock.withLock { matches.value(forKey: id) }
    }

    /// The remembered match, else the one `find` gives, which a lookup already running for `id`
    /// gives every caller. A miss isn't remembered, so a later open looks again.
    func catalogID(for id: String, find: @escaping @Sendable () async throws -> String?) async throws -> String? {
        if let known = catalogID(for: id) { return known }
        let lookup: Task<String?, Error> = lock.withLock {
            if let running = lookups[id] { return running }
            let started = Task { try await find() }
            lookups[id] = started
            return started
        }
        let found: String?
        do {
            found = try await lookup.value
        } catch {
            finish(lookup, for: id, found: nil)
            throw error
        }
        finish(lookup, for: id, found: found)
        try Task.checkCancellation()
        return found
    }

    private func finish(_ lookup: Task<String?, Error>, for id: String, found: String?) {
        lock.withLock {
            if lookups[id] == lookup { lookups[id] = nil }
            if let found { matches.setValue(found, forKey: id) }
        }
    }
}

/// Artist and album pages show Apple Music's catalog, whichever way they were opened (#658).
///
/// A saved artist or album has a library ID, and its library copy holds only what was saved:
/// Tainy's page listed the two saved songs and "DATA" with 2 tracks. The page opens the catalog
/// copy instead, found from the saved copy; only when Apple Music has none does it show the
/// library's. What was saved shows in the artist page's own section (`artistPageExtras`) and as
/// a mark on the album page's songs.
extension AppleMusicBrowsingProvider {
    /// Saved songs a lookup reads to find a saved item's catalog copy.
    static let catalogMatchSongs = 5
    /// Saved albums an artist page's "In your library" section lists songs from.
    static let maxLibrarySectionAlbums = 20
    static let maxLibrarySectionTracks = 50

    // MARK: - Artists

    /// The artist a page shows: the catalog's when Apple Music has them, else the saved copy.
    func pageArtist(id: String) async throws -> Artist {
        if MusicKitLibraryLookup.isCatalogID(id) {
            do {
                if let catalog = try await source.artist(id: id) { return catalog }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The catalog didn't answer (offline): the saved copy, if there is one.
                if let saved = try await catalogItem({ try await source.libraryArtist(id: id) }) ?? nil { return saved }
                throw error
            }
            if let saved = try await source.libraryArtist(id: id) { return saved }
            throw AppleMusicBrowsingError.notFound
        }
        if let known = catalogMatches.catalogID(for: id),
           let catalog = try await catalogItem({ try await source.artist(id: known) }) ?? nil {
            return catalog
        }
        guard let saved = try await source.artist(id: id) else { throw AppleMusicBrowsingError.notFound }
        if let catalogID = try await catalogArtistID(of: saved, pageID: id),
           let catalog = try await catalogItem({ try await source.artist(id: catalogID) }) ?? nil {
            return catalog
        }
        return saved
    }

    /// The catalog ID of the artist a page was opened with, or `nil` when Apple Music has no
    /// catalog copy of a saved artist (an upload's artist, say).
    func catalogArtistID(forPageID id: String) async throws -> String? {
        if MusicKitLibraryLookup.isCatalogID(id) { return id }
        if let known = catalogMatches.catalogID(for: id) { return known }
        guard let saved = try await source.artist(id: id) else { return nil }
        return try await catalogArtistID(of: saved, pageID: id)
    }

    private func catalogArtistID(of saved: Artist, pageID: String) async throws -> String? {
        try await catalogMatches.catalogID(for: pageID) { try await catalogArtistID(of: saved) }
    }

    private func catalogArtistID(of saved: Artist) async throws -> String? {
        if let catalogID = Self.catalogID(of: saved) { return catalogID }
        // The catalog songs behind the artist's saved songs name the artist.
        let albums = try await source.albums(of: saved, limit: Self.catalogMatchSongs)
        var songIDs: [String] = []
        // Saved albums only, and one that can't be read is skipped: finding the match must never
        // cost the page more than the saved copy would.
        for album in albums where songIDs.count < Self.catalogMatchSongs && !MusicKitLibraryLookup.isCatalogID(album.id.rawValue) {
            // A saved album names its catalog album, whose songs are catalog songs; a saved
            // album's own songs, read through the album, name no catalog ID.
            if let catalogAlbumID = Self.catalogID(of: album),
               let catalogAlbum = try await catalogItem({ try await source.album(id: catalogAlbumID) }) ?? nil,
               let tracks = try await catalogItem({ try await source.tracks(of: catalogAlbum, limit: Self.catalogMatchSongs) }) {
                songIDs += Self.songCatalogIDs(tracks).filter { !songIDs.contains($0) }
                continue
            }
            guard let detailed = try await catalogItem({ try await source.album(id: album.id.rawValue) }) ?? nil,
                  let tracks = try await catalogItem({ try await source.tracks(of: detailed, limit: Self.catalogMatchSongs) })
            else { continue }
            songIDs += Self.songCatalogIDs(tracks).filter { !songIDs.contains($0) }
        }
        if !songIDs.isEmpty {
            let songs = try await catalogItem({ try await source.catalogSongs(ids: Array(songIDs.prefix(Self.catalogMatchSongs))) }) ?? []
            for song in songs {
                if let artist = song.artists?.first(where: { Self.sameName($0.name, saved.name) }) {
                    return artist.id.rawValue
                }
            }
        }
        // Nothing saved names it: the catalog artist of exactly that name, as search ranks them.
        let found = try await catalogItem({ try await source.catalogSearch(term: saved.name, limit: 10, offset: 0) })
        return found?.artists.first(where: { Self.sameName($0.name, saved.name) })?.id.rawValue
    }

    /// Never `nil` here: the page keeps Apple Music's newest-first release order also when a
    /// part can't be read, which then stays empty.
    func artistPageExtras(id: String) async throws -> MusicArtistPageExtras? {
        async let topTracks = catalogItem { try await artistPageTopTracks(id: id) }
        async let library = catalogItem { try await artistLibrarySection(id: id) }
        let (top, saved) = try await (topTracks, library)
        return MusicArtistPageExtras(
            topTracks: top ?? [],
            libraryTracks: saved?.0 ?? [],
            libraryAlbums: saved?.1 ?? []
        )
    }

    /// Apple Music's top songs of the artist, the page's Songs.
    private func artistPageTopTracks(id: String) async throws -> [MusicTrack] {
        guard let catalogID = try await catalogArtistID(forPageID: id) else { return [] }
        let songs = try await catalogItem({ try await source.artistTopSongs(artistID: catalogID) }) ?? []
        await lookUpRatings(songs)
        return songs.map(AppleMusicItemMapping.track)
    }

    /// The songs and albums saved from the artist, for the page's "In your library" section;
    /// empty when nothing is saved.
    private func artistLibrarySection(id: String) async throws -> ([MusicTrack], [MusicArtistAlbum]) {
        guard let saved = try await savedArtist(forPageID: id) else { return ([], []) }
        let albums = try await source.albums(of: saved, limit: Self.maxLibrarySectionAlbums)
        // The saved albums' songs, read a few albums at a time and kept in the albums' order.
        var songsByAlbum = [(album: Album, tracks: [Track])?](repeating: nil, count: albums.count)
        try await withThrowingTaskGroup(of: (Int, Album, [Track])?.self) { group in
            var next = 0
            func addNext() {
                guard next < albums.count else { return }
                let index = next
                next += 1
                group.addTask {
                    // One saved album that can't be read is left out, not the whole section.
                    guard let detailed = try await catalogItem({ try await source.album(id: albums[index].id.rawValue) }) ?? nil,
                          let tracks = try await catalogItem({ try await source.tracks(of: detailed, limit: Self.maxLibraryAlbumTracks) })
                    else { return nil }
                    editor.songReferences.remember(tracks)
                    return (index, detailed, tracks)
                }
            }
            for _ in 0..<Self.libraryAlbumCountParallelism { addNext() }
            while let read = try await group.next() {
                if let (index, album, tracks) = read { songsByAlbum[index] = (album, tracks) }
                addNext()
            }
        }
        // Only songs in the library: a saved album also lists songs that are only in a playlist
        // (#401), and an album with none of them isn't saved.
        var shown: [(track: Track, album: Album)] = []
        var seen: Set<String> = []
        var savedAlbumIDs: Set<String> = []
        for case let (album, albumTracks)? in songsByAlbum {
            let saved = Self.savedSongIDs(albumTracks, registry: editor.songReferences)
            if !saved.isEmpty { savedAlbumIDs.insert(album.id.rawValue) }
            for track in albumTracks where saved.contains(track.id.rawValue)
                && shown.count < Self.maxLibrarySectionTracks && seen.insert(track.id.rawValue).inserted {
                shown.append((track, album))
            }
        }
        // One ratings lookup for the songs shown, so the section waits for it once, not per album.
        await lookUpRatings(shown.map(\.track))
        let tracks = shown.map { AppleMusicItemMapping.track($0.track, album: $0.album) }
        let savedAlbums = albums.filter { savedAlbumIDs.contains($0.id.rawValue) }
        // A card gives the count its page shows (#400): the whole album for one that names its
        // catalog album, which its page opens, else the saved songs (an upload, say).
        let ratings = savedAlbums.isEmpty ? [:] : await savedAlbumRatings(savedAlbums).known
        let mapped = savedAlbums.map { AppleMusicItemMapping.artistAlbum($0, catalogExplicit: ratings[$0.id.rawValue]) }
        let withCatalogCopy = Set(savedAlbums.filter { Self.catalogID(of: $0) != nil }.map(\.id.rawValue))
        let counted = try await Self.libraryCounted(mapped.filter { !withCatalogCopy.contains($0.id) }, source: source)
        let countedByID = Dictionary(counted.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return (tracks, Self.newestFirst(mapped.map { countedByID[$0.id] ?? $0 }, dates: savedAlbums))
    }

    /// The saved copy of the artist a page was opened with, by either ID, else by name.
    private func savedArtist(forPageID id: String) async throws -> Artist? {
        if let saved = try await source.libraryArtist(id: id) { return saved }
        guard MusicKitLibraryLookup.isCatalogID(id),
              let catalog = try await catalogItem({ try await source.artist(id: id) }) ?? nil
        else { return nil }
        let found = try await source.librarySearch(term: catalog.name, limit: 10)
        guard let match = found.artists.first(where: { Self.sameName($0.name, catalog.name) }) else { return nil }
        return try await source.libraryArtist(id: match.id.rawValue)
    }

    // MARK: - Albums

    /// The album a page shows, the catalog's when Apple Music has it, and the saved copy of it
    /// when there is one, for the marks on its saved songs. `saved` is `nil` when the page shows
    /// the saved copy itself.
    func pageAlbum(id: String) async throws -> (album: Album, saved: Album?) {
        let saved: Album?
        let catalog: Album?
        if MusicKitLibraryLookup.isCatalogID(id) {
            // Both at once: every album opened from Home or search asks for its saved copy too.
            async let savedRead = catalogItem { try await source.libraryAlbum(id: id) }
            async let catalogRead = catalogItem { try await source.album(id: id) }
            let (savedResult, catalogResult) = try await (savedRead, catalogRead)
            saved = savedResult ?? nil
            catalog = catalogResult ?? nil
        } else {
            saved = try await source.album(id: id)
            let catalogID = try await saved.asyncFlatMap { try await catalogAlbumID(of: $0, pageID: id) }
            catalog = try await catalogID.asyncFlatMap { catalogID in
                try await catalogItem { try await source.album(id: catalogID) } ?? nil
            }
        }
        if let catalog { return (catalog, saved) }
        if let saved { return (saved, nil) }
        throw AppleMusicBrowsingError.notFound
    }

    /// The songs of a saved album, for the marks on the catalog album's page; none when it
    /// can't be read, which only leaves the marks off.
    func savedSongs(of saved: Album?) async throws -> [Track] {
        guard let saved else { return [] }
        return try await catalogItem { try await source.tracks(of: saved, limit: Self.maxLibraryAlbumTracks) } ?? []
    }

    /// The catalog album's songs that are saved, by their catalog ID. Each one's saved row is
    /// remembered under that ID too, so the song's menu offers Remove at once and the removal
    /// finds the saved copy. A song of the saved album that is only in a playlist isn't in the
    /// library (#401) and gets no mark.
    func savedCatalogSongIDs(_ catalogTracks: [Track], saved savedTracks: [Track]) -> Set<String> {
        editor.songReferences.remember(savedTracks)
        var ids: Set<String> = []
        for case let .song(savedSong) in savedTracks {
            guard let match = Self.catalogTrack(matching: savedSong, in: catalogTracks) else { continue }
            let reference = editor.songReferences.reference(for: savedSong.id.rawValue)
            if let reference { editor.songReferences.remember(reference.listed(as: match.id.rawValue)) }
            if reference?.isInLibrary ?? true { ids.insert(match.id.rawValue) }
        }
        return ids
    }

    /// The songs of a saved album the page shows itself that are in the library; one that is
    /// only in a playlist isn't (#401).
    static func savedSongIDs(_ tracks: [Track], registry: AppleMusicSongReferenceRegistry) -> Set<String> {
        Set(tracks.map(\.id.rawValue).filter { registry.reference(for: $0)?.isInLibrary ?? true })
    }

    /// A saved album's song read through the album names no catalog ID (only its persistent ID),
    /// so it matches its catalog song by title, and by disc and track number when the album has
    /// several songs of that title.
    static func catalogTrack(matching saved: Song, in catalogTracks: [Track]) -> Track? {
        if let catalogID = songCatalogIDs([.song(saved)]).first,
           let match = catalogTracks.first(where: { $0.id.rawValue == catalogID }) {
            return match
        }
        let sameTitle = catalogTracks.filter { sameName($0.title, saved.title) }
        guard sameTitle.count > 1 else { return sameTitle.first }
        return sameTitle.first { $0.discNumber == saved.discNumber && $0.trackNumber == saved.trackNumber }
    }

    private func catalogAlbumID(of saved: Album, pageID: String) async throws -> String? {
        try await catalogMatches.catalogID(for: pageID) { try await findCatalogAlbumID(of: saved) }
    }

    private func findCatalogAlbumID(of saved: Album) async throws -> String? {
        if let catalogID = Self.catalogID(of: saved) { return catalogID }
        let tracks = try await source.tracks(of: saved, limit: Self.catalogMatchSongs)
        let songIDs = Self.songCatalogIDs(tracks)
        if !songIDs.isEmpty {
            let songs = try await catalogItem({ try await source.catalogSongs(ids: songIDs) }) ?? []
            for song in songs {
                if let album = song.albums?.first(where: { Self.sameName($0.title, saved.title) }) {
                    return album.id.rawValue
                }
            }
        }
        let found = try await catalogItem({ try await source.catalogSearch(term: "\(saved.title) \(saved.artistName)", limit: 10, offset: 0) })
        return found?.albums.first(where: {
            Self.sameName($0.title, saved.title) && Self.sameName($0.artistName, saved.artistName)
        })?.id.rawValue
    }

    // MARK: - Helpers

    /// A read for finding or showing the catalog copy that failed for a reason other than
    /// cancelling: the page falls back to the saved copy rather than failing.
    private func catalogItem<T>(_ read: () async throws -> T) async throws -> T? {
        do {
            return try await read()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            SpotiglassLog.info(.api, "Apple Music read for a page's catalog copy failed (\(MusicKitContentSource.describe(error))); the page shows the saved copy")
            return nil
        }
    }

    /// The catalog ID a saved item names, when MusicKit gives one.
    static func catalogID<Item: MusicItem & Encodable>(of item: Item) -> String? {
        guard let catalogID = AppleMusicSongIdentity(encoding: item).catalogID,
              catalogID != item.id.rawValue, MusicKitLibraryLookup.isCatalogID(catalogID)
        else { return nil }
        return catalogID
    }

    /// The catalog IDs saved songs name.
    static func songCatalogIDs(_ tracks: [Track]) -> [String] {
        tracks.compactMap { track -> String? in
            guard case let .song(song) = track else { return nil }
            if MusicKitLibraryLookup.isCatalogID(song.id.rawValue) { return song.id.rawValue }
            return catalogID(of: song)
        }
    }

    static func sameName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame
    }

    /// Releases newest first, as Apple Music lists them; the same day keeps the service's order.
    static func newestFirst(_ mapped: [MusicArtistAlbum], dates albums: [Album]) -> [MusicArtistAlbum] {
        let dates = Dictionary(albums.map { ($0.id.rawValue, $0.releaseDate ?? .distantPast) }, uniquingKeysWith: { first, _ in first })
        return mapped.enumerated().sorted { lhs, rhs in
            let left = dates[lhs.element.id] ?? .distantPast
            let right = dates[rhs.element.id] ?? .distantPast
            return left != right ? left > right : lhs.offset < rhs.offset
        }.map(\.element)
    }
}

private extension Optional {
    func asyncFlatMap<T>(_ transform: (Wrapped) async throws -> T?) async rethrows -> T? {
        guard let self else { return nil }
        return try await transform(self)
    }
}
