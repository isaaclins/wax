import Foundation

extension PlaylistBrowserViewModel {
    func loadArtistDetailSnapshot(id: String, preferCached: Bool) async throws -> ArtistDetailSnapshot {
        if let inFlight = artistDetailLoadTasks[id] {
            artistFetchMetrics.coalescedRequests += 1
            return try await inFlight.value
        }
        artistFetchMetrics.requestStarts += 1
        let task = Task { [api] in
            // Asked next to the releases; a page without them still opens.
            async let extrasRead = Self.artistPageExtras(api: api, id: id)
            // The country is only a hint for the artist's top tracks: without it the page still
            // loads, instead of failing on a profile lookup it barely needs (#595).
            let market: String?
            do {
                market = try await api.currentUserProfile().country
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                SpotiglassLog.error(.browsing, "Profile didn't load for the artist page: \(SpotiglassLog.describe(error))")
                market = nil
            }
            if preferCached {
                async let cachedDetail = api.artistCached(id: id, cacheMode: .allowStale)
                async let cachedAlbums = api.artistAlbumsCached(
                    id: id,
                    includeGroups: [.album, .single, .compilation],
                    limit: 10,
                    cacheMode: .allowStale
                )
                let (detailHit, albumsHit) = try await (cachedDetail, cachedAlbums)
                let extras = try await extrasRead
                let tracks = try await self.artistPageTracks(
                    extras: extras,
                    artistId: id,
                    artist: detailHit.value,
                    albums: albumsHit.value,
                    market: market
                )
                return ArtistDetailSnapshot(
                    artistDetail: detailHit.value,
                    albums: albumsHit.value,
                    tracks: tracks,
                    usedStaleCache: detailHit.isStale || albumsHit.isStale,
                    paging: nil,
                    extras: extras
                )
            }
            let artistDetail = try await api.artist(id: id, cacheMode: .bypassCache)
            let includeGroups: [MusicArtistAlbumGroup] = [.album, .single, .compilation]
            let limit = 10
            var nextURL: URL?
            var nextOffset = 0
            var pagesFetched = 0
            var seenNextURLs: Set<String> = []
            var albumList: [MusicArtistAlbum] = []
            repeat {
                if let url = nextURL {
                    let key = url.absoluteString
                    if seenNextURLs.contains(key) {
                        // A broken response, not the end of the list: the albums read so far
                        // still show, and the loop is logged (#595).
                        SpotiglassLog.error(.browsing, "Artist albums linked back to a page already read; showing what loaded")
                        break
                    }
                    seenNextURLs.insert(key)
                }
                let page = try await api.artistAlbumsPage(
                    id: id,
                    includeGroups: includeGroups,
                    limit: limit,
                    offset: nextOffset,
                    nextURL: nextURL,
                    cacheMode: .bypassCache
                )
                albumList = Self.dedupeAlbums(albumList + page.items)
                pagesFetched += 1
                nextOffset += limit
                nextURL = page.next
            } while nextURL != nil && pagesFetched < self.initialArtistAlbumPageCount
            let extras = try await extrasRead
            let resolved = try await self.artistPageTracks(
                extras: extras,
                artistId: id,
                artist: artistDetail,
                albums: albumList,
                market: market
            )
            let paging = ArtistAlbumsPagingState(
                artistID: id,
                includeGroups: includeGroups,
                limit: limit,
                nextURL: nextURL,
                nextOffset: nextOffset,
                albums: albumList,
                tracks: resolved,
                isLoading: false,
                seenNextURLs: seenNextURLs
            )
            return ArtistDetailSnapshot(
                artistDetail: artistDetail,
                albums: albumList,
                tracks: resolved,
                usedStaleCache: false,
                paging: paging,
                extras: extras
            )
        }
        artistDetailLoadTasks[id] = task
        defer { artistDetailLoadTasks[id] = nil }
        return try await task.value
    }

    /// The service's top songs when it gave them, else songs found through search or the albums.
    /// With extras (Apple Music) those songs are a stand-in, so failing to find them leaves the
    /// page without songs rather than failing it; Spotify's page fails as before.
    private func artistPageTracks(
        extras: MusicArtistPageExtras?,
        artistId: String,
        artist: MusicArtistDetail,
        albums: [MusicArtistAlbum],
        market: String?
    ) async throws -> [MusicTrack] {
        guard let extras else {
            return try await resolveArtistTracks(artistId: artistId, artist: artist, albums: albums, market: market)
        }
        if !extras.topTracks.isEmpty { return extras.topTracks }
        do {
            return try await resolveArtistTracks(artistId: artistId, artist: artist, albums: albums, market: market)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            SpotiglassLog.info(.api, "Artist page songs failed (\(SpotiglassLog.describe(error))); the page shows without them")
            return []
        }
    }

    /// A failed read leaves the page without top songs and saved items rather than failing it.
    private nonisolated static func artistPageExtras(api: MusicBrowsingProvider, id: String) async throws -> MusicArtistPageExtras? {
        do {
            return try await api.artistPageExtras(id: id)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            SpotiglassLog.info(.api, "Artist page extras failed (\(SpotiglassLog.describe(error))); the page shows without them")
            return nil
        }
    }

    static func dedupeAlbums(_ albums: [MusicArtistAlbum]) -> [MusicArtistAlbum] {
        var deduped: [MusicArtistAlbum] = []
        var seenIDs: Set<String> = []
        deduped.reserveCapacity(albums.count)
        for album in albums {
            guard !seenIDs.contains(album.id) else { continue }
            seenIDs.insert(album.id)
            deduped.append(album)
        }
        return deduped
    }
}
