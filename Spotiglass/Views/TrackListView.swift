import SwiftUI

/// Native track collection used by playlist-like detail surfaces.
///
/// `List` on macOS is backed by `NSTableView`, so it virtualizes rows itself:
/// only the rows inside the clip view plus a small reuse margin are ever
/// realized, which is the property the previous hand written virtualizer
/// existed to provide. Handing the job back to the framework also brings the
/// table behaviors the custom scroll view had to fake or go without: click to
/// select, shift-click to extend a range, command-click to toggle, selection
/// that de-emphasizes when the window stops being key, arrow key navigation,
/// and a focus ring on the row a context menu was opened on.
///
/// Optional header and footer content lets a detail surface keep its metadata
/// and release shelves in the same native collection instead of nesting a
/// selectable table inside another scroll view.
struct TrackListView<Row: View>: View {
    let tracks: [TrackRowViewModel]
    /// Bound straight through to the browser view model's selection set, which
    /// stays the source of truth every context menu action reads.
    @Binding var selection: Set<String>
    let rowBuilder: (TrackRowViewModel) -> Row
    /// Optional content rendered above the track rows in the native list.
    let headerContent: AnyView?
    /// Optional content rendered below the track rows in the native list.
    let footerContent: AnyView?
    /// Set externally (e.g. when lyrics dismiss) to a track id; the list scrolls
    /// that row to the middle of the viewport, then clears the binding.
    @Binding var pendingScrollRestoreTrackID: String?
    /// Fires with the id of the topmost visible row whenever it changes; powers
    /// the "remember last visible track" behavior used for scroll restore.
    let onFirstVisibleTrackChanged: (String) -> Void
    /// Plays the selected rows. Arrow keys already moved the selection, but
    /// nothing consumed Return, so a keyboard user could highlight a track and
    /// never start it (#122).
    var playSelection: ((Set<String>) -> Void)? = nil
    /// Drag-to-reorder (#543): the table's own move, with its insertion line and the selected
    /// rows moving together. `nil` offers no reordering at all (Liked Songs, albums, other
    /// people's playlists). Rows stay draggable to the sidebar either way.
    var moveRows: ((IndexSet, Int) -> Void)? = nil
    /// Everything the rows are built from besides their own track and selection: the list they
    /// belong to and what the row builder's closures read. While it stays the same, a row whose
    /// track and selection didn't change keeps the row it has instead of being built again.
    /// `nil` builds every row again on each update of the list.
    ///
    /// The Mac `List` runs the body of every row it was given, on screen or not, each time this
    /// view updates: the first scroll, a click that selects, any change in the browser. On a
    /// 2,000-song playlist that was 2,000 rows per click and a first scroll frame of over 200 ms
    /// (#655).
    var rowContentKey: AnyHashable? = nil

    init(
        tracks: [TrackRowViewModel],
        selection: Binding<Set<String>>,
        rowBuilder: @escaping (TrackRowViewModel) -> Row,
        pendingScrollRestoreTrackID: Binding<String?>,
        onFirstVisibleTrackChanged: @escaping (String) -> Void,
        playSelection: ((Set<String>) -> Void)? = nil,
        moveRows: ((IndexSet, Int) -> Void)? = nil,
        rowContentKey: AnyHashable? = nil,
        headerContent: AnyView? = nil,
        footerContent: AnyView? = nil
    ) {
        self.tracks = tracks
        _selection = selection
        self.rowBuilder = rowBuilder
        self.headerContent = headerContent
        self.footerContent = footerContent
        _pendingScrollRestoreTrackID = pendingScrollRestoreTrackID
        self.onFirstVisibleTrackChanged = onFirstVisibleTrackChanged
        self.playSelection = playSelection
        self.moveRows = moveRows
        self.rowContentKey = rowContentKey
    }

    /// Deliberately a reference type rather than stored-in-state values. Rows
    /// report every time the table realizes or drops one, and keeping that in
    /// view state would invalidate the body on each report, re-walking the whole
    /// track array to redraw nothing. Nobody observes this bookkeeping.
    @State private var realizedRows = TrackListRealizedRows()
    /// A click selects a row but left the table without keyboard focus: the row's own tap
    /// gestures take the mouse-down, so the selection stayed grey (the inactive look) and the
    /// arrow keys, Delete and ⌘A never reached the table (#628). A new selection focuses it.
    @FocusState private var isListFocused: Bool

