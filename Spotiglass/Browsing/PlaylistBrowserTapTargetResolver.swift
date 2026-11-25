import Foundation

/// Resolves artist/album tap targets via the catalog search when IDs are missing.
enum PlaylistBrowserTapTargetResolver {
    static func resolveAlbumID(
        name: String,
        artistHint: String,
        search: (_ query: String, _ limit: Int) async throws -> MusicSearchResults
    ) async throws -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let escaped = trimmed.replacingOccurrences(of: "\"", with: "")
        let firstArtist = artistHint.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        let query: String
        if firstArtist.isEmpty {
            query = "album:\"\(escaped)\""
        } else {
            let artistEsc = firstArtist.replacingOccurrences(of: "\"", with: "")
            query = "album:\"\(escaped)\" artist:\"\(artistEsc)\""
        }
        let results = try await whatLoaded(search, query)
        guard !results.albums.isEmpty else { return nil }
        let normalizedQuery = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if let exact = results.albums.first(where: {
            $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == normalizedQuery
        }) {
            return exact.id
        }
        return results.albums.first?.id
    }

    /// The artist a credit's text names, for a tap target the service gave no ID (#637).
    ///
    /// Only an artist whose name matches exactly counts. The search for the whole credit comes
    /// first: an artist it lists whose full name is the credit (an artist can be called
    /// "Simon & Garfunkel") or a stretch of it between separators ("Bad Bunny" in
    /// "Bad Bunny & RaiNao", "Tyler, The Creator" in "Tyler, The Creator & Kali Uchis") wins, the
    /// one named first and then the longest. Only when it lists none is each single name searched
    /// on its own, in order. A search lists other artists too, so with no exact match this
    /// answers `nil` and nothing opens, instead of the first hit, who may not be on the song at all.
    /// The query is the name alone: Apple Music reads Spotify's `artist:"…"` filter as words.
    static func resolveArtistID(
        forName name: String,
        search: (_ query: String, _ limit: Int) async throws -> MusicSearchResults
    ) async throws -> String? {
        let candidates = creditNames(name)
        guard let whole = candidates.first else { return nil }
        let wholeResults = try await whatLoaded(search, whole)
        for run in creditRuns(whole).map(folded) {
            if let artist = wholeResults.artists.first(where: { folded($0.name) == run }) {
                return artist.id
            }
        }
        for candidate in candidates.dropFirst() {
            let results = try await whatLoaded(search, candidate)
            let wanted = folded(candidate)
            if let exact = results.artists.first(where: { folded($0.name) == wanted }) {
                return exact.id
            }
        }
        return nil
    }

    /// A search where one half failed still has the half that answered (#595): a saved artist
    /// opens while the catalog is offline, a catalog one while the library read fails.
    private static func whatLoaded(
        _ search: (_ query: String, _ limit: Int) async throws -> MusicSearchResults,
        _ query: String
    ) async throws -> MusicSearchResults {
        do {
            return try await search(query, 10)
        } catch let partial as MusicSearchPartialFailure {
            // The provider logged what failed; the lookup goes on with what answered.
            SpotiglassLog.debug(.browsing, "Name lookup uses the half of the search that answered")
            return partial.results
        }
    }

    /// The whole credit, then each single name in it, in order and without repeats.
    static func creditNames(_ credit: String) -> [String] {
        let pieces = creditPieces(credit)
        guard let first = pieces.first, let last = pieces.last else { return [] }
        let whole = String(credit[first.lowerBound..<last.upperBound])
        var seen = Set<String>()
        return ([whole] + pieces.map { String(credit[$0]) })
            .filter { seen.insert(folded($0)).inserted }
    }

    /// Every stretch of the credit from one name to a later one, with the separators between
    /// them kept as written: in the order they start, the longest first.
    static func creditRuns(_ credit: String) -> [String] {
        let pieces = creditPieces(credit)
        var runs: [String] = []
        for start in pieces.indices {
            for end in pieces.indices.reversed() where end >= start {
                runs.append(String(credit[pieces[start].lowerBound..<pieces[end].upperBound]))
            }
        }
        return runs
    }

    /// Where each name sits in the credit: the text between separators, without the spaces
    /// around it; empty ones are left out.
    private static func creditPieces(_ credit: String) -> [Range<String.Index>] {
        var pieces: [Range<String.Index>] = []
        var pieceStart = credit.startIndex
        var index = credit.startIndex
        func closePiece(at end: String.Index) {
            var lower = pieceStart
            var upper = end
            while lower < upper, credit[lower].isWhitespace { lower = credit.index(after: lower) }
            while lower < upper, credit[credit.index(before: upper)].isWhitespace { upper = credit.index(before: upper) }
            if lower < upper { pieces.append(lower..<upper) }
        }
        while index < credit.endIndex {
            if let separator = creditSeparators.first(where: { credit[index...].hasPrefix($0) }) {
                closePiece(at: index)
                index = credit.index(index, offsetBy: separator.count)
                pieceStart = index
            } else {
                index = credit.index(after: index)
            }
        }
        closePiece(at: credit.endIndex)
        return pieces
    }

    /// How services join several artists in one credit. Words like "and" are left out: they
    /// are part of many artists' own names.
    private static let creditSeparators = [
        ",", "&", " x ", " X ", " feat. ", " Feat. ", " ft. ", " Ft. ", " featuring ", " Featuring ", " with ", " / ",
    ]

    private static func folded(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
