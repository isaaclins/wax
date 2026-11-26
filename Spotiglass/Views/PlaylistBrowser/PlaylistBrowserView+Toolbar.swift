import SwiftUI

extension PlaylistBrowserView {
    var unifiedRefreshToolbarButton: some View {
        Button {
            Task { await performUnifiedToolbarRefresh() }
        } label: {
            refreshToolbarLabelIconAndText
        }
        .buttonStyle(.borderless)
        .disabled(isUnifiedRefreshBusy)
        .help(SpotiglassL10n.string("tooltip.toolbar.refresh"))
        .accessibilityHint(
            SpotiglassL10n.string("browser.toolbar.refreshHelp")
        )
    }

    /// Icon + “Refresh” label; horizontal padding keeps the borderless primary-action item clear of the toolbar edge.
    var refreshToolbarLabelIconAndText: some View {
        refreshToolbarLabelCore
            .padding(.horizontal, SpotiglassDesign.spacingM)
    }

    var refreshToolbarLabelCore: some View {
        HStack(spacing: SpotiglassDesign.spacingXS) {
            Group {
                if isUnifiedRefreshBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.body.weight(.medium))
                }
            }
            .frame(width: SpotiglassDesign.Layout.iconSize, height: SpotiglassDesign.Layout.iconSize)
            Text(SpotiglassL10n.string("browser.refresh"))
        }
    }

    /// Refresh is only in the toolbar while the lyrics are closed (#438), so they don't count here.
    var isUnifiedRefreshBusy: Bool {
        if isQueueVisible, unifiedRefreshFocus == .queuePanel {
            return viewModel.isUnifiedQueueRefreshActive
        }
        return isPlaylistOrDetailRefreshing
    }

    var isPlaylistOrDetailRefreshing: Bool {
        if case .refreshing = viewModel.playlistState { return true }
        if case .refreshing = viewModel.detailState { return true }
        return false
    }

    /// `lyricsPresented`: the lyrics' new state while it is being changed, before it is stored.
    func syncUnifiedRefreshRoutingToViewModel(lyricsPresented: Bool? = nil) {
        viewModel.refreshRoutingLyricsPresented = lyricsPresented ?? lyricsOverlay.isPresented
        viewModel.refreshRoutingQueuePanelVisible = isQueueVisible
        viewModel.refreshRoutingQueuePanelFocused = unifiedRefreshFocus == .queuePanel
    }

    func performUnifiedToolbarRefresh() async {
        syncUnifiedRefreshRoutingToViewModel()
        await viewModel.performUnifiedRefresh { await queueViewModel.refreshQueue() }
    }
}

/// Always-visible browser feedback for the bulk playlist-track prefetch. This
/// lives in the main window toolbar rather than the palette so a menu-bar run
/// is observable and cancellable without opening another surface.
struct PlaylistBrowserPrefetchProgressToolbarItem: View {
    let progress: PrefetchAllPlaylistsProgress
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: SpotiglassDesign.spacingXS) {
            Image(systemName: iconName)
                .foregroundStyle(.secondary)
            if progress.phase == .running, progress.total > 0 {
                ProgressView(
                    value: Double(progress.processedCount),
                    total: Double(progress.total)
                )
                .progressViewStyle(.linear)
                .frame(width: SpotiglassDesign.Layout.toolbarProgressWidth)
            }
            Text(progress.localizedStatusLabel)
                .font(.caption)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if progress.phase == .running {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(SpotiglassL10n.string("palette.cancelPrefetch"))
                .accessibilityLabel(SpotiglassL10n.string("palette.cancelPrefetch"))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(progress.localizedStatusLabel)
    }

    private var iconName: String {
        switch progress.phase {
        case .running:
            "arrow.down.circle"
        case .finished:
            "checkmark.circle.fill"
        case .cancelled:
            "xmark.circle"
        }
    }
}

/// The browser's toolbar items. They observe the lyrics' state themselves, so opening or closing
/// the lyrics swaps them without running the browser's body (#674).
struct BrowserToolbarItems<RefreshButton: View>: ToolbarContent {
    @ObservedObject var presentation: LyricsPresentationState
    @ObservedObject var viewModel: PlaylistBrowserViewModel
    /// Only its button observes it, so opening the queue doesn't run the toolbar again (#673).
    let queuePanel: StoredFlag
    /// Whether the page shows its title in the bar (not on Home, #495); the lyrics always do.
    let pageShowsTitle: Bool
    let canDisconnect: Bool
    let disconnectHint: String
    let confirmDisconnect: () -> Void
    let popOutLyrics: () -> Void
    let closeLyrics: () -> Void
    let refreshButton: RefreshButton

