import XCTest

@testable import Spotiglass

@MainActor
final class CommandPaletteViewModelSearchRefreshTests: XCTestCase {
    func testSingleCharacterQueryDoesNotInvokeSearchProvider() async {
        let viewModel = CommandPaletteViewModel()
        var callCount = 0
        viewModel.searchProvider = { _, _ in
            callCount += 1
            return CommandPaletteSearchResults()
        }
        viewModel.show()
        viewModel.query = "a"
        viewModel.refresh()
        await viewModel.waitForSearchCompletion()
        XCTAssertEqual(callCount, 0)
    }

    func testDuplicateRefreshSkipsSearchProviderWhenKeyUnchanged() async {
        let viewModel = CommandPaletteViewModel()
        var callCount = 0
        viewModel.searchProvider = { _, _ in
            callCount += 1
            return CommandPaletteSearchResults(
                tracks: [
                    CommandPaletteItem(
                        id: "track-1",
                        title: "Song",
                        subtitle: "Artist",
                        iconSystemName: "music.note",
                        section: .tracks,
                        keywords: []
                    ) {}
                ]
            )
        }
        viewModel.show()
        viewModel.query = "ab"
        viewModel.refresh()
        await viewModel.waitForSearchCompletion()
        XCTAssertEqual(callCount, 1)
        viewModel.refresh()
        await viewModel.waitForSearchCompletion()
        XCTAssertEqual(callCount, 1)
    }

    func testShorteningQueryBelowMinCharThenRestoringRefetches() async {
        let viewModel = CommandPaletteViewModel()
        var callCount = 0
        viewModel.searchProvider = { _, _ in
            callCount += 1
            return CommandPaletteSearchResults(
                tracks: [
                    CommandPaletteItem(
                        id: "track-1",
                        title: "Song",
                        subtitle: "Artist",
                        iconSystemName: "music.note",
                        section: .tracks,
                        keywords: []
                    ) {}
                ]
            )
        }
        viewModel.show()
        viewModel.query = "ab"
        viewModel.refresh()
        await viewModel.waitForSearchCompletion()
        XCTAssertEqual(callCount, 1)
        viewModel.query = "a"
        viewModel.refresh()
        await viewModel.waitForSearchCompletion()
        viewModel.query = "ab"
        viewModel.refresh()
        await viewModel.waitForSearchCompletion()
        XCTAssertEqual(callCount, 2)
    }

    func testRapidCategoryCyclesCoalesceToSingleSearchProviderCall() async {
        let viewModel = CommandPaletteViewModel()
        var callCount = 0
        viewModel.searchProvider = { _, _ in
            callCount += 1
            return CommandPaletteSearchResults()
        }
        viewModel.show()
        viewModel.setAvailableSearchCategories(
            CommandPaletteSearchCategory.footerOrder(includeThisPlaylist: false), refreshIfFilterInvalidated: false)
        viewModel.query = "abc"
        for _ in 0..<5 {
            viewModel.cycleSearchCategory(forward: true)
        }
        await viewModel.waitForSearchCompletion()
        XCTAssertEqual(callCount, 1)
    }

    func testRateLimitedSearchSetsCooldownAndSkipsFollowUpProviderCalls() async {
        let viewModel = CommandPaletteViewModel()
        var callCount = 0
        viewModel.searchProvider = { _, _ in
            callCount += 1
            throw SpotifyAPIError.rateLimited(retryAfter: 3)
        }
        viewModel.show()
        viewModel.query = "ab"
        viewModel.refresh()
        await viewModel.waitForSearchCompletion()
        XCTAssertEqual(callCount, 1)
        viewModel.searchProvider = { _, _ in
            callCount += 1
            return CommandPaletteSearchResults()
        }
        viewModel.refresh()
        await viewModel.waitForSearchCompletion()
        XCTAssertEqual(callCount, 1, "Palette should honor cooldown and not dispatch another search immediately")
        // The skipped search must still say why: a cleared line read as "No results" (#595).
        XCTAssertEqual(viewModel.error?.message, SpotifyAPIError.rateLimited(retryAfter: 3).userMessage)
    }

    func testLegacyAtPrefixSongSearchCallsProviderOnceForNormalizedQuery() async {
        let viewModel = CommandPaletteViewModel()
        var invocations: [String] = []
        viewModel.searchProvider = { query, _ in
            invocations.append(query)
            return CommandPaletteSearchResults()
        }
        viewModel.show()
        viewModel.query = "@m83"
        viewModel.refresh()
        await viewModel.waitForSearchCompletion()
        XCTAssertEqual(invocations, ["m83"])
    }

