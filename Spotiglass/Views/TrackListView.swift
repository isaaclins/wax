import AppKit
import Combine
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
    /// of truth every context menu action reads, and how to change it. Neither this nor
    /// `pendingScrollRestoreTrackID` is kept as a `Binding`: a binding into a view model tells
    /// SwiftUI it changed every time SwiftUI looks, and on macOS 26 opening or closing the queue
    /// makes SwiftUI look at this view, so the list ran every row it holds with each press
    /// though nothing in them changed (#751). The page builds this view again when either changes.
    private let selection: Set<String>
    /// The page's selection binding, handed to the list in the body: it reads the selection live,
    /// so a click the table makes is read back before the page has built this view again. It is
    /// kept inside a closure on purpose: kept as a `Binding` it would bring #751 back.
    private let liveSelection: () -> Binding<Set<String>>
    /// Builds a row from its track and whether it is selected. A click changes the second only for
    /// the rows it selects or leaves, and only those are built again (#689).
    let rowBuilder: (TrackRowViewModel, Bool) -> Row
    /// Optional content rendered above the track rows in the native list.
    let headerContent: AnyView?
    /// Optional content rendered below the track rows in the native list.
    let footerContent: AnyView?
    /// Set externally (e.g. when lyrics dismiss) to a track id; the list scrolls
    /// that row to the middle of the viewport, then clears it.
    private let pendingScrollRestoreTrackID: String?
    private let clearPendingScrollRestore: () -> Void
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
    /// Double-click and the right-click menu of the rows (#689). `nil` offers neither.
    var rowActions: TrackListRowActions? = nil
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
        rowBuilder: @escaping (TrackRowViewModel, Bool) -> Row,
        pendingScrollRestoreTrackID: Binding<String?>,
        onFirstVisibleTrackChanged: @escaping (String) -> Void,
        playSelection: ((Set<String>) -> Void)? = nil,
        moveRows: ((IndexSet, Int) -> Void)? = nil,
        rowActions: TrackListRowActions? = nil,
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
        self.pendingScrollRestoreTrackID = pendingScrollRestoreTrackID.wrappedValue
        clearPendingScrollRestore = { pendingScrollRestoreTrackID.wrappedValue = nil }
        self.onFirstVisibleTrackChanged = onFirstVisibleTrackChanged
        self.playSelection = playSelection
        self.moveRows = moveRows
        self.rowActions = rowActions
        self.rowContentKey = rowContentKey
    }

    /// Deliberately a reference type rather than stored-in-state values. Rows
    /// report every time the table realizes or drops one, and keeping that in
    /// view state would invalidate the body on each report, re-walking the whole
    /// track array to redraw nothing. Nobody observes this bookkeeping.
    @State private var realizedRows = TrackListRealizedRows()
    /// The selection as the rows read it. A row follows it by itself, so a click builds again
    /// only the rows it selects or leaves, not the list of all of them (#689).
    @State private var selectionFeed = TrackListSelectionFeed()
    /// A click selects a row but left the table without keyboard focus, so the selection stayed
    /// grey (the inactive look) and the arrow keys, Delete and ⌘A never reached the table (#628).
    /// The list selects through its own click recognizer, which doesn't focus the table, even
    /// with no gesture on the rows. A new selection focuses it, from AppKit: SwiftUI's focus state
    /// still said "focused" after the keyboard had gone elsewhere through AppKit, and then the
    /// table never got it back (#689).
    @State private var tableFocus = TrackListTableFocus()

    var body: some View {
        #if DEBUG
        let _ = ViewBodyTally.record("TrackListView")
        #endif
        let tracksGeneration = realizedRows.generation(of: tracks)
        let _ = selectionFeed.store(selection)
        // The table's double-click, from AppKit. SwiftUI's own (the primary action of
        // `contextMenu(forSelectionType:)`) held every mouse-down back until the mouse-up and then
        // handed the table both at once: the table waited for a mouse-up that had already come,
        // and the next click only ended that wait instead of selecting its row (#689).
        let _ = tableFocus.onDoubleClick = doubleClickAction
        ScrollViewReader { proxy in
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
                    tracksGeneration: tracksGeneration,
                    selectionFeed: selectionFeed,
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
            .background(TrackListTableFocus.Probe(focus: tableFocus))
            .onChange(of: selection) {
                if !selection.isEmpty { tableFocus.focusTable() }
                selectionFeed.announce()
            }
            // The table's own menu, not each row's: a row's menu was built on every mouse-down to
            // find out whether the row wanted the click (#689).
            .modifier(TrackListRowActionsModifier(tracks: tracks, actions: rowActions))
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
                clearPendingScrollRestore()
            }
        }
    }

    /// What a double-click on a selected row does: plays (or pauses) the first selected song.
    private var doubleClickAction: (() -> Void)? {
        guard let rowActions else { return nil }
        let tracks = tracks
        let selectionFeed = selectionFeed
        return {
            guard let first = tracks.first(where: { selectionFeed.isSelected($0.id) }) else { return }
            rowActions.activate(first)
        }
    }

    private func setRowRealized(_ isRealized: Bool, track: TrackRowViewModel) {
        if isRealized {
            realizedRows.trackIDs.insert(track.id)
            prepareMenu(of: track)
        } else {
            realizedRows.trackIDs.remove(track.id)
        }
        reportFirstVisibleTrack()
    }

    /// Hands rows that came on screen to ``TrackListRowActions/prepareMenus``, all of one turn of
    /// the run loop at once.
    private func prepareMenu(of track: TrackRowViewModel) {
        guard let prepare = rowActions?.prepareMenus else { return }
        let realizedRows = realizedRows
        realizedRows.rowsAwaitingMenus.append(track)
        guard !realizedRows.isPreparingMenus else { return }
        realizedRows.isPreparingMenus = true
        DispatchQueue.main.async {
            realizedRows.isPreparingMenus = false
            let rows = realizedRows.rowsAwaitingMenus
            realizedRows.rowsAwaitingMenus = []
            prepare(rows)
        }
    }

    private func reportFirstVisibleTrack() {
        guard let id = TrackListVisibility.firstVisibleTrackID(realized: realizedRows.trackIDs, positions: realizedRows.positionByTrackID),
              id != realizedRows.lastReportedFirstVisibleTrackID
        else { return }
        realizedRows.lastReportedFirstVisibleTrackID = id
        onFirstVisibleTrackChanged(id)
    }
}

