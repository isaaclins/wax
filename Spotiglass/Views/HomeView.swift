import Combine
import SwiftUI

/// Top-level Home surface: a time-of-day greeting, a quick-access grid (Liked
/// Songs + playlists), a Recently Played carousel, and a Your Top Tracks list.
/// Sections load independently; quick access is derived from already-loaded
/// library state so it appears instantly.
struct HomeView: View {
    @ObservedObject var viewModel: PlaylistBrowserViewModel
    /// Not observed: only the actions use them, and each track row reads by itself whether it is
    /// the playing one. Observing them re-rendered this view and every row on each play/pause
    /// and each new track (#422).
    let playbackViewModel: PlaybackSessionViewModel
    let queueViewModel: QueueViewModel

    let hasPlaybackDevice: Bool
    /// Shared playlist-creation prompt supplied by the browser detail host.
    let onRequestCreatePlaylist: (([TrackRowViewModel]) -> Void)?
    /// Shared continuation action supplied by the browser host.
    let onRequestLibraryContinuation: ((TrackRowViewModel) -> Void)?

    private let quickAccessColumns = [
        GridItem(.adaptive(minimum: SpotiglassDesign.Layout.quickAccessTileMinWidth), spacing: SpotiglassDesign.spacingS)
    ]

    init(
        viewModel: PlaylistBrowserViewModel,
        playbackViewModel: PlaybackSessionViewModel,
        queueViewModel: QueueViewModel,
        hasPlaybackDevice: Bool,
        onRequestCreatePlaylist: (([TrackRowViewModel]) -> Void)? = nil,
        onRequestLibraryContinuation: ((TrackRowViewModel) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.playbackViewModel = playbackViewModel
        self.queueViewModel = queueViewModel
        self.hasPlaybackDevice = hasPlaybackDevice
        self.onRequestCreatePlaylist = onRequestCreatePlaylist
        self.onRequestLibraryContinuation = onRequestLibraryContinuation
    }

    var body: some View {
        #if DEBUG
        let _ = ViewBodyTally.record("HomeView")
        #endif
        let tracks = viewModel.homeTopTracks.value ?? []
        let marks = TrackRowPlaybackSource(session: playbackViewModel).marks(in: tracks)
        // The whole page sits in the native track table, the way the artist page does (#319):
        // greeting, quick access and the shelf above the rows, so the top tracks select, move
        // with the arrow keys and read out to VoiceOver like every other track list, and the
        // selection is the one the menu bar acts on (#173).
        DetailTrackSelectionReader(selection: viewModel.detailTrackSelection) { selection in
            TrackListView(
                tracks: tracks,
                selection: selection,
                rowBuilder: { track, isSelected in
                    marks.row(for: track) { mark in topTrackRow(track, mark: mark, isSelected: isSelected, in: tracks) }
                },
                pendingScrollRestoreTrackID: .constant(nil),
                onFirstVisibleTrackChanged: { _ in },
                playSelection: { selectedIDs in
                    guard let uri = tracks.first(where: { selectedIDs.contains($0.id) })?.playableURI else { return }
                    play(uri, in: tracks)
                },
                rowActions: TrackListRowActions(
                    invocation: { TrackListRow.playbackInvocation(of: $0, mark: marks.mark(of: $0)) },
                    playURI: { uri in play(uri, in: tracks) },
                    togglePlayPause: { playbackViewModel.requestTogglePlayPause() },
                    menuItems: { targets in
                        AnyView(TrackOpsMenuItems(
                            targets: targets,
                            browserViewModel: viewModel,
                            sourcePlaylistID: nil,
                            onRequestCreatePlaylist: onRequestCreatePlaylist,
                            onRequestLibraryContinuation: onRequestLibraryContinuation,
                            openArtist: { target in
                                if let id = target.id {
                                    Task { await viewModel.selectArtist(id: id, origin: .extend, displayName: target.name) }
                                }
                            },
                            addToQueue: { uri in
                                await queueViewModel.addToQueue(uri: uri)
                            },
                            hasPlaybackDevice: hasPlaybackDevice,
                            copyableURI: targets.count == 1 ? targets.first?.playableURI : nil
                        ))
                    },
                    prepareMenus: { viewModel.prepareTrackMenus(for: $0) }
                ),
                headerContent: AnyView(listHeader)
            )
        }
    }

    private var listHeader: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.Layout.sectionSpacing) {
            HomeGreetingHeader(viewModel: viewModel)

            quickAccessGrid
            recentlyPlayedSection
            topTracksHeader
        }
        .padding(.horizontal, SpotiglassDesign.Layout.insetListContentInset)
        .padding(.vertical, SpotiglassDesign.spacingM)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Quick access