    func testLocalResultsRenderInstantlyBeforeCatalogProviderReturns() async {
        let viewModel = CommandPaletteViewModel()
        defer { viewModel.hide() }
        viewModel.localResultsProvider = { _ in
            CommandPaletteSearchResults(
                myPlaylists: [
                    CommandPaletteItem(
                        id: "playlist-local",
                        title: "Local Mix",
                        subtitle: nil,
                        iconSystemName: "music.note.list",
                        section: .myPlaylists,
                        keywords: []
                    ) {}
                ]
            )
        }
        var networkCalls = 0
        let releaseNetworkCall = AsyncSignal()
        viewModel.searchProvider = { _, _ in
            networkCalls += 1
            await releaseNetworkCall.wait()
            return CommandPaletteSearchResults()
        }
        viewModel.show()
        viewModel.searchCategoryFilter = .all
        viewModel.query = "local"
        viewModel.refresh()

        // refresh() paints local matches synchronously — before the debounce/network fires.
        XCTAssertEqual(viewModel.visibleItems.map(\.id), ["playlist-local"])
        XCTAssertEqual(networkCalls, 0)
        releaseNetworkCall.signal()
        await viewModel.waitForSearchCompletion()
    }

    func testSwitchingCategoryAfterSearchFiltersFromCacheWithoutRefetch() async {
        let viewModel = CommandPaletteViewModel()
        defer { viewModel.hide() }
        var networkCalls = 0
        viewModel.searchProvider = { _, _ in
            networkCalls += 1
            return CommandPaletteSearchResults(
                tracks: [
                    CommandPaletteItem(
                        id: "track-1",
                        title: "Midnight City",
                        subtitle: "M83",
                        iconSystemName: "music.note",
                        section: .tracks,
                        keywords: []
                    ) {}
                ],
                artists: [
                    CommandPaletteItem(
                        id: "artist-1",
                        title: "M83",
                        subtitle: "Artist",
                        iconSystemName: "person.wave.2",
                        section: .artists,
                        keywords: []
                    ) {}
                ]
            )
        }
        viewModel.setAvailableSearchCategories(
            CommandPaletteSearchCategory.footerOrder(includeThisPlaylist: false), refreshIfFilterInvalidated: false)
        viewModel.show()
        viewModel.searchCategoryFilter = .all
        viewModel.query = "midnight"
        viewModel.refresh()
        await viewModel.waitForSearchCompletion()
        XCTAssertEqual(networkCalls, 1)

        viewModel.selectCategory(.artists)
        XCTAssertEqual(networkCalls, 1, "Switching pills must re-filter the cache, not re-query")
        XCTAssertEqual(viewModel.sections.map(\.section), [.artists])
        XCTAssertEqual(viewModel.visibleItems.map(\.id), ["artist-1"])

        viewModel.selectCategory(.tracks)
        XCTAssertEqual(networkCalls, 1)
        XCTAssertEqual(viewModel.visibleItems.map(\.id), ["track-1"])
    }

    func testAllCategoryFloatsBestMatchingSectionFirst() async {
        let viewModel = CommandPaletteViewModel()
        defer { viewModel.hide() }
        viewModel.searchProvider = { _, _ in
            CommandPaletteSearchResults(
                tracks: [
                    CommandPaletteItem(
                        id: "track-1",
                        title: "Some Song",
                        subtitle: "Other Band",
                        iconSystemName: "music.note",
                        section: .tracks,
                        keywords: []
                    ) {}
                ],
                artists: [
                    CommandPaletteItem(
                        id: "artist-1",
                        title: "Kanye West",
                        subtitle: "Artist",
                        iconSystemName: "person.wave.2",
                        section: .artists,
                        keywords: []
                    ) {}
                ]
            )
        }
        viewModel.setAvailableSearchCategories(
            CommandPaletteSearchCategory.footerOrder(includeThisPlaylist: false), refreshIfFilterInvalidated: false)
        viewModel.show()
        viewModel.searchCategoryFilter = .all
        viewModel.query = "kanye"
        viewModel.refresh()
        await viewModel.waitForSearchCompletion()

        // "kanye" matches the artist (prefix) but not the track, so Artists floats above Tracks.
        XCTAssertEqual(viewModel.sections.map(\.section), [.artists, .tracks])
    }

    // MARK: - #595: a search that answered in part