/// Gives the table of a ``TrackListView`` the keyboard (#628, #689), and its double-click.
@MainActor
final class TrackListTableFocus {
    private weak var probe: NSView?
    private weak var table: NSTableView?
    /// Runs on a double-click on a selected row.
    var onDoubleClick: (() -> Void)?
    private var monitor: Any?
    /// The mouse-down last taken for a double-click. AppKit can hand a held-back mouse-down to
    /// the monitor a second time, and a second run would pause what the first one played.
    private var lastDoubleClick: TimeInterval?

    /// Makes the list's table the first responder unless it already is.
    func focusTable() {
        guard let window = probe?.window else { return }
        if let table, table.window === window {
            if window.firstResponder !== table { window.makeFirstResponder(table) }
            return
        }
        guard let found = findTable() else { return }
        table = found
        if window.firstResponder !== found { window.makeFirstResponder(found) }
    }

    /// Watches the window's mouse-downs for a double-click on the table, and leaves each one to
    /// the table as it is.
    func watchDoubleClicks() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.handleMouseDown(event)
            return event
        }
    }

    func stopWatchingDoubleClicks() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard event.clickCount == 2,
              event.modifierFlags.isDisjoint(with: [.command, .shift]),
              let onDoubleClick,
              let window = probe?.window, event.window === window,
              event.timestamp != lastDoubleClick
        else { return }
        if table?.window !== window { table = findTable() }
        guard let table else { return }
        let point = table.convert(event.locationInWindow, from: nil)
        let row = table.row(at: point)
        // The first click of the two selected the row; the list's header and footer can't be.
        guard row >= 0, table.visibleRect.contains(point), table.selectedRowIndexes.contains(row) else { return }
        lastDoubleClick = event.timestamp
        onDoubleClick()
    }

    /// The list's table: the nearest one around the probe (the list's background) whose scroll
    /// view covers the probe's middle. The sidebar's list is a table too, further away.
    private func findTable() -> NSTableView? {
        guard let probe else { return nil }
        let frame = probe.convert(probe.bounds, to: nil)
        let middle = NSPoint(x: frame.midX, y: frame.midY)
        var ancestor = probe.superview
        while let current = ancestor {
            var stack: [NSView] = [current]
            while let view = stack.popLast() {
                if let table = view as? NSTableView, let scroll = table.enclosingScrollView,
                   scroll.convert(scroll.bounds, to: nil).contains(middle) {
                    return table
                }
                stack.append(contentsOf: view.subviews)
            }
            ancestor = current.superview
        }
        return nil
    }

    /// An empty view behind the list, so the list's table can be found from it.
    struct Probe: NSViewRepresentable {
        let focus: TrackListTableFocus

        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            focus.probe = view
            focus.watchDoubleClicks()
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            focus.probe = nsView
        }

        func makeCoordinator() -> TrackListTableFocus {
            focus
        }

        static func dismantleNSView(_ nsView: NSView, coordinator: TrackListTableFocus) {
            coordinator.stopWatchingDoubleClicks()
        }
    }
}

