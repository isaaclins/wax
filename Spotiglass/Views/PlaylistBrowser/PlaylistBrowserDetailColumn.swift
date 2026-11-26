import SwiftUI

/// The page and, while the queue is open, the queue panel beside it.
///
/// It observes the queue flag itself, so opening or closing the queue re-runs this body and not
/// the browser's (#673). Both columns are built once, when the browser builds this view, and kept
/// as values: a re-run here hands SwiftUI the same page it had, so the page, its rows and the
/// queue panel's inputs compare equal and only the layout changes.
struct PlaylistBrowserDetailWithQueueSplit<Main: View, Queue: View>: View {
    @Binding var unifiedRefreshFocus: UnifiedRefreshFocus
    @ObservedObject var queuePanel: StoredFlag
    private let mainColumn: Main
    private let queueColumn: Queue

    init(
        unifiedRefreshFocus: Binding<UnifiedRefreshFocus>,
        queuePanel: StoredFlag,
        @ViewBuilder mainColumn: () -> Main,
        @ViewBuilder queueColumn: () -> Queue
    ) {
        _unifiedRefreshFocus = unifiedRefreshFocus
        _queuePanel = ObservedObject(wrappedValue: queuePanel)
        self.mainColumn = mainColumn()
        self.queueColumn = queueColumn()
    }

    private var isQueueVisible: Bool { queuePanel.isOn }

    var body: some View {
        HStack(spacing: 0) {
            mainColumn
                .background(.background)
                .frame(minWidth: SpotiglassDesign.detailColumnMinWidth)
                .layoutPriority(1)
                .onHover { hovering in
                    if hovering { unifiedRefreshFocus = .mainContent }
                }
            if isQueueVisible {
                queueColumn
                    .transition(
                        .asymmetric(
                            insertion: .offset(x: SpotiglassDesign.sidebarWidth).combined(with: .opacity),
                            removal: .offset(x: SpotiglassDesign.sidebarWidth).combined(with: .opacity)
                        )
                    )
                    .onHover { hovering in
                        if hovering { unifiedRefreshFocus = .queuePanel }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.38, dampingFraction: 0.84), value: isQueueVisible)
    }
}

struct QueuePanelColumn: View {
    @ObservedObject var browserViewModel: PlaylistBrowserViewModel
    @ObservedObject var queueViewModel: QueueViewModel
    @ObservedObject var playbackViewModel: PlaybackSessionViewModel
    let openArtist: (ArtistTapTarget) -> Void
    let onRequestCreatePlaylist: (([TrackRowViewModel]) -> Void)?
    let onRequestLibraryContinuation: ((TrackRowViewModel) -> Void)?

    init(
        browserViewModel: PlaylistBrowserViewModel,
        queueViewModel: QueueViewModel,
        playbackViewModel: PlaybackSessionViewModel,
        openArtist: @escaping (ArtistTapTarget) -> Void,
        onRequestCreatePlaylist: (([TrackRowViewModel]) -> Void)? = nil,
        onRequestLibraryContinuation: ((TrackRowViewModel) -> Void)? = nil
    ) {
        _browserViewModel = ObservedObject(wrappedValue: browserViewModel)
        _queueViewModel = ObservedObject(wrappedValue: queueViewModel)
        _playbackViewModel = ObservedObject(wrappedValue: playbackViewModel)
        self.openArtist = openArtist
        self.onRequestCreatePlaylist = onRequestCreatePlaylist
        self.onRequestLibraryContinuation = onRequestLibraryContinuation
    }

    var body: some View {
        QueuePanelView(
            queueViewModel: queueViewModel,
            playbackViewModel: playbackViewModel,
            openArtist: openArtist,
            trackOpsMenuItems: { items in
                AnyView(TrackOpsMenuItems(
                    targets: items.map { TrackRowViewModel(queueItem: $0) },
                    browserViewModel: browserViewModel,
                    sourcePlaylistID: nil,
                    onRequestCreatePlaylist: onRequestCreatePlaylist,
                    onRequestLibraryContinuation: onRequestLibraryContinuation,
                    openArtist: openArtist,
                    artistTargetsOverride: items.flatMap(\.artistTapTargets),
                    // Remove from Queue is the queue panel's own item (#628); Add to Queue is
                    // meaningless for a row already in it.
                    copyableURI: items.first?.uri
                ))
            }
        )
        .background(.background)
        .frame(
            minWidth: SpotiglassDesign.queuePanelMinWidth,
            idealWidth: SpotiglassDesign.sidebarWidth,
            maxWidth: SpotiglassDesign.queuePanelMaxWidth
        )
    }
}

struct PlaylistBrowserMainDetailColumn: View {
    @ObservedObject var viewModel: PlaylistBrowserViewModel
    /// Not observed: the actions use them, and each track row reads by itself whether it is the
    /// playing one. Observing them re-rendered the whole detail column, every visible row
    /// included, on each play/pause and each new track (#422).
    let playbackViewModel: PlaybackSessionViewModel
    let queueViewModel: QueueViewModel
    /// Shared creation prompt owned by the browser shell for non-playlist
    /// surfaces. Playlist detail retains its inline prompt for now.
    let onRequestCreatePlaylist: (([TrackRowViewModel]) -> Void)?
    /// Queue orchestration owned by the browser shell and shared by every track
    /// surface's context menu.
    let onRequestLibraryContinuation: ((TrackRowViewModel) -> Void)?
    @EnvironmentObject private var lyricsOverlay: LyricsOverlayController

