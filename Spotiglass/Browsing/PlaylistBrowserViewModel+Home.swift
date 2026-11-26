import Foundation

extension PlaylistBrowserViewModel {
    /// Quick-access tiles for the top of the home grid, derived synchronously from
    /// already-loaded library state (no extra network). Liked Songs is pinned first,
    /// followed by the user's playlists.
    var homeQuickAccessCards: [HomeMediaCard] {
        var cards: [HomeMediaCard] = [
            HomeMediaCard(
                id: SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID,
                title: SpotiglassL10n.string("browser.likedSongs.title"),
                subtitle: "",
                artworkURL: nil,
                destination: .likedSongs
            )
        ]
        cards.append(contentsOf: visiblePlaylists.prefix(11).map { playlist in
            HomeMediaCard(
                playlist: PlaylistBrowserLibraryActions.playlistSummaryFromRow(playlist),
                // The row keeps the owner it was loaded with; resolve it like the sidebar (#398).
                subtitle: playlist.localizedOwner()
            )
        })
        return cards
    }

    /// Time-of-day greeting shown in the home header. The hours after midnight get their
    /// own greeting: they are neither evening nor morning yet (#464).
    func homeGreeting(now: Date = Date(), calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: now)
        switch hour {
        case 0..<5:
            return SpotiglassL10n.string("home.greeting.night")
        case 5..<12:
            return SpotiglassL10n.string("home.greeting.morning")
        case 12..<18:
            return SpotiglassL10n.string("home.greeting.afternoon")
        default:
            return SpotiglassL10n.string("home.greeting.evening")
        }
    }

    /// Hours at which `homeGreeting` changes.
    nonisolated static let homeGreetingChangeHours = [0, 5, 12, 18]

    /// The next moment after `date` at which the home greeting changes, so a Home left on
    /// screen overnight can switch by itself (#464).
    nonisolated static func nextHomeGreetingChange(after date: Date, calendar: Calendar = .current) -> Date {
        homeGreetingChangeHours.compactMap { hour in
            calendar.nextDate(
                after: date,
                matching: DateComponents(hour: hour, minute: 0, second: 0),
                matchingPolicy: .nextTime
            )
        }.min() ?? date.addingTimeInterval(3600)
    }

    /// Entry point for showing the home surface: marks the detail column as Home and
    /// kicks off the independent section loads. Safe to call repeatedly (refresh).
    func loadHomeFeed(session: Int) async {
        guard session == detailSession else { return }
        detailState = .loaded(.home)
        await reloadHomeSections()
    }

    /// Reloads the network-backed home sections (recently played, top tracks)
    /// concurrently. Quick access is derived state and needs no reload here.
    func reloadHomeSections(forceRefresh: Bool = false) async {
        homeFeedGeneration += 1
        let generation = homeFeedGeneration
        let cacheMode: MusicRequestCacheMode = forceRefresh ? .bypassCache : .freshOnly
        homeRecentlyPlayed = .loading
        homeTopTracks = .loading
        homeTopTrackData = []
        async let recently: Void = loadHomeRecentlyPlayed(generation: generation, cacheMode: cacheMode)
        async let top: Void = loadHomeTopTracks(generation: generation, cacheMode: cacheMode)
        _ = await (recently, top)
    }

    private func loadHomeRecentlyPlayed(
        generation: Int,
        cacheMode: MusicRequestCacheMode
    ) async {
        do {
            let tracks = try await api.recentlyPlayedTracks(limit: 50, cacheMode: cacheMode)
            guard generation == homeFeedGeneration else { return }
            var seenAlbums: Set<String> = []
            let cards = tracks.compactMap { track -> HomeMediaCard? in
                guard let card = HomeMediaCard(recentlyPlayed: track) else { return nil }
                guard seenAlbums.insert(card.id).inserted else { return nil }
                return card
            }
            homeRecentlyPlayed = .loaded(cards)
        } catch is CancellationError {
            return
        } catch {
            guard generation == homeFeedGeneration else { return }
            homeRecentlyPlayed = Self.homeSectionState(for: error, while: "loading Home's recently played")
        }
    }

    private func loadHomeTopTracks(
        generation: Int,
        cacheMode: MusicRequestCacheMode
    ) async {
        do {
            let tracks = try await api.topTracks(
                limit: 20,
                timeRange: .shortTerm,
                cacheMode: cacheMode
            )
            guard generation == homeFeedGeneration else { return }
            homeTopTrackData = tracks
            invalidateLibraryContinuationCache()
            let rows = TrackRowViewModel.numberedTopTracks(tracks)
            homeTopTracks = .loaded(rows)
            // A refresh can drop selected songs. Keeping their ids left Add to Queue enabled in
            // the menu bar with nothing left to add (#173).
            if case .home = detailState.currentValue {
                let shown = Set(rows.map(\.id))
                if !selectedDetailTrackIDs.isSubset(of: shown) { selectedDetailTrackIDs.formIntersection(shown) }
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == homeFeedGeneration else { return }
            homeTopTracks = Self.homeSectionState(for: error, while: "loading Home's top tracks")
        }
    }

    /// Maps a section load failure to a terminal state. Missing-scope failures
    /// degrade to `.unavailable` (inline reconnect hint) rather than `.failed`,
    /// so accounts authorized before the home-feed scopes were added aren't
    /// shown a scary error.
    static func homeSectionState<Value>(for error: Error, while operation: String) -> HomeSectionState<Value> {
        if let apiError = error as? SpotifyAPIError {
            switch apiError {
            case .insufficientScope, .forbidden:
                // A sign-in from before the Home scopes: the section asks for a reconnect.
                SpotiglassLog.info(.browsing, "\(operation) needs a reconnect: \(SpotiglassLog.describe(error))")
                return .unavailable
            default:
                break
            }
        }
        var message = displayError(for: error)
        // A Home row has room for one sentence: Spotify's own, as before.
        if let apiError = error as? SpotifyAPIError {
            message.messageText = LocalizedText(apiError.userMessage)
        }
        return .failed(ErrorReporting.report(error, while: operation, in: .browsing, showing: message))
    }
}