    var body: some ToolbarContent {
        // The title is what pushed the items to the bar's trailing edge; without it on Home they
        // slid over next to the sidebar button. A flexible space takes its place (#495).
        if !(presentation.isPresented || pageShowsTitle) {
            ToolbarSpacer(.flexible)
        }
        if let progress = viewModel.prefetchAllPlaylistsProgress {
            ToolbarItem(placement: .automatic) {
                PlaylistBrowserPrefetchProgressToolbarItem(progress: progress) {
                    Task { await viewModel.toggleBulkPlaylistTrackPrefetch() }
                }
                .hiddenFromAccessibilityBehindPalette()
            }
        }
        // Only once there is somewhere to go back to, like Music: at the
        // root a dimmed chevron would sit beside the title doing nothing.
        // Back belongs to the page under the lyrics, so it leaves with that page (#438).
        if !presentation.isPresented, viewModel.canNavigateBack {
            ToolbarItem(placement: .navigation) {
                NavigationToolbarChrome(viewModel: viewModel)
                    .hiddenFromAccessibilityBehindPalette()
            }
        }
        // With the lyrics open the bar keeps what still applies (the queue panel stays next
        // to them) and trades Refresh and Disconnect for closing the lyrics: Refresh would
        // reload a page that isn't showing (#438).
        ToolbarItemGroup(placement: .automatic) {
            QueuePanelToolbarButton(queuePanel: queuePanel)
                .hiddenFromAccessibilityBehindPalette()

            if presentation.isPresented {
                // Moves the lyrics into the small window that can stay above other apps (#439).
                Button(action: popOutLyrics) {
                    Label(SpotiglassL10n.string("lyrics.popOut.button"), systemImage: "pip.enter")
                }
                .help(SpotiglassL10n.string("lyrics.popOut.button.help"))
                .hiddenFromAccessibilityBehindPalette()

                Button(action: closeLyrics) {
                    Label(SpotiglassL10n.string("browser.closeLyrics"), systemImage: "xmark")
                }
                .help(SpotiglassL10n.string("browser.closeLyrics"))
                .accessibilityHint(SpotiglassL10n.string("browser.closeLyrics.hint"))
                .hiddenFromAccessibilityBehindPalette()
            } else if canDisconnect {
                Button(action: confirmDisconnect) {
                    Label(SpotiglassL10n.string("browser.disconnect"), systemImage: "rectangle.portrait.and.arrow.right")
                }
                .help(SpotiglassL10n.string("browser.disconnect"))
                .accessibilityHint(disconnectHint)
                .hiddenFromAccessibilityBehindPalette()
            }
        }
        if !presentation.isPresented {
            ToolbarItem(placement: .primaryAction) {
                refreshButton
                    .hiddenFromAccessibilityBehindPalette()
            }
        }
    }
}

/// The window's name: where you are, or the lyrics while they are open (#438). Observes the
/// lyrics' state itself, so the browser's body doesn't run when they open or close (#674).
struct LyricsAwareWindowTitle: ViewModifier {
    @ObservedObject var presentation: LyricsPresentationState
    let pageTitle: String
    let pageShowsTitle: Bool

    func body(content: Content) -> some View {
        let lyrics = presentation.isPresented
        content
            .navigationTitle(lyrics ? SpotiglassL10n.string("playback.controls.lyrics") : pageTitle)
            .toolbar(removing: lyrics || pageShowsTitle ? nil : .title)
    }
}

/// The page under the open lyrics: still built, so closing the lyrics shows it again at once,
/// where it was, instead of building it and every row on screen again (#674); hidden, and out of
/// reach of VoiceOver, Tab and the page's own shortcuts, since you can't see its rows (#438).
/// It fades with the lyrics; switching it off for the keyboard and VoiceOver reaches every view
/// of the page, so that follows a frame later with the toolbar (the lyrics cover it meanwhile).
struct HiddenUnderLyrics: ViewModifier {
    @ObservedObject var presentation: LyricsPresentationState
    @ObservedObject var chromePresentation: LyricsPresentationState

    func body(content: Content) -> some View {
        let covered = chromePresentation.isPresented
        content
            .disabled(covered)
            .accessibilityHidden(covered)
            .opacity(presentation.isPresented ? 0 : 1)
    }
}