    @Binding var pendingPlaylistListScrollRestoreID: String?
    @Binding var detailLastVisibleTrackID: String?

    let hasPlaybackDevice: Bool

    init(
        viewModel: PlaylistBrowserViewModel,
        playbackViewModel: PlaybackSessionViewModel,
        queueViewModel: QueueViewModel,
        pendingPlaylistListScrollRestoreID: Binding<String?>,
        detailLastVisibleTrackID: Binding<String?>,
        hasPlaybackDevice: Bool,
        onRequestCreatePlaylist: (([TrackRowViewModel]) -> Void)? = nil,
        onRequestLibraryContinuation: ((TrackRowViewModel) -> Void)? = nil
    ) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
        self.playbackViewModel = playbackViewModel
        self.queueViewModel = queueViewModel
        self.onRequestCreatePlaylist = onRequestCreatePlaylist
        self.onRequestLibraryContinuation = onRequestLibraryContinuation
        _pendingPlaylistListScrollRestoreID = pendingPlaylistListScrollRestoreID
        _detailLastVisibleTrackID = detailLastVisibleTrackID
        self.hasPlaybackDevice = hasPlaybackDevice
    }

    var body: some View {
        #if DEBUG
        let _ = ViewBodyTally.record("PlaylistBrowserMainDetailColumn")
        #endif
        VStack(spacing: 0) {
            switch viewModel.detailState {
            case .loading:
                ProgressView(SpotiglassL10n.string("browser.loadingDetail"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .loaded(content), let .refreshing(content), let .staleCache(content, _):
                Group {
                    if lyricsOverlay.isPresented {
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityHidden(true)
                    } else {
                        switch content {
                        case .home:
                            HomeView(
                                viewModel: viewModel,
                                playbackViewModel: playbackViewModel,
                                queueViewModel: queueViewModel,
                                hasPlaybackDevice: hasPlaybackDevice,
                                onRequestCreatePlaylist: onRequestCreatePlaylist,
                                onRequestLibraryContinuation: onRequestLibraryContinuation
                            )
                        case .search:
                            CatalogSearchView(
                                viewModel: viewModel,
                                searchViewModel: viewModel.catalogSearch,
                                playbackViewModel: playbackViewModel,
                                queueViewModel: queueViewModel,
                                hasPlaybackDevice: hasPlaybackDevice,
                                onRequestCreatePlaylist: onRequestCreatePlaylist,
                                onRequestLibraryContinuation: onRequestLibraryContinuation
                            )
                        case let .playlist(detail):
                            playlistDetailView(detail)
                        case let .artist(detail):
                            artistDetailView(detail)
                        }
                    }
                }
                .overlay(alignment: .bottom) {
                    if case let .staleCache(_, error) = viewModel.detailState {
                        ErrorBanner(error: error, style: .floating, retry: error?.canRetry == false ? nil : {
                            Task { await viewModel.retryFailedDetail() }
                        })
                    } else if case .refreshing = viewModel.detailState {
                        ProgressView(SpotiglassL10n.string("browser.refreshingDetail"))
                            .controlSize(.small)
                            .padding(SpotiglassDesign.spacingS)
                            .background(.background, in: Capsule())
                            .padding(SpotiglassDesign.spacingM)
                    }
                }
            case let .empty(text):
                let message = text.string
                EmptyStateView(title: SpotiglassL10n.string("browser.noTracks.title"), message: message)
            case let .error(error):
                if let locked = error.lockedPlaylist {
                    FollowedPlaylistLockedView(error: error, info: locked, playbackViewModel: playbackViewModel)
                } else {
                    // The page that failed is asked again from here (#465), when asking
                    // again can help: not for "Sign in again" or "Access denied".
                    ErrorPage(error: error, retry: error.canRetry ? {
                        Task { await viewModel.retryFailedDetail() }
                    } : nil)
                }
            }
        }
        // Over every state, loading and errors included: a toast set while the page loads
        // used to wait for the rows and show up late (#608).
        .toast($viewModel.trackMutationToast)
    }

    private func playlistDetailView(_ detail: PlaylistDetailViewModel) -> some View {
        let headerPlaybackTarget = DetailHeaderPlayback.target(for: detail)
        return PlaylistDetailContent(
            detail: detail,
            currentUserID: viewModel.currentUserID,
            pendingScrollRestoreTrackID: $pendingPlaylistListScrollRestoreID,
            onTrackEnteredViewportApproximation: { detailLastVisibleTrackID = $0 },
            playURI: { uri in
                Task {
                    guard let playing = await viewModel.detailForPlayback(
                        detail,
                        playbackCommands: { playbackViewModel.playbackCommandCount }
                    ) else { return }
                    await playbackViewModel.playFromPlaylist(
                        clickedURI: uri,
                        playableURIs: playing.tracks.compactMap(\.playableURI),
                        playlistID: playing.playlist.id
                    )
                }
            },
            playback: TrackRowPlaybackSource(session: playbackViewModel),
            togglePlayPause: {
                playbackViewModel.requestTogglePlayPause()
            },
            hasPlaybackDevice: hasPlaybackDevice,
            addToQueue: { uri in
                await queueViewModel.addToQueue(uri: uri)
            },
            openArtist: { artist in
                Task { await viewModel.selectArtist(id: artist.id, origin: .extend, displayName: artist.name) }
            },
            onRequestLibraryContinuation: onRequestLibraryContinuation,
            playHeaderAction: {
                guard let playing = await viewModel.detailForPlayback(
                    detail,
                    playbackCommands: { playbackViewModel.playbackCommandCount }
                ) else { return }
                await DetailHeaderPlayback.play(
                    target: DetailHeaderPlayback.target(for: playing),
                    using: playbackViewModel
                )
            },
            shuffleHeaderAction: {
                guard let playing = await viewModel.detailForPlayback(
                    detail,
                    playbackCommands: { playbackViewModel.playbackCommandCount }
                ) else { return }
                await DetailHeaderPlayback.shuffleAndPlay(
                    target: DetailHeaderPlayback.target(for: playing),
                    using: playbackViewModel
                )
            },
            areHeaderActionsAvailable: headerPlaybackTarget.isPlayable,
            browserViewModel: viewModel
        )
    }

    private func artistDetailView(_ detail: ArtistDetailViewModel) -> some View {
        let headerPlaybackTarget = DetailHeaderPlayback.target(for: detail)
        return ArtistDetailContent(
            detail: detail,
            browserViewModel: viewModel,
            playTrack: { uri in
                // A song from "In your library" plays on through the saved songs (#658).
                let list = detail.tracks.contains { $0.playableURI == uri } ? detail.tracks : detail.libraryTracks
                let playableURIs = list.compactMap(\.playableURI)
                Task {
                    await playbackViewModel.playFromPlaylist(
                        clickedURI: uri,
                        playableURIs: playableURIs,
                        playlistID: nil
                    )
                }
            },
            openAlbum: { album in
                Task {
                    await viewModel.selectAlbum(
                        id: album.id,
                        displayTitle: album.title,
                        displaySubtitle: detail.artist.name,
                        artworkURL: album.artworkURL,
                        origin: .extend
                    )
                }
            },
            playAlbumContext: { albumURI in
                Task { await playbackViewModel.play(contextURI: albumURI) }
            },
            playback: TrackRowPlaybackSource(session: playbackViewModel),
            togglePlayPause: {
                playbackViewModel.requestTogglePlayPause()
            },
            hasPlaybackDevice: hasPlaybackDevice,
            addToQueue: { uri in
                await queueViewModel.addToQueue(uri: uri)
            },
            openArtist: { artist in
                Task { await viewModel.selectArtist(id: artist.id, origin: .extend, displayName: artist.name) }
            },
            loadMoreAlbums: {
                Task { await viewModel.loadMoreArtistAlbums() }
            },
            onRequestCreatePlaylist: onRequestCreatePlaylist,
            onRequestLibraryContinuation: onRequestLibraryContinuation,
            playHeaderAction: {
                await DetailHeaderPlayback.play(
                    target: headerPlaybackTarget,
                    using: playbackViewModel
                )
            },
            shuffleHeaderAction: {
                await DetailHeaderPlayback.shuffleAndPlay(
                    target: headerPlaybackTarget,
                    using: playbackViewModel
                )
            },
            areHeaderActionsAvailable: headerPlaybackTarget.isPlayable
        )
    }
}

/// The toolbar's queue button. Its own view so that only its tooltip follows the queue flag,
/// not the browser that holds the toolbar (#673).
struct QueuePanelToolbarButton: View {
    @ObservedObject var queuePanel: StoredFlag

    var body: some View {
        Button {
            queuePanel.isOn.toggle()
        } label: {
            Label(SpotiglassL10n.string("browser.queue"), systemImage: "list.bullet.indent")
        }
        .help(
            queuePanel.isOn
                ? SpotiglassL10n.string("tooltip.toolbar.queue.hide")
                : SpotiglassL10n.string("tooltip.toolbar.queue.show")
        )
        .accessibilityHint(SpotiglassL10n.string("browser.queue.hint"))
    }
}