    /// What loaded shows with a line for what didn't, and the same query asks again instead of
    /// keeping the partial answer as finished.
    func testAPartialSearchShowsWhatLoadedWithANoteAndAsksAgain() async {
        let viewModel = CommandPaletteViewModel()
        defer { viewModel.hide() }
        var callCount = 0
        let missing = MusicSearchPartialFailure(
            results: MusicSearchResults(tracks: [], artists: [], albums: [], playlists: []),
            missing: .catalog,
            underlying: URLError(.notConnectedToInternet)
        )
        viewModel.searchProvider = { _, _ in
            callCount += 1
            let loaded = CommandPaletteSearchResults(tracks: [
                CommandPaletteItem(
                    id: "track-saved", title: "Saved Song", subtitle: "Artist",
                    iconSystemName: "music.note", section: .tracks, keywords: []
                ) {}
            ])
            throw CommandPalettePartialSearchFailure(results: loaded, missing: missing)
        }
        viewModel.show()
        viewModel.query = "saved"
        viewModel.refresh()
        await viewModel.waitForSearchCompletion()

        XCTAssertEqual(viewModel.error?.message, ErrorMessage.partialSearch(missing).message)
        XCTAssertTrue(
            viewModel.sections.contains { $0.items.contains { $0.id == "track-saved" } },
            "the half that answered still shows"
        )

        viewModel.refresh()
        await viewModel.waitForSearchCompletion()
        XCTAssertEqual(callCount, 2, "a partial answer isn't kept as the finished search")
    }
    /// A pill switch after a partial answer asks again instead of filtering the partial rows.
    func testAPillSwitchAfterAPartialSearchAsksAgain() async {
        let viewModel = CommandPaletteViewModel()
        defer { viewModel.hide() }
        var callCount = 0
        viewModel.searchProvider = { _, _ in
            callCount += 1
            throw CommandPalettePartialSearchFailure(
                results: CommandPaletteSearchResults(),
                missing: MusicSearchPartialFailure(
                    results: MusicSearchResults(tracks: [], artists: [], albums: [], playlists: []),
                    missing: .catalog,
                    underlying: URLError(.notConnectedToInternet)
                )
            )
        }
        viewModel.show()
        viewModel.query = "saved"
        viewModel.refresh()
        await viewModel.waitForSearchCompletion()
        XCTAssertEqual(callCount, 1)

        viewModel.selectCategory(.artists)
        await viewModel.waitForSearchCompletion()
        XCTAssertEqual(callCount, 2)
    }

    /// A partial answer that arrives after a newer search started must not replace the newer
    /// rows or put its note over them. The order is forced: the old answer is held until the
    /// new search has finished.
    func testALatePartialAnswerDoesNotOverwriteANewerSearch() async {
        let viewModel = CommandPaletteViewModel()
        defer { viewModel.hide() }
        var releaseOld: CheckedContinuation<Void, Never>?
        let oldAsked = expectation(description: "old search reached the provider")
        let oldFinished = expectation(description: "old search finished handling its answer")
        viewModel.songSearchDidFinish = { query in
            if query == "old" { oldFinished.fulfill() }
        }
        viewModel.searchProvider = { query, _ in
            if query == "old" {
                await withCheckedContinuation { continuation in
                    releaseOld = continuation
                    oldAsked.fulfill()
                }
                throw CommandPalettePartialSearchFailure(
                    results: CommandPaletteSearchResults(tracks: [
                        CommandPaletteItem(
                            id: "track-old", title: "Old", subtitle: nil,
                            iconSystemName: "music.note", section: .tracks, keywords: []
                        ) {}
                    ]),
                    missing: MusicSearchPartialFailure(
                        results: MusicSearchResults(tracks: [], artists: [], albums: [], playlists: []),
                        missing: .catalog,
                        underlying: URLError(.notConnectedToInternet)
                    )
                )
            }
            return CommandPaletteSearchResults(tracks: [
                CommandPaletteItem(
                    id: "track-new", title: "New", subtitle: nil,
                    iconSystemName: "music.note", section: .tracks, keywords: []
                ) {}
            ])
        }
        viewModel.show()
        viewModel.query = "old"
        viewModel.refresh()
        await fulfillment(of: [oldAsked], timeout: 10)

        viewModel.query = "new"
        viewModel.refresh()
        await viewModel.waitForSearchCompletion()
        XCTAssertTrue(viewModel.sections.contains { $0.items.contains { $0.id == "track-new" } })

        releaseOld?.resume()
        await fulfillment(of: [oldFinished], timeout: 10)

        XCTAssertNil(viewModel.error?.message, "the old search's note landed on the new results")
        XCTAssertFalse(viewModel.sections.contains { $0.items.contains { $0.id == "track-old" } })
        XCTAssertTrue(viewModel.sections.contains { $0.items.contains { $0.id == "track-new" } })
    }

    /// A pill switch while the same query is being asked again only re-filters what is there:
    /// it doesn't cancel the running search and start another one.
    func testAPillSwitchWhileTheSameQueryReloadsDoesNotRestartIt() async {
        let viewModel = CommandPaletteViewModel()
        defer { viewModel.hide() }
        var callCount = 0
        var release: CheckedContinuation<Void, Never>?
        let reloadAsked = expectation(description: "the reload reached the provider")
        viewModel.searchProvider = { _, _ in
            callCount += 1
            if callCount == 2 {
                await withCheckedContinuation { continuation in
                    release = continuation
                    reloadAsked.fulfill()
                }
            }
            return CommandPaletteSearchResults(tracks: [
                CommandPaletteItem(
                    id: "track-1", title: "Song", subtitle: nil,
                    iconSystemName: "music.note", section: .tracks, keywords: []
                ) {}
            ])
        }
        viewModel.show()
        viewModel.query = "song"
        viewModel.refresh()
        await viewModel.waitForSearchCompletion()
        XCTAssertEqual(callCount, 1)

        // A language switch asks for the same query again.
        viewModel.languageDidChange()
        await fulfillment(of: [reloadAsked], timeout: 10)
        viewModel.selectCategory(.artists)
        release?.resume()
        await viewModel.waitForSearchCompletion()

        XCTAssertEqual(callCount, 2, "the pill switch restarted the running search")
    }
}
