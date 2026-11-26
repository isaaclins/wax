import AppKit
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
        .background(TrackListSelectionShortcuts(
            tracks: tracks,
            liveSelection: liveSelection,
            shownSelection: selection,
            // A row of the table is a song only once the rows above the songs are known:
            // with a header and a footer they aren't, and the table keeps its own ⌘A and
            // shift-click (artist pages, whose top tracks are few).
            rowsAboveTracks: headerContent == nil ? .noRows : footerContent == nil ? .allOtherRows : nil
        ))
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

/// ⌘A and shift-click on the track table, done in code instead of by the table (#694).
///
/// SwiftUI builds the row of every song a selection made by the table adds, on screen or not:
/// on the table's selection change it asks each newly selected row how it selects, and that
/// makes the row's view. ⌘A on a 2,000-song playlist built all 2,000 rows and froze the window
/// for seconds; a shift-click over 30 songs took over 100 ms. The same selection set through the
/// binding doesn't ask the rows. So these two are caught before the table sees them and the
/// selection is set here: ⌘A selects every song, a shift-click the songs from the last song
/// clicked without shift to the clicked one, keeping songs picked with ⌘-click before, as the
/// table does. A plain click and a ⌘-click are left to the table:
/// they add one row at most.
struct TrackListSelectionShortcuts: NSViewRepresentable {
    /// Where the songs start among the table's rows.
    enum RowsAboveTracks {
        /// The songs are the table's first rows.
        case noRows
        /// Every row that isn't a song is above the songs (a header and no footer).
        case allOtherRows
    }