/// Ids of the rows the table currently has realized. A table only realizes what
/// it draws, so this stays about a viewport deep however long the playlist is.
/// Kept by id, not row number: a row dragged to a new spot keeps its identity and
/// doesn't appear again, so a number recorded for it would go stale (#543).
@MainActor
final class TrackListRealizedRows {
    var trackIDs: Set<String> = []
    /// Rows come on screen whose menus haven't been prepared yet, handed over together.
    var rowsAwaitingMenus: [TrackRowViewModel] = []
    var isPreparingMenus = false
    /// Each row's place in the list, built again when the rows change.
    var positionByTrackID: [String: Int] = [:]
    var lastReportedFirstVisibleTrackID: String?

    /// A counter that moves on when the list's rows change, so a row can tell they did without
    /// comparing all of them.
    private var tracksGeneration = 0
    private var lastTracks: [TrackRowViewModel] = []

    /// The counter for `tracks`, moved on if they are new.
    func generation(of tracks: [TrackRowViewModel]) -> Int {
        if tracks != lastTracks {
            lastTracks = tracks
            tracksGeneration &+= 1
        }
        return tracksGeneration
    }
}

/// The selection of a ``TrackListView`` as its rows read it (#689). Each row listens for its own
/// part, so a click builds again the row it selects and the one it leaves. Handed to the rows
/// through the list's own view, every click built the list of all rows again, and the table then
/// went through all 2,000 of them.
@MainActor
final class TrackListSelectionFeed {
    private(set) var ids: Set<String> = []
    private let changes = PassthroughSubject<Set<String>, Never>()

    /// Keeps the selection the list was built with, so a row built now reads it.
    func store(_ selection: Set<String>) {
        ids = selection
    }

    /// Tells the rows built earlier that the selection changed.
    func announce() {
        changes.send(ids)
    }

    func isSelected(_ id: String) -> Bool {
        ids.contains(id)
    }

    func selectedChanges(of id: String) -> AnyPublisher<Bool, Never> {
        changes.map { $0.contains(id) }.eraseToAnyPublisher()
    }
}