    private var quickAccessGrid: some View {
        LazyVGrid(columns: quickAccessColumns, spacing: SpotiglassDesign.spacingS) {
            ForEach(viewModel.homeQuickAccessCards) { card in
                HomeQuickAccessTile(card: card, browserViewModel: viewModel) {
                    open(card.destination)
                }
            }
        }
    }

    // MARK: - Recently played

    @ViewBuilder
    private var recentlyPlayedSection: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.Layout.sectionTitleSpacing) {
            HomeSectionHeader(title: SpotiglassL10n.string("home.section.recentlyPlayed"))
            switch viewModel.homeRecentlyPlayed {
            case .loading:
                HomeSectionNotice(style: .loading)
            case let .loaded(cards):
                if cards.isEmpty {
                    HomeSectionNotice(style: .message(
                        icon: "clock.arrow.circlepath",
                        text: SpotiglassL10n.string("home.recentlyPlayed.empty")
                    ))
                } else {
                    // The shelf hid its indicator and cut the last card in half,
                    // so nothing said it scrolled (#162). The indicator is back,
                    // and a trackpad swipe settles on card boundaries, so it never
                    // leaves a card bisected. A mouse wheel moves the shelf freely (#475).
                    // Lazy, like the top tracks: a plain stack laid out every card on every
                    // size the window took, which made resizing Home slow (#473).
                    ScrollView(.horizontal, showsIndicators: true) {
                        LazyHStack(alignment: .top, spacing: SpotiglassDesign.spacingM) {
                            ForEach(cards) { card in
                                HomeMediaCardView(card: card, browserViewModel: viewModel, openArtist: openArtist) {
                                    open(card.destination)
                                }
                            }
                        }
                        .scrollTargetLayout()
                        .padding(.vertical, SpotiglassDesign.spacingXS)
                    }
                    .shelfScrollBehavior()
                }
            case .unavailable:
                HomeSectionNotice(style: .message(
                    icon: "lock.fill",
                    text: SpotiglassL10n.string("home.section.reconnect")
                ))
            case let .failed(message):
                HomeSectionNotice(style: .message(icon: "exclamationmark.triangle", text: message.string))
            }
        }
    }

    // MARK: - Top tracks

    /// The section title, and in place of the rows a notice while they load, when there are none
    /// or when they can't be shown.
    @ViewBuilder
    private var topTracksHeader: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.Layout.sectionTitleSpacing) {
            HomeSectionHeader(title: SpotiglassL10n.string("home.section.topTracks"))
            switch viewModel.homeTopTracks {
            case .loading:
                HomeSectionNotice(style: .loading)
            case let .loaded(tracks):
                if tracks.isEmpty {
                    HomeSectionNotice(style: .message(
                        icon: "music.note",
                        text: SpotiglassL10n.string("home.topTracks.empty")
                    ))
                }
            case .unavailable:
                HomeSectionNotice(style: .message(
                    icon: "lock.fill",
                    text: SpotiglassL10n.string("home.section.reconnect")
                ))
            case let .failed(message):
                HomeSectionNotice(style: .message(icon: "exclamationmark.triangle", text: message.string))
            }
        }
    }

    private func topTrackRow(
        _ track: TrackRowViewModel,
        mark: TrackRowPlaybackMark,
        isSelected: Bool,
        in tracks: [TrackRowViewModel]
    ) -> TrackListRow {
        TrackListRow(
            trackNumber: track.listPosition,
            track: track,
            playURI: { uri in play(uri, in: tracks) },
            togglePlayPause: {
                playbackViewModel.requestTogglePlayPause()
            },
            isCurrent: mark.isCurrent,
            isPlaying: mark.isPlaying,
            openArtist: openArtist,
            isSelected: isSelected,
            // The table draws the selection and the hover, takes the keyboard focus, and
            // handles the double-click and the menu.
            drawsRowHighlights: false,
            isKeyboardFocusable: false,
            handlesClicks: false
        )
    }

    private func play(_ uri: String, in tracks: [TrackRowViewModel]) {
        let playableURIs = tracks.compactMap(\.playableURI)
        Task {
            await playbackViewModel.playFromPlaylist(clickedURI: uri, playableURIs: playableURIs, playlistID: nil)
        }
    }

    // MARK: - Navigation

    private func openArtist(_ artist: MusicArtistRef) {
        Task { await viewModel.selectArtist(id: artist.id, origin: .extend, displayName: artist.name) }
    }

    private func open(_ destination: HomeMediaCard.Destination) {
        switch destination {
        case .likedSongs:
            Task { await viewModel.selectSidebar(.likedSongs) }
        case let .playlist(id):
            Task { await viewModel.selectSidebar(.playlist(id)) }
        case let .album(id, title, subtitle, artworkURL):
            Task {
                await viewModel.selectAlbum(
                    id: id,
                    displayTitle: title,
                    displaySubtitle: subtitle,
                    artworkURL: artworkURL,
                    origin: .extend
                )
            }
        }
    }
}