    var body: some View {
        let generations = realizedRows.generations(tracks: tracks, selection: selection)
        ScrollViewReader { proxy in
            List(selection: $selection) {
                if let headerContent {
                    headerContent
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                }

                // Its own view, so an update of this one that leaves the rows as they were (the
                // table runs it on about every frame of a scroll) doesn't walk all of them.
                TrackListRows(
                    tracks: tracks,
                    selection: selection,
                    generations: generations,
                    rowContentKey: rowContentKey,
                    rowBuilder: rowBuilder,
                    moveRows: moveRows,
                    setRowRealized: { setRowRealized($0, track: $1) }
                )

                if let footerContent {
                    footerContent
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.inset)
            .environment(\.defaultMinListRowHeight, TrackListRow.listRowHeight)
            .focused($isListFocused)
            .onChange(of: selection) {
                // A click already gave the table focus; asking again runs this view again.
                if !selection.isEmpty, !isListFocused { isListFocused = true }
            }
            .onKeyPress(.return) {
                guard let playSelection, !selection.isEmpty else { return .ignored }
                playSelection(selection)
                return .handled
            }
            // Rows that change places (a reorder) don't appear again, so the topmost one is
            // worked out anew from the rows' new order.
            .onChange(of: tracks, initial: true) {
                realizedRows.positionByTrackID = TrackListVisibility.positions(of: tracks)
                reportFirstVisibleTrack()
            }
            .onChange(of: pendingScrollRestoreTrackID) { _, newValue in
                guard let id = newValue else { return }
                if tracks.contains(where: { $0.id == id }) {
                    proxy.scrollTo(id, anchor: .center)
                }
                pendingScrollRestoreTrackID = nil
            }
        }
    }

    private func setRowRealized(_ isRealized: Bool, track: TrackRowViewModel) {
        if isRealized {
            realizedRows.trackIDs.insert(track.id)
        } else {
            realizedRows.trackIDs.remove(track.id)
        }
        reportFirstVisibleTrack()
    }

    private func reportFirstVisibleTrack() {
        guard let id = TrackListVisibility.firstVisibleTrackID(realized: realizedRows.trackIDs, positions: realizedRows.positionByTrackID),
              id != realizedRows.lastReportedFirstVisibleTrackID
        else { return }
        realizedRows.lastReportedFirstVisibleTrackID = id
        onFirstVisibleTrackChanged(id)
    }
}

/// Ids of the rows the table currently has realized. A table only realizes what
/// it draws, so this stays about a viewport deep however long the playlist is.
/// Kept by id, not row number: a row dragged to a new spot keeps its identity and
/// doesn't appear again, so a number recorded for it would go stale (#543).
@MainActor
final class TrackListRealizedRows {
    var trackIDs: Set<String> = []
    /// Each row's place in the list, built again when the rows change.
    var positionByTrackID: [String: Int] = [:]
    var lastReportedFirstVisibleTrackID: String?

    /// Counters that move on when the list's rows or its selection change, so a row can tell
    /// either changed without comparing all of it.
    struct Generations: Equatable {
        var tracks = 0
        var selection = 0
    }

    private var generations = Generations()
    private var lastTracks: [TrackRowViewModel] = []
    private var lastSelection: Set<String> = []

    /// The counters for `tracks` and `selection`, moved on for whichever is new.
    func generations(tracks: [TrackRowViewModel], selection: Set<String>) -> Generations {
        if tracks != lastTracks {
            lastTracks = tracks
            generations.tracks &+= 1
        }
        if selection != lastSelection {
            lastSelection = selection
            generations.selection &+= 1
        }
        return generations
    }
}

/// The track rows of ``TrackListView``. Built again only when the rows, the selection or the
/// list's ``TrackListView/rowContentKey`` changed, and then each row only when its own
/// ``TrackListRowKey`` did (#655).
private struct TrackListRows<Row: View>: View, Equatable {
    let tracks: [TrackRowViewModel]
    let selection: Set<String>
    let generations: TrackListRealizedRows.Generations
    let rowContentKey: AnyHashable?
    let rowBuilder: (TrackRowViewModel) -> Row
    let moveRows: ((IndexSet, Int) -> Void)?
    let setRowRealized: (Bool, TrackRowViewModel) -> Void

