import Foundation

extension PlaylistBrowserViewModel {
    func selectArtist(
        id: String,
        forceRefresh: Bool = false,
        origin: BrowserNavigationOrigin = .reset,
        displayName: String? = nil
    ) async {
        clearTrackSelection()
        registerNavigationTransition(to: .artist(id))
        rememberArtistNameForBack(displayName, artistID: id)
        applyBreadcrumbForArtist(
            id: id,
            displayName: displayName,
            origin: origin
        )
        let nowDate = now()
        detailLoadTask?.cancel()

        if !forceRefresh,
           let cached = cachedArtistSnapshots[id],
           nowDate.timeIntervalSince(cached.fetchedAt) < artistDetailCacheTTL {
            detailSession += 1
            currentArtistAlbumsPaging = cached.snapshot.paging
            let cachedVM = ArtistDetailViewModel(
                artist: cached.snapshot.artistDetail,
                tracks: cached.snapshot.tracks,
                albums: cached.snapshot.albums,
                canLoadMoreAlbums: cached.snapshot.paging?.nextURL != nil,
                isLoadingMoreAlbums: cached.snapshot.paging?.isLoading == true,
                extras: cached.snapshot.extras
            )
            ignoreNextNilSidebarSelectionForDetail = true
            sidebarSelection = nil
            detailState = .loaded(.artist(cachedVM))
            refineLastBreadcrumbArtistLabelIfNeeded(artistID: id, resolvedName: cached.snapshot.artistDetail.name)
            return
        }
        if let lastSelection = lastArtistSelectionAt[id],
           nowDate.timeIntervalSince(lastSelection) < artistSelectionDebounceWindow,
           artistDetailLoadTasks[id] != nil {
            artistFetchMetrics.coalescedRequests += 1
            return
        }
        lastArtistSelectionAt[id] = nowDate

        ignoreNextNilSidebarSelectionForDetail = true
        sidebarSelection = nil
        detailSession += 1
        currentArtistAlbumsPaging = nil
        let session = detailSession
        detailState = .loading
        do {
            let snapshot = try await loadArtistDetailSnapshot(id: id, preferCached: false)
            guard session == detailSession else { return }
            currentArtistAlbumsPaging = snapshot.paging
            if snapshot.usedStaleCache {
                artistFetchMetrics.staleResponsesServed += 1
                let staleVM = ArtistDetailViewModel(
                    artist: snapshot.artistDetail,
                    tracks: snapshot.tracks,
                    albums: snapshot.albums,
                    canLoadMoreAlbums: snapshot.paging?.nextURL != nil,
                    extras: snapshot.extras
                )
                detailState = .refreshing(.artist(staleVM))
                artistFetchMetrics.forcedRefreshRuns += 1
                let refreshed = try await loadArtistDetailSnapshot(id: id, preferCached: false)
                guard session == detailSession else { return }
                currentArtistAlbumsPaging = refreshed.paging
                let refreshedVM = ArtistDetailViewModel(
                    artist: refreshed.artistDetail,
                    tracks: refreshed.tracks,
                    albums: refreshed.albums,
                    canLoadMoreAlbums: refreshed.paging?.nextURL != nil,
                    extras: refreshed.extras
                )
                showArtistPage(refreshedVM, snapshot: refreshed, artistID: id)
                refineLastBreadcrumbArtistLabelIfNeeded(artistID: id, resolvedName: refreshed.artistDetail.name)
                return
            }
            guard session == detailSession else { return }
            let vm = ArtistDetailViewModel(
                artist: snapshot.artistDetail,
                tracks: snapshot.tracks,
                albums: snapshot.albums,
                canLoadMoreAlbums: snapshot.paging?.nextURL != nil,
                extras: snapshot.extras
            )
            showArtistPage(vm, snapshot: snapshot, artistID: id)
            refineLastBreadcrumbArtistLabelIfNeeded(artistID: id, resolvedName: snapshot.artistDetail.name)
        } catch is CancellationError {
            return
        } catch {
            guard session == detailSession else { return }
            detailState = .error(Self.reportedError(error, while: "loading the artist page", context: [.private("artist", id)]))
        }
    }

    /// A whole page is kept for next time; one with a part that didn't load shows the rest
    /// under a banner with Retry, and is asked again next time (#608).
    private func showArtistPage(_ page: ArtistDetailViewModel, snapshot: ArtistDetailSnapshot, artistID: String) {
        if let failure = snapshot.partialFailure {
            // Nothing else loaded either: the failure is the page, not "no songs, no releases".
            let isEmpty = snapshot.tracks.isEmpty && snapshot.albums.isEmpty
            let shown = Self.reportedError(
                failure,
                while: isEmpty ? "loading the artist page's songs (nothing else to show)" : "loading part of the artist page (shown without it)",
                context: [.private("artist", artistID)]
            )
            detailState = isEmpty ? .error(shown) : .staleCache(.artist(page), shown)
            return
        }
        cachedArtistSnapshots[artistID] = CachedArtistSnapshot(snapshot: snapshot, fetchedAt: now())
        detailState = .loaded(.artist(page))
    }
}