/// Home's title. It wakes only when the greeting changes, and starts over with the new calendar when
/// the Mac's time zone or clock changes, so Home left open overnight, or carried into another time
/// zone, still greets for the local time (#464).
private struct HomeGreetingHeader: View {
    let viewModel: PlaylistBrowserViewModel
    @StateObject private var clock = HomeGreetingClock()

    var body: some View {
        TimelineView(HomeGreetingSchedule(calendar: clock.calendar)) { context in
            HomeSectionHeader(title: viewModel.homeGreeting(now: context.date, calendar: clock.calendar), style: .pageTitle)
        }
        // A new identity drops the entries already scheduled for the old time zone.
        .id(clock.generation)
    }
}

/// The calendar the home greeting is worked out in. It is replaced, and `generation` moves on,
/// whenever the system time zone or clock changes.
@MainActor
final class HomeGreetingClock: ObservableObject {
    @Published private(set) var generation = 0
    private(set) var calendar: Calendar
    private let currentCalendar: () -> Calendar
    private var cancellables = Set<AnyCancellable>()

    /// `currentCalendar` reads the system's calendar again; tests pass their own.
    init(
        notificationCenter: NotificationCenter = .default,
        currentCalendar: @escaping () -> Calendar = {
            NSTimeZone.resetSystemTimeZone()
            return Calendar.current
        }
    ) {
        self.currentCalendar = currentCalendar
        calendar = currentCalendar()
        Publishers.Merge(
            notificationCenter.publisher(for: .NSSystemTimeZoneDidChange),
            notificationCenter.publisher(for: .NSSystemClockDidChange)
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.reset() }
        .store(in: &cancellables)
    }

    private func reset() {
        calendar = currentCalendar()
        generation += 1
    }
}

/// Timeline entries at the moments the home greeting changes (00:00, 05:00, 12:00, 18:00).
struct HomeGreetingSchedule: TimelineSchedule {
    let calendar: Calendar

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next: Date? = startDate
        return AnyIterator {
            guard let current = next else { return nil }
            next = PlaylistBrowserViewModel.nextHomeGreetingChange(after: current, calendar: calendar)
            return current
        }
    }
}