    var body: some View {
        #if DEBUG
        let _ = ViewBodyTally.record("TrackListRows")
        #endif
        ForEach(tracks) { track in
            // One view per song, whatever the row builder returns: a builder's view
            // isn't known to be one view, so on every play / pause the table walked
            // every song of the list to collect the rows' ids, 20 ms with 2,543 songs (#645).
            HStack(spacing: 0) {
                TrackListRowSlot(
                    key: rowKey(for: track),
                    track: track,
                    content: rowBuilder
                )
                .equatable()
            }
            .frame(height: TrackListRow.listRowHeight)
            // With the list's own inset the row's edge lands on the
            // page margin, under the header's artwork and titles.
            .listRowInsets(EdgeInsets(
                top: 0,
                leading: SpotiglassDesign.Layout.insetListContentInset,
                bottom: 0,
                trailing: SpotiglassDesign.Layout.insetListContentInset
            ))
            .tag(track.id)
            // Row lifecycle is what tells us where the list is. Deriving
            // it from the scroll offset instead reads the wrong row,
            // because NSTableView estimates the height of rows it has
            // not measured yet, so a jump down a long playlist leaves
            // the offset covering more rows than the arithmetic thinks.
            // onScrollVisibilityChange would be the precise answer but
            // it never fires inside a macOS List, so this settles for the
            // table's realized rows, which run one row wide of the
            // visible ones. The consumer wants an approximation.
            .onAppear { setRowRealized(true, track) }
            .onDisappear { setRowRealized(false, track) }
        }
        .onMove(perform: moveRows)
    }

    private func rowKey(for track: TrackRowViewModel) -> TrackListRowKey {
        let isSelected = selection.contains(track.id)
        return TrackListRowKey(
            trackID: track.id,
            isSelected: isSelected,
            // A row in a selection of several acts on all of it, so it follows the selection.
            selection: isSelected && selection.count > 1 ? generations.selection : 0,
            tracks: generations.tracks,
            list: rowContentKey
        )
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rowContentKey != nil
            && lhs.rowContentKey == rhs.rowContentKey
            && lhs.generations == rhs.generations
            && (lhs.moveRows == nil) == (rhs.moveRows == nil)
    }
}

/// What a row of ``TrackListView`` is built from (#655). The row's id stands for its track:
/// within one generation of the list's rows an id always has the same track, and comparing
/// the whole track of every row on each update cost more than the rows it saved.
struct TrackListRowKey: Equatable {
    var trackID: String
    var isSelected: Bool
    var selection: Int
    var tracks: Int
    var list: AnyHashable?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.trackID == rhs.trackID
            && lhs.isSelected == rhs.isSelected
            && lhs.selection == rhs.selection
            && lhs.tracks == rhs.tracks
            && lhs.list == rhs.list
    }
}

/// One row of ``TrackListView``, built again only when its ``TrackListRowKey`` changes. A list
/// without a ``TrackListView/rowContentKey`` builds it every time.
private struct TrackListRowSlot<Row: View>: View, Equatable {
    let key: TrackListRowKey
    let track: TrackRowViewModel
    let content: (TrackRowViewModel) -> Row

    var body: some View {
        content(track)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.key.list != nil && lhs.key == rhs.key
    }
}

/// Picks the topmost row out of the rows the table currently has on hand, by
/// their places in the list as it is now. Only the realized rows are looked at,
/// about a viewport of them, however long the list.
enum TrackListVisibility {
    static func positions(of tracks: [TrackRowViewModel]) -> [String: Int] {
        Dictionary(tracks.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
    }

    static func firstVisibleTrackID(realized: Set<String>, positions: [String: Int]) -> String? {
        realized.min { (positions[$0] ?? .max, $0) < (positions[$1] ?? .max, $1) }
    }
}


/// Shows `content` with a binding to the detail selection, and runs it again when the
/// selection changes (#655). The binding is to the selection itself: one through the browser
/// view model's property counted as changed every time the table read it, so the table's view
/// ran again on every frame of a scroll.
struct DetailTrackSelectionReader<Content: View>: View {
    @ObservedObject var selection: DetailTrackSelection
    @ViewBuilder let content: (Binding<Set<String>>) -> Content

    var body: some View {
        content($selection.ids)
    }
}
