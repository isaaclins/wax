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
    /// The browser view model's selection set as the page handed it in, which stays the source
    /// of truth every context menu action reads, and how to change it. It isn't kept as a
    /// `Binding`: a binding into a view model tells
    /// SwiftUI it changed every time SwiftUI looks, and on macOS 26 opening or closing the queue
    /// makes SwiftUI look at this view, so the list ran every row it holds with each press
    /// though nothing in them changed (#751). The page builds this view again when it changes.
    private let selection: Set<String>
    /// The page's selection binding, handed to the list in the body: it reads the selection live,
    /// so a click the table makes is read back before the page has built this view again. It is
    /// kept inside a closure on purpose: kept as a `Binding` it would bring #751 back.
    private let liveSelection: () -> Binding<Set<String>>
    let rowBuilder: (TrackRowViewModel) -> Row
    /// Optional content rendered above the track rows in the native list.
    let headerContent: AnyView?
    /// Optional content rendered below the track rows in the native list.
    let footerContent: AnyView?
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
        playSelection: ((Set<String>) -> Void)? = nil,
        moveRows: ((IndexSet, Int) -> Void)? = nil,
        rowContentKey: AnyHashable? = nil,
        headerContent: AnyView? = nil,
        footerContent: AnyView? = nil
    ) {
        self.tracks = tracks
        self.selection = selection.wrappedValue
        liveSelection = { selection }
        self.rowBuilder = rowBuilder
        self.headerContent = headerContent
        self.footerContent = footerContent
        self.playSelection = playSelection
        self.moveRows = moveRows
        self.rowContentKey = rowContentKey
    }

    /// A reference type rather than state: the counters move on as the body runs, and keeping
    /// them in view state would run the body again for it. Nobody observes them.
    @State private var generationCounter = TrackListGenerations()

    var body: some View {
        #if DEBUG
        let _ = ViewBodyTally.record("TrackListView")
        #endif
        let generations = generationCounter.generations(tracks: tracks, selection: selection)
        List(selection: liveSelection()) {
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
                moveRows: moveRows
            )

            if let footerContent {
                footerContent
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .environment(\.defaultMinListRowHeight, TrackListRow.listRowHeight)
        .modifier(FocusedOnSelection(selection: selection))
        .onKeyPress(.return) {
            guard let playSelection, !selection.isEmpty else { return .ignored }
            playSelection(selection)
            return .handled
        }
    }
}

@MainActor
final class TrackListGenerations {
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
    let generations: TrackListGenerations.Generations
    let rowContentKey: AnyHashable?
    let rowBuilder: (TrackRowViewModel) -> Row
    let moveRows: ((IndexSet, Int) -> Void)?

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

/// A click selects a row but left the table without keyboard focus: the row's own tap gestures
/// take the mouse-down, so the selection stayed grey (the inactive look) and the arrow keys,
/// Delete and ⌘A never reached the table (#628). A new selection focuses it.
///
/// The focus state lives here, not in ``TrackListView``: every move of the keyboard in the window
/// (the lyrics taking it when they open, giving it back when they close) updates it, and in the
/// list that ran the list's body again (#674).
private struct FocusedOnSelection: ViewModifier {
    let selection: Set<String>
    @FocusState private var isListFocused: Bool

    func body(content: Content) -> some View {
        content
            .focused($isListFocused)
            .onChange(of: selection) {
                // A click already gave the table focus; asking again runs this view again.
                if !selection.isEmpty, !isListFocused { isListFocused = true }
            }
    }
}
