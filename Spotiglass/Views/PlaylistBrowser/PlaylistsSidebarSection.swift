import SwiftUI

struct PlaylistsSidebarSectionHeader: View {
    let playlistState: BrowsingLoadState<[PlaylistRowViewModel]>

    var body: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXS) {
            // The sidebar's own header style, the same as Library's (#444).
            Text(SpotiglassL10n.string("browser.playlists"))
            switch playlistState {
            case .staleCache:
                // Why it's from before is the banner's job at the bottom of the list (#608);
                // saying it here too showed the same failure twice.
                Text(SpotiglassL10n.string("browser.cachedData"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .refreshing:
                Text(SpotiglassL10n.string("browser.refreshing"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            default:
                EmptyView()
            }
        }
    }

}

struct PlaylistsSidebarSectionContent: View {
    let playlistState: BrowsingLoadState<[PlaylistRowViewModel]>
    let likedSongsStubRow: PlaylistRowViewModel
    @ObservedObject var viewModel: PlaylistBrowserViewModel
    /// Not observed: each row reads by itself whether its playlist is the one playing, so
    /// play/pause re-renders that row only, not the whole section and every row (#422).
    let playbackViewModel: PlaybackSessionViewModel
    @EnvironmentObject private var pinnedStore: PinnedItemsStore
    @State private var editingPlaylistID: String?
    @State private var editedPlaylistName = ""
    @FocusState private var isPlaylistNameFocused: Bool
    let playlistSummaryFromRow: (PlaylistRowViewModel) -> MusicPlaylistSummary

    private var visiblePlaylistIDs: [String] {
        playlistState.currentValue?.map(\.id) ?? []
    }

    var body: some View {
        #if DEBUG
            let _ = ViewBodyTally.record("PlaylistsSidebarSectionContent")
        #endif
        Group {
            likedSongsSidebarRow
            switch playlistState {
            case .loading:
                ProgressView(SpotiglassL10n.string("browser.loadingPlaylists"))
            case .loaded(let playlists), .refreshing(let playlists), .staleCache(let playlists, _):
                ForEach(playlists) { playlist in
                    playlistSidebarRow(playlist: playlist)
                }
            case .empty(let text):
                let message = text.string
                EmptyStateView(title: SpotiglassL10n.string("browser.noPlaylists.title"), message: message)
            case .error(let error):
                ErrorPage(
                    error: error,
                    retry: error.canRetry
                        ? {
                            Task { await viewModel.refreshPlaylists(trigger: .userInitiated) }
                        } : nil)
            }
        }
        .onChange(of: viewModel.sidebarSelection) { _, newSelection in
            guard let editingPlaylistID,
                newSelection != .playlist(editingPlaylistID)
            else { return }
            cancelPlaylistNameEditing()
        }
        .onChange(of: visiblePlaylistIDs) { _, playlistIDs in
            guard let editingPlaylistID,
                playlistIDs.contains(editingPlaylistID) == false
            else { return }
            cancelPlaylistNameEditing()
        }
        // "Edit playlist name" on a Home or Search tile of an empty playlist: its page has no
        // header to edit in, so the row edits here as if it had been right-clicked (#478).
        .onChange(of: viewModel.sidebarPlaylistNameEditRequestID, initial: true) { _, requestedID in
            guard let requestedID,
                let playlist = playlistState.currentValue?.first(where: { $0.id == requestedID })
            else { return }
            viewModel.playlistNameEditRequestID = nil
            beginPlaylistNameEditing(for: playlist)
        }
        // Cancel on focus loss instead of committing on blur. This avoids
        // saving an unfinished name after focus moves to another surface.
        .onChange(of: isPlaylistNameFocused) { _, isFocused in
            guard !isFocused, editingPlaylistID != nil else { return }
            cancelPlaylistNameEditing()
        }
    }

    @ViewBuilder
    private var likedSongsSidebarRow: some View {
        playbackViewModel.playlistRow(SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID) { mark in
            PlaylistListRow(
                playlist: likedSongsStubRow,
                currentUserID: viewModel.currentUserID,
                isActive: mark.isActive,
                isPlaying: mark.isPlaying,
                isListSelected: viewModel.sidebarSelection == .likedSongs,
                isPinned: false
            )
        }
        .id(SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID)
        .tag(SidebarSelection.likedSongs)
    }

    @ViewBuilder
    private func playlistSidebarRow(playlist: PlaylistRowViewModel) -> some View {
        let pinned = pinnedStore.isPinned(spotifyID: playlist.id, kind: .playlist)
        let summary = playlistSummaryFromRow(playlist)
        playbackViewModel.playlistRow(playlist.id) { mark in
            PlaylistListRow(
                playlist: playlist,
                currentUserID: viewModel.currentUserID,
                isActive: mark.isActive,
                isPlaying: mark.isPlaying,
                isListSelected: viewModel.sidebarSelection == .playlist(playlist.id),
                isPinned: pinned,
                titleOverride: editingPlaylistID == playlist.id
                    ? AnyView(playlistRenameEditor(playlist: playlist))
                    : nil
            )
        }
        .tag(SidebarSelection.playlist(playlist.id))
        .id(playlist.id)
        .draggable(PinnedItemTransfer(item: .playlist(summary))) {
            PinnedItemDragPill(item: .playlist(summary))
        }
        .contextMenu {
            CollectionMenuItems(
                menu: CollectionMenu.menu(
                    for: .playlist(summary),
                    isPinned: pinned,
                    canRename: viewModel.canRenamePlaylist(summary),
                    canDelete: viewModel.canDeletePlaylist(summary)
                ),
                placement: .sidebar
            ) { entry in
                switch entry {
                case .editPlaylistName:
                    beginPlaylistNameEditing(for: playlist)
                case .deletePlaylist:
                    viewModel.requestPlaylistDeletion(summary)
                case .pin:
                    pinnedStore.pin(.playlist(summary))
                case .unpin:
                    pinnedStore.unpin(id: PinnedItem.id(forKind: .playlist, spotifyID: playlist.id))
                }
            }
        }
    }

    private func beginPlaylistNameEditing(for playlist: PlaylistRowViewModel) {
        guard viewModel.canRenamePlaylist(playlistSummaryFromRow(playlist)) else { return }
        editingPlaylistID = playlist.id
        editedPlaylistName = playlist.title
    }

    private func playlistRenameEditor(playlist: PlaylistRowViewModel) -> some View {
        TextField("", text: $editedPlaylistName)
            .font(.body)
            .textFieldStyle(.plain)
            .focused($isPlaylistNameFocused)
            .onSubmit { commitPlaylistName(for: playlist.id) }
            .onExitCommand(perform: cancelPlaylistNameEditing)
            .onAppear { isPlaylistNameFocused = true }
    }

    private func commitPlaylistName(for playlistID: String) {
        guard
            let capturedPlaylistID = PlaylistRenameEditingPolicy.commitTarget(
                editingPlaylistID: editingPlaylistID,
                rowID: playlistID,
                visiblePlaylistIDs: visiblePlaylistIDs
            )
        else {
            cancelPlaylistNameEditing()
            return
        }
        let name = editedPlaylistName
        editingPlaylistID = nil
        isPlaylistNameFocused = false
        Task {
            await viewModel.renamePlaylist(id: capturedPlaylistID, name: name)
        }
    }

    private func cancelPlaylistNameEditing() {
        editingPlaylistID = nil
        isPlaylistNameFocused = false
        editedPlaylistName = ""
    }
}