    let tracks: [TrackRowViewModel]
    /// The page's selection binding, kept in a closure like ``TrackListView``'s so it doesn't
    /// bring #751 back.
    let liveSelection: () -> Binding<Set<String>>
    var selection: Set<String> {
        get { liveSelection().wrappedValue }
        nonmutating set { liveSelection().wrappedValue = newValue }
    }
    /// The selection as the page last handed it in: a change that isn't the last click's own
    /// (an arrow key) moves where the next shift-click starts.
    let shownSelection: Set<String>
    /// `nil` when the songs' rows aren't known: the table then keeps ⌘A and shift-click.
    let rowsAboveTracks: RowsAboveTracks?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = Marker()
        view.coordinator = context.coordinator
        context.coordinator.marker = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.shortcuts = self
        // A disabled list (the lyrics cover the page) takes no clicks or keys.
        context.coordinator.isEnabled = context.environment.isEnabled
        context.coordinator.selectionChanged(to: shownSelection)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    /// Sits behind the list, over the same area, so the table under it is the one to act on.
    final class Marker: NSView {
        weak var coordinator: Coordinator?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { coordinator?.stop() } else { coordinator?.start() }
        }
    }

    @MainActor
    final class Coordinator {
        var shortcuts: TrackListSelectionShortcuts?
        var isEnabled = true
        weak var marker: NSView?
        private var monitor: Any?
        /// The window whose next mouse-up belongs to a shift-click handled here.
        private weak var swallowsMouseUpIn: NSWindow?
        /// Where a shift-click starts and what it keeps.
        private(set) var shiftClick = TrackListShiftClick()
        private var lastSelection: Set<String> = []

        func selectionChanged(to selection: Set<String>) {
            guard selection != lastSelection else { return }
            lastSelection = selection
            shiftClick.selectionChanged(to: selection)
        }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .leftMouseUp]) { [weak self] event in
                MainActor.assumeIsolated {
                    // Not `self?.handle(event) ?? event`: that hands on an event `handle` kept.
                    guard let self else { return event }
                    return self.handle(event)
                }
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard isEnabled, let shortcuts, shortcuts.rowsAboveTracks != nil, let window = marker?.window, event.window === window
            else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch event.type {
            case .keyDown:
                guard modifiers.subtracting([.capsLock, .numericPad, .function]) == .command,
                      event.charactersIgnoringModifiers?.lowercased() == "a",
                      let table = window.firstResponder as? NSTableView, isOurs(table)
                else { return event }
                shortcuts.selection = Set(shortcuts.tracks.map(\.id))
                shiftClick.selectedAll()
                return nil
            case .leftMouseUp:
                // The table selects on a mouse-up too: given the shift-click's, it made the
                // selection again itself and built the rows this is here to spare.
                guard swallowsMouseUpIn === window else { return event }
                swallowsMouseUpIn = nil
                return nil
            case .leftMouseDown:
                swallowsMouseUpIn = nil
                // A control-click opens the row's menu: the table leaves the selection and the
                // song a shift-click starts from as they are.
                guard !modifiers.contains(.control), let table = table(at: event.locationInWindow, in: window),
                      let id = trackID(atRow: table.row(at: table.convert(event.locationInWindow, from: nil)), of: table)
                else { return event }
                guard modifiers.subtracting([.capsLock, .numericPad, .function]) == .shift, event.clickCount == 1 else {
                    // A plain click, a ⌘-click, a ⌘-shift-click or a double-click: the table's,
                    // as before. The next shift-click extends from here.
                    shiftClick.clicked(
                        id, command: modifiers.contains(.command), shift: modifiers.contains(.shift),
                        selection: shortcuts.selection
                    )
                    return event
                }
                shortcuts.selection = shiftClick.shiftClicked(
                    id, positions: TrackListSelectionShortcuts.positions(of: shortcuts.tracks), tracks: shortcuts.tracks
                )
                // The table didn't get the click, so it takes the keyboard here, as a click gives it.
                if window.firstResponder !== table { window.makeFirstResponder(table) }
                swallowsMouseUpIn = window
                return nil
            default:
                return event
            }
        }

        /// The table this list is: the one whose scroll view covers the marker.
        private func isOurs(_ table: NSTableView) -> Bool {
            guard let marker, let scrollView = table.enclosingScrollView else { return false }
            let area = marker.convert(marker.bounds, to: nil)
            return scrollView.convert(scrollView.bounds, to: nil).contains(NSPoint(x: area.midX, y: area.midY))
        }

        /// This list's table, looked up once rather than on every click in the window.
        private weak var table: NSTableView?

        private func table(at point: NSPoint, in window: NSWindow) -> NSTableView? {
            if table.map({ $0.window !== window || !isOurs($0) }) ?? true {
                table = Self.tables(in: window.contentView).first(where: isOurs)
            }
            // Only a click the table itself gets: not one on the scroll bar or on something drawn
            // over the list, like a toast.
            guard let table, table.visibleRect.contains(table.convert(point, from: nil)),
                  window.contentView?.hitTest(point)?.isDescendant(of: table) == true
            else { return nil }
            return table
        }

        private static func tables(in view: NSView?) -> [NSTableView] {
            guard let view else { return [] }
            if let table = view as? NSTableView { return [table] }
            return view.subviews.flatMap { tables(in: $0) }
        }

        private func trackID(atRow row: Int, of table: NSTableView) -> String? {
            guard let shortcuts, let rowsAbove = shortcuts.rowsAboveTracks,
                  let index = TrackListSelectionShortcuts.trackIndex(
                      atRow: row, rowsAbove: rowsAbove, rowCount: table.numberOfRows, trackCount: shortcuts.tracks.count
                  )
            else { return nil }
            return shortcuts.tracks[index].id
        }
    }

    /// The song at a row of the table, or `nil` for a row that isn't one (the header above Home's
    /// top tracks, a footer below a playlist's songs).
    static func trackIndex(atRow row: Int, rowsAbove: RowsAboveTracks, rowCount: Int, trackCount: Int) -> Int? {
        let first = rowsAbove == .noRows ? 0 : rowCount - trackCount
        let index = row - first
        guard row >= 0, first >= 0, (0..<trackCount).contains(index) else { return nil }
        return index
    }

    /// Each song's place in the list, worked out when a shift-click needs it.
    static func positions(of tracks: [TrackRowViewModel]) -> [String: Int] {
        Dictionary(tracks.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The songs from `anchor` to `id`, added to the songs of `base` still in
    /// the list (those picked with ⌘-click before). Without an anchor still in the list, the song
    /// alone.
    static func extend(
        to id: String, from anchor: String?, keeping base: Set<String> = [],
        positions: [String: Int], tracks: [TrackRowViewModel]
    ) -> Set<String> {
        guard let to = positions[id], let from = anchor.flatMap({ positions[$0] }),
              tracks.indices.contains(to), tracks.indices.contains(from)
        else { return [id] }
        return base.filter { positions[$0] != nil }.union(tracks[min(from, to)...max(from, to)].map(\.id))
    }
}

/// Where a shift-click on the track table starts and what it keeps, the way the table itself
/// keeps them (#694): the song last clicked without shift, and the selection that click left.
/// So songs picked with ⌘-click stay, a second shift-click swaps only the range, and a selection
/// made since by ⌘A or shift-arrow is replaced by the range.
struct TrackListShiftClick: Equatable {
    /// The song a shift-click extends from: the last one clicked without shift, or the song
    /// selected alone (an arrow key moves it).
    private(set) var anchorID: String?
    /// What a shift-click adds its range to.
    private(set) var base: Set<String> = []

    /// A click without shift on `id` (plain, ⌘ or ⌘-shift), which the table makes: the selection
    /// it leaves, worked out ahead, is what the next shift-clicks keep.
    mutating func clicked(_ id: String, command: Bool, shift: Bool, selection: Set<String>) {
        anchorID = id
        base = !command ? [id] : shift ? selection.union([id]) : selection.symmetricDifference([id])
    }

    /// ⌘A: a shift-click after it selects the range alone, as the table's does.
    mutating func selectedAll() {
        base = []
    }

    /// A song selected alone other than by the last click (an arrow key) is where the next
    /// shift-click starts.
    mutating func selectionChanged(to selection: Set<String>) {
        guard selection.count == 1, selection != base else { return }
        anchorID = selection.first
        base = selection
    }

    /// A shift-click on `id`: the selection it makes.
    mutating func shiftClicked(_ id: String, positions: [String: Int], tracks: [TrackRowViewModel]) -> Set<String> {
        guard let anchorID, positions[anchorID] != nil else {
            anchorID = id
            base = []
            return [id]
        }
        return TrackListSelectionShortcuts.extend(to: id, from: anchorID, keeping: base, positions: positions, tracks: tracks)
    }
}
