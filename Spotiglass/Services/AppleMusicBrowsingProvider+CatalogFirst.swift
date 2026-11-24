import Foundation
import MusicKit
import os

/// The catalog copy of a saved artist or album, once found, by the ID the page was opened with.
/// Memory only and bounded: a page opened again doesn't look it up again, and the page's header,
/// releases and top songs, which ask at the same time, share one lookup.
final class AppleMusicCatalogMatches: @unchecked Sendable {
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
        var tracks: [MusicTrack] = []
        var seen: Set<String> = []
        for album in albums where tracks.count < Self.maxLibrarySectionTracks {
            try Task.checkCancellation()
            guard let detailed = try await source.album(id: album.id.rawValue) else { continue }
            let albumTracks = try await source.tracks(of: detailed, limit: Self.maxLibraryAlbumTracks)
            editor.songReferences.remember(albumTracks)
            await lookUpRatings(albumTracks)
            for track in albumTracks where tracks.count < Self.maxLibrarySectionTracks && seen.insert(track.id.rawValue).inserted {
                tracks.append(AppleMusicItemMapping.track(track, album: detailed))
            }
        }
        let ratings = albums.isEmpty ? [:] : await savedAlbumRatings(albums).known
        let mapped = try await Self.libraryCounted(
            albums.map { AppleMusicItemMapping.artistAlbum($0, catalogExplicit: ratings[$0.id.rawValue]) },
            source: source
        )
        return (tracks, Self.newestFirst(mapped, dates: albums))
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

    /// The album a page shows, the catalog's when Apple Music has it, and the catalog IDs of its
    /// songs that are saved, for their mark.
    func pageAlbum(id: String) async throws -> (album: Album, savedSongIDs: Set<String>) {
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
        if let catalog {
            let savedTracks = try await saved.asyncMap { try await source.tracks(of: $0, limit: Self.maxLibraryAlbumTracks) } ?? []
            editor.songReferences.remember(savedTracks)
            return (catalog, Set(Self.songCatalogIDs(savedTracks)))
        }
        if let saved { return (saved, []) }
        throw AppleMusicBrowsingError.notFound
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
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let self else { return nil }
        return try await transform(self)
    }

    func asyncFlatMap<T>(_ transform: (Wrapped) async throws -> T?) async rethrows -> T? {
        guard let self else { return nil }
        return try await transform(self)
    }
}