/// What double-clicking a row of a ``TrackListView`` and its right-click menu do (#689). The table
/// handles both for all of its rows.
struct TrackListRowActions {
    /// Whether the row plays, pauses or can't play: the menu's first item and the double-click.
    let invocation: (TrackRowViewModel) -> TrackRowPlaybackInvocation
    let playURI: (String) -> Void
    let togglePlayPause: () -> Void
    /// The rest of the menu, for the rows it acts on in list order: the selection when the
    /// right-click was on a selected row, else that row.
    let menuItems: ([TrackRowViewModel]) -> AnyView
    /// Fetches what the menu of these rows shows that comes from the network, such as whether
    /// a song is in Liked Songs. Called as rows come on screen: a menu is built when it opens,
    /// and an answer that arrives after that doesn't reach the open menu (#689).
    var prepareMenus: (@MainActor ([TrackRowViewModel]) -> Void)? = nil

    func activate(_ track: TrackRowViewModel) {
        TrackListRow.perform(invocation(track), playURI: playURI, togglePlayPause: togglePlayPause)
    }
}

/// Puts ``TrackListRowActions`` on the table.
private struct TrackListRowActionsModifier: ViewModifier {
    let tracks: [TrackRowViewModel]
    let actions: TrackListRowActions?

    func body(content: Content) -> some View {
        if let actions {
            content.contextMenu(forSelectionType: String.self) { ids in
                menu(for: ids, actions: actions)
            }
        } else {
            content
        }
    }

    @ViewBuilder
    private func menu(for ids: Set<String>, actions: TrackListRowActions) -> some View {
        let targets = tracks.filter { ids.contains($0.id) }
        if let first = targets.first {
            TrackRowMenuContent(invocation: actions.invocation(first), activate: { actions.activate(first) }) {
                actions.menuItems(targets)
            }
        }
    }
}

/// The track rows of ``TrackListView``. Built again only when the rows or the list's
/// ``TrackListView/rowContentKey`` changed, and then each row only when its own
/// ``TrackListRowKey`` did (#655). A change of the selection doesn't build them again (#689).
private struct TrackListRows<Row: View>: View, Equatable {
    let tracks: [TrackRowViewModel]
    let tracksGeneration: Int
    let selectionFeed: TrackListSelectionFeed
    let rowContentKey: AnyHashable?
    let rowBuilder: (TrackRowViewModel, Bool) -> Row
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
                PlaybackValueReader(
                    value: { selectionFeed.isSelected(track.id) },
                    changes: selectionFeed.selectedChanges(of: track.id)
                ) { isSelected in
                    TrackListRowSlot(
                        key: TrackListRowKey(trackID: track.id, isSelected: isSelected, tracks: tracksGeneration, list: rowContentKey),
                        track: track,
                        content: rowBuilder
                    )
                    .equatable()
                }
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

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rowContentKey != nil
            && lhs.rowContentKey == rhs.rowContentKey
            && lhs.tracksGeneration == rhs.tracksGeneration
            && (lhs.moveRows == nil) == (rhs.moveRows == nil)
    }
}

/// What a row of ``TrackListView`` is built from (#655). The row's id stands for its track:
/// within one generation of the list's rows an id always has the same track, and comparing
/// the whole track of every row on each update cost more than the rows it saved.
struct TrackListRowKey: Equatable {
    var trackID: String
    var isSelected: Bool
    var tracks: Int
    var list: AnyHashable?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.trackID == rhs.trackID
            && lhs.isSelected == rhs.isSelected
            && lhs.tracks == rhs.tracks
            && lhs.list == rhs.list
    }
}

/// One row of ``TrackListView``, built again only when its ``TrackListRowKey`` changes. A list
/// without a ``TrackListView/rowContentKey`` builds it every time.
private struct TrackListRowSlot<Row: View>: View, Equatable {
    let key: TrackListRowKey
    let track: TrackRowViewModel
    let content: (TrackRowViewModel, Bool) -> Row

    var body: some View {
        content(track, key.isSelected)
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
