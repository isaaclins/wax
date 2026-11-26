import AppKit
import Combine
import SwiftUI

/// Hosts the lyrics surface in an AppKit responder parent. This keeps the overlay
/// owner in the focused responder's chain even when a SwiftUI child button or
/// scroll view takes keyboard focus.
struct LyricsOverlayFocusContainer<Content: View>: NSViewRepresentable {
    let content: Content
    let isActive: Bool
    let keymapStore: CommandPaletteKeymapStore?
    let keyboardFocus: LyricsKeyboardFocusProbe?

    init(
        content: Content,
        isActive: Bool,
        keymapStore: CommandPaletteKeymapStore? = nil,
        keyboardFocus: LyricsKeyboardFocusProbe? = nil
    ) {
        self.content = content
        self.isActive = isActive
        self.keymapStore = keymapStore
        self.keyboardFocus = keyboardFocus
    }

    func makeNSView(context: Context) -> LyricsOverlayFocusContainerView<Content> {
        let view = LyricsOverlayFocusContainerView(
            content: content,
            isActive: isActive,
            keymapStore: keymapStore ?? CommandPaletteKeymapStore()
        )
        keyboardFocus?.container = view
        return view
    }

    func updateNSView(_ nsView: LyricsOverlayFocusContainerView<Content>, context: Context) {
        nsView.updateContent(content)
        nsView.setActive(isActive)
    }

    static func dismantleNSView(
        _ nsView: LyricsOverlayFocusContainerView<Content>,
        coordinator: Coordinator
    ) {
        nsView.deactivate()
    }
}

private enum LyricsOverlayGlobalCommands {
    static let commandIDs: Set<String> = [
        CommandPaletteCommandID.toggleLyrics,
        CommandPaletteCommandID.popOutLyrics,
        CommandPaletteCommandID.togglePlayback,
        CommandPaletteCommandID.nextTrack,
        CommandPaletteCommandID.previousTrack,
        CommandPaletteCommandID.toggleQueue,
        CommandPaletteCommandID.toggleSidebar,
        CommandPaletteCommandID.openPalette,
        CommandPaletteCommandID.openSettings,
        // Switching service is app-wide (`.always`) and clears the lyrics on its way (#399).
        CommandPaletteCommandID.switchToAppleMusic,
        CommandPaletteCommandID.switchToSpotify,
    ]
}

/// Tells the lyrics whether the user moved the keyboard out of them, so focus placed once the
/// lyrics finish loading doesn't pull it back from the sidebar or the queue (#438).
@MainActor
final class LyricsKeyboardFocusProbe {
    weak var container: (any LyricsKeyboardFocusOwner)?

    var userMovedFocusAway: Bool {
        container?.keyboardFocusMovedAway ?? false
    }
}

@MainActor
protocol LyricsKeyboardFocusOwner: AnyObject {
    var keyboardFocusMovedAway: Bool { get }
}

private struct LyricsKeyboardFocusKey: EnvironmentKey {
    static var defaultValue: LyricsKeyboardFocusProbe? { nil }
}

extension EnvironmentValues {
    var lyricsKeyboardFocus: LyricsKeyboardFocusProbe? {
        get { self[LyricsKeyboardFocusKey.self] }
        set { self[LyricsKeyboardFocusKey.self] = newValue }
    }
}

/// Owns the keyboard focus while the lyrics overlay is presented and returns it
/// to the responder that was focused before the presentation opened.
@MainActor
final class LyricsOverlayFocusContainerView<Content: View>: NSView, FocusedKeyEventOwner, LyricsKeyboardFocusOwner {
    private let hostingView: NSHostingView<Content>
    private let keymapStore: CommandPaletteKeymapStore
    private var overlayIsActive: Bool
    private var capturedPreviousResponder = false
    private weak var previousWindow: NSWindow?
    private var previousResponder: NSResponder?
    private var focusRequestScheduled = false
    /// Set once the keyboard is in the lyrics, so a later move elsewhere reads as the user's.
    private var didHoldKeyboardFocus = false
    private var isHideScheduled = false

    init(content: Content, isActive: Bool, keymapStore: CommandPaletteKeymapStore) {
        hostingView = NSHostingView(rootView: content)
        self.keymapStore = keymapStore
        overlayIsActive = isActive
        super.init(frame: .zero)
        isHidden = !isActive

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    convenience init(content: Content, isActive: Bool) {
        self.init(
            content: content,
            isActive: isActive,
            keymapStore: CommandPaletteKeymapStore()
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    func updateContent(_ content: Content) {
        hostingView.rootView = content
    }

    func setActive(_ active: Bool) {
        if active { isHidden = false } else { hideOnceFadedOut() }
        guard overlayIsActive != active else { return }
        overlayIsActive = active
        if active {
            capturePreviousResponderIfNeeded()
            requestFocusIfNeeded()
        } else {
            restorePreviousFocus()
        }
    }

    /// Closed, the container stays in the window (#674) but hidden, so it takes no clicks, keys
    /// or VoiceOver; after the lyrics' fade, which plays inside it.
    private func hideOnceFadedOut() {
        guard !isHidden, !isHideScheduled else { return }
        isHideScheduled = true
        let timer = Timer(timeInterval: Self.fadeOutSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isHideScheduled = false
                guard !self.overlayIsActive else { return }
                self.isHidden = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private static var fadeOutSeconds: TimeInterval { 0.3 }

    func deactivate() {
        guard overlayIsActive || capturedPreviousResponder else { return }
        overlayIsActive = false
        restorePreviousFocus()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard overlayIsActive else { return }
        capturePreviousResponderIfNeeded()
        requestFocusIfNeeded()
    }

    override func removeFromSuperview() {
        deactivate()
        super.removeFromSuperview()
    }

    /// Escape remains available to ``CommandPaletteManager``'s existing lyrics
    /// dismissal hook. Transport and global commands also stay with the app-wide
    /// keymap; only events with no matching command remain in the overlay chain.
    func ownsKeyEvent(_ event: NSEvent) -> Bool {
        guard overlayIsActive, event.keyCode != 53 else { return false }
        return !matchesGlobalCommandBinding(event)
    }

    /// The local monitor has yielded to this focused owner, so other keys stop here. Tab and
    /// Shift-Tab move on to the sidebar, the queue and the player bar, which stay usable next
    /// to the lyrics (#438); without a lyrics list (loading, instrumental, no lyrics) this
    /// container is all that has the keyboard.
    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 48, let window else { return }
        if event.modifierFlags.contains(.shift) {
            window.selectPreviousKeyView(self)
        } else {
            window.selectNextKeyView(self)
        }
    }

    /// AppKit offers key equivalents to every view in the window, not only the focused one,
    /// and before the menu bar. The lyrics only claim plain keys, and only while the keyboard
    /// is in them: with focus in the sidebar or the queue, shortcuts work as on every other
    /// screen, and ⌘ shortcuts always reach the menu bar, so Repeat (⌥⌘R, now only in the
    /// player bar), Shuffle and seeking work with the lyrics open (#438). Menu commands that
    /// act on the page under the lyrics are dimmed while they are open.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard hasKeyboardFocus,
            !event.modifierFlags.contains(.command),
            ownsKeyEvent(event)
        else {
            return super.performKeyEquivalent(with: event)
        }
        return true
    }

    /// Whether the keyboard is in the lyrics: this container or a view inside it.
    var hasKeyboardFocus: Bool {
        guard let window else { return false }
        return isInResponderChain(window.firstResponder)
    }

    var keyboardFocusMovedAway: Bool {
        if hasKeyboardFocus { didHoldKeyboardFocus = true }
        return didHoldKeyboardFocus && !hasKeyboardFocus
    }

    private func matchesGlobalCommandBinding(_ event: NSEvent) -> Bool {
        if CommandPaletteSidebarShortcut.isSystemChord(event) { return true }
        return keymapStore
            .commandBindings(for: event, context: .signedIn)
            .contains { LyricsOverlayGlobalCommands.commandIDs.contains($0.command) }
    }

    private func capturePreviousResponderIfNeeded() {
        guard !capturedPreviousResponder, let window else { return }
        capturedPreviousResponder = true
        previousWindow = window
        guard let responder = window.firstResponder, !isInResponderChain(responder) else { return }
        previousResponder = responder
    }

    private func requestFocusIfNeeded() {
        guard overlayIsActive,
            let window,
            !isInResponderChain(window.firstResponder),
            !focusRequestScheduled
        else { return }

        // Right after the frame that shows the lyrics, not in it: moving the keyboard updates the
        // focus of every view in the window, and that held back the lyrics' first frame (#674).
        focusRequestScheduled = true
        AfterThisFrame.run { [weak self, weak window] in
            guard let self else { return }
            self.focusRequestScheduled = false
            guard self.overlayIsActive,
                let window,
                self.window === window,
                !self.isInResponderChain(window.firstResponder)
            else { return }
            if window.makeFirstResponder(self) {
                self.didHoldKeyboardFocus = true
                return
            }
            // SwiftUI can leave the old responder in place until the next run-loop turn.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, self.overlayIsActive, let window, self.window === window,
                    !self.isInResponderChain(window.firstResponder)
                else { return }
                if window.makeFirstResponder(self) { self.didHoldKeyboardFocus = true }
            }
        }
    }

    private func restorePreviousFocus() {
        let window = previousWindow
        let responder = previousResponder
        previousWindow = nil
        previousResponder = nil
        capturedPreviousResponder = false
        didHoldKeyboardFocus = false

        guard let window else { return }
        // The sidebar, the queue and the player bar stay usable next to the lyrics (#438). When
        // the keyboard already moved there (a click on a sidebar row that also closed the
        // lyrics, Escape from the queue), it stays where the user put it.
        if let current = window.firstResponder, current !== window, !isInResponderChain(current) {
            return
        }
        if let responder, responder !== self, isResponderInWindow(responder, window) {
            _ = window.makeFirstResponder(responder)
        } else {
            _ = window.makeFirstResponder(nil)
        }
    }

    private func isResponderInWindow(_ responder: NSResponder, _ window: NSWindow) -> Bool {
        if let view = responder as? NSView {
            return view.window === window
        }
        var current: NSResponder? = responder
        var visited = Set<ObjectIdentifier>()
        while let candidate = current {
            guard visited.insert(ObjectIdentifier(candidate)).inserted else { break }
            if candidate === window { return true }
            current = candidate.nextResponder
        }
        return false
    }

    private func isInResponderChain(_ responder: NSResponder?) -> Bool {
        var current = responder
        var visited = Set<ObjectIdentifier>()
        while let candidate = current {
            guard visited.insert(ObjectIdentifier(candidate)).inserted else { break }
            if candidate === self { return true }
            current = candidate.nextResponder
        }
        return false
    }
}

/// Whether the lyrics are open, published on its own: only what looks different with them open
/// observes it. When the whole browser observed it, each ⌥⌘L ran the browser's body again, with
/// the sidebar, the page under the lyrics and every song row on screen, about 140 ms where the
/// budget is 50 ms (#674).
@MainActor
final class LyricsPresentationState: ObservableObject {
    @Published fileprivate(set) var isPresented = false
}

/// Runs `work` once, right after Core Animation commits the frame being built now, or when the
/// run loop it was set up in exits first (a menu's tracking loop, say).
@MainActor
enum AfterThisFrame {
    static func run(_ work: @escaping @MainActor () -> Void) {
        // Core Animation commits at `beforeWaiting` with order 2,000,000; this one comes after.
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue,
            false,
            2_000_002
        ) { _, _ in
            MainActor.assumeIsolated { work() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}

/// Owns immersive lyrics presentation and holds references to the main-window playback session
/// so ``ImmersiveLyricsView`` can be hosted above ``NavigationSplitView`` (full-window compositing).
/// It publishes nothing itself, so the browser that holds it doesn't render again when the lyrics
/// open or close (#674); ``presentation`` is what to observe.
@MainActor
final class LyricsOverlayController: ObservableObject {
    /// Builds the lyrics, hidden, a second after the window shows, so even the first ⌥⌘L only
    /// shows them (#674). The app's window turns it on; a controller made without it builds them
    /// on the first open, which is all a view test that never opens them needs.
    let buildsLyricsAhead: Bool

    init(buildsLyricsAhead: Bool = false) {
        self.buildsLyricsAhead = buildsLyricsAhead
    }

    /// The lyrics themselves and the page under them: they change in the frame that answers ⌥⌘L.
    let presentation = LyricsPresentationState()
    /// What frames them (the toolbar's items, the window's name, the player bar's Lyrics buttons,
    /// the menus) follows one frame later. Swapping the toolbar's items alone took 16-18 ms, the
    /// menus and the bar another 12, and none of it is what you look at when the lyrics open, so
    /// it no longer holds back their first frame (#674).
    let chromePresentation = LyricsPresentationState()
    private var isChromeUpdateScheduled = false

    /// Opening and closing animate: the lyrics fade in while the page under them fades out.
    var isPresented: Bool {
        get { presentation.isPresented }
        set {
            guard newValue != presentation.isPresented else { return }
            withAnimation(.easeOut(duration: 0.22)) { presentation.isPresented = newValue }
            scheduleChromeUpdate()
        }
    }

    private func scheduleChromeUpdate() {
        guard !isChromeUpdateScheduled else { return }
        isChromeUpdateScheduled = true
        AfterThisFrame.run { [weak self] in
            guard let self else { return }
            isChromeUpdateScheduled = false
            let presented = presentation.isPresented
            guard chromePresentation.isPresented != presented else { return }
            withAnimation(.easeOut(duration: 0.22)) { self.chromePresentation.isPresented = presented }
        }
    }

    private(set) var playbackViewModel: PlaybackSessionViewModel?
    private(set) var queueViewModel: QueueViewModel?
    private(set) var lyricsModel: ImmersiveLyricsViewModel?
    private(set) var navigateToArtist: ((ArtistTapTarget) -> Void)?
    private(set) var navigateToAlbum: ((AlbumTapTarget, String, URL?) -> Void)?

    func attach(
        playback: PlaybackSessionViewModel,
        queue: QueueViewModel,
        lyrics: ImmersiveLyricsViewModel,
        navigateToArtist: @escaping (ArtistTapTarget) -> Void,
        navigateToAlbum: @escaping (AlbumTapTarget, String, URL?) -> Void
    ) {
        playbackViewModel = playback
        queueViewModel = queue
        lyricsModel = lyrics
        self.navigateToArtist = navigateToArtist
        self.navigateToAlbum = navigateToAlbum
    }

    func detach() {
        isPresented = false
        playbackViewModel = nil
        queueViewModel = nil
        lyricsModel = nil
        navigateToArtist = nil
        navigateToAlbum = nil
    }

    /// Every page change closes the lyrics, mostly while they are closed already. Setting the
    /// same value again still re-rendered the window and rebuilt the menus, which made ⌘F to
    /// Search the slowest page change (#675), so only a real change is published.
    func dismiss() {
        if isPresented { isPresented = false }
    }

    /// Opens the lyrics only when there is a song to show them for: the one in the player bar,
    /// whichever service is on screen (#486).
    func setPresented(_ presented: Bool) {
        guard !presented || hasLyricsToShow, isPresented != presented else { return }
        isPresented = presented
    }

    /// What the bar's Lyrics button and View › Show Lyrics toggle.
    var presentedBinding: Binding<Bool> {
        Binding(
            get: { self.isPresented },
            set: { self.setPresented($0) }
        )
    }

    var hasLyricsToShow: Bool {
        guard let playbackViewModel else { return false }
        return playbackViewModel.audiblePlayer.currentLyricTrack != nil
    }
}

/// Renders ``ImmersiveLyricsView`` in the browser's main column, in place of the page that was
/// showing. The sidebar, the queue panel and the player bar stay where they are on every other
/// screen (#438); the backdrop runs up under the toolbar so the bar reads as part of the lyrics.
struct LyricsOverlayLayer: View {
    let lyricsOverlay: LyricsOverlayController
    @ObservedObject private var presentation: LyricsPresentationState
    let keymapStore: CommandPaletteKeymapStore
    @EnvironmentObject private var settingsStore: SpotiglassSettingsStore
    @State private var keyboardFocus = LyricsKeyboardFocusProbe()
    /// Set a moment after the window shows (or when the lyrics first open, if sooner); from
    /// then on the lyrics stay built, so even the first ⌥⌘L only shows them (#674).
    @State private var isBuilt = false
    /// How much of the column's bottom the player bar covers. The lyrics run behind the bar
    /// (#474), and the column doesn't get the bar's safe area (the split view hosts it), so
    /// the browser measures the bar and hands its height in.
    let playerBarInset: CGFloat

    init(lyricsOverlay: LyricsOverlayController, keymapStore: CommandPaletteKeymapStore, playerBarInset: CGFloat = 0) {
        self.lyricsOverlay = lyricsOverlay
        _presentation = ObservedObject(wrappedValue: lyricsOverlay.presentation)
        self.keymapStore = keymapStore
        self.playerBarInset = playerBarInset
    }

    private static let buildDelay = Duration.seconds(1)

    /// Avoid blocking the column when `isPresented` is true before the browser has called `attach` (nil models).
    private var immersiveLyricsReady: Bool {
        presentation.isPresented && lyricsOverlay.lyricsModel != nil
    }

    var body: some View {
        ZStack {
            // The container, its hosting view and the lyrics in it are built once, closed, and
            // stay: building them on ⌥⌘L held back the lyrics' first frame (#674). Closed, the
            // lyrics are paused and the container is hidden, so it takes no clicks, keys or
            // VoiceOver.
            if isBuilt || presentation.isPresented,
                let playback = lyricsOverlay.playbackViewModel,
                let queue = lyricsOverlay.queueViewModel,
                let lyrics = lyricsOverlay.lyricsModel,
                let navigateArtist = lyricsOverlay.navigateToArtist,
                let navigateAlbum = lyricsOverlay.navigateToAlbum
            {
                LyricsOverlayFocusContainer(
                    content: LyricsOverlayContent(
                        isShowing: immersiveLyricsReady,
                        onScreenPlayer: playback,
                        queueViewModel: queue,
                        lyricsModel: lyrics,
                        navigateToArtist: navigateArtist,
                        navigateToAlbum: navigateAlbum,
                        onDismiss: { lyricsOverlay.dismiss() }
                    )
                    .environmentObject(settingsStore)
                    .environment(\.locale, settingsStore.appLocale)
                    .environment(\.spotiglassLocale, settingsStore.appLocale)
                    .environment(\.lyricsKeyboardFocus, keyboardFocus)
                    .safeAreaPadding(.bottom, playerBarInset),
                    isActive: immersiveLyricsReady,
                    keymapStore: keymapStore,
                    keyboardFocus: keyboardFocus
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The lines scroll unclipped for the edge fade; without this they would draw past the
        // column's edges (#438). The column runs behind the player bar, so the backdrop reaches
        // the window's bottom edge and the lines fade out above the bar (#474).
        .clipped()
        .ignoresSafeArea(.container, edges: .top)
        .allowsHitTesting(immersiveLyricsReady)
        .onChange(of: presentation.isPresented) { _, presented in
            if presented, !isBuilt { isBuilt = true }
        }
        // Built a moment after the window shows rather than with it, so the window's own first
        // frame doesn't wait for lyrics nobody asked for yet.
        .task {
            guard lyricsOverlay.buildsLyricsAhead else { return }
            // try?: it only throws when cancelled, because the layer left the window.
            try? await Task.sleep(for: Self.buildDelay)
            if !Task.isCancelled, !isBuilt { isBuilt = true }
        }
    }
}

/// What the lyrics' hosting view shows. Once built, the lyrics stay built: closed, they are
/// invisible and paused (``EnvironmentValues/lyricsAreShowing``), and opening only shows them
/// again. Building them, every line, their text and the views inside, was most of the lyrics'
/// first frame, 50-70 ms where the budget is 50 (#674). The hosting view has its own view
/// graph, so the fade is set here rather than taken from the change that opened them.
struct LyricsOverlayContent: View {
    let isShowing: Bool
    let onScreenPlayer: PlaybackSessionViewModel
    let queueViewModel: QueueViewModel
    let lyricsModel: ImmersiveLyricsViewModel
    let navigateToArtist: (ArtistTapTarget) -> Void
    let navigateToAlbum: (AlbumTapTarget, String, URL?) -> Void
    let onDismiss: () -> Void

    var body: some View {
        LyricsOverlayPlayerResolver(
            onScreenPlayer: onScreenPlayer,
            queueViewModel: queueViewModel,
            lyricsModel: lyricsModel,
            navigateToArtist: navigateToArtist,
            navigateToAlbum: navigateToAlbum,
            onDismiss: onDismiss
        )
        .environment(\.lyricsAreShowing, isShowing)
        .allowsHitTesting(isShowing)
        .accessibilityHidden(!isShowing)
        .animation(.easeOut(duration: 0.22)) { lyrics in
            lyrics
                .opacity(isShowing ? 1 : 0)
                .scaleEffect(isShowing ? 1 : 0.98)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shows the lyrics of the song in the player bar (``PlaybackSessionViewModel/audiblePlayer``,
/// #486): the on-screen player, or the other service's while its music is the one you hear,
/// playing or paused. The bar, View › Show Lyrics and the pop-out window follow the same player.
struct LyricsOverlayPlayerResolver: View {
    @ObservedObject var onScreenPlayer: PlaybackSessionViewModel
    let queueViewModel: QueueViewModel
    let lyricsModel: ImmersiveLyricsViewModel
    let navigateToArtist: (ArtistTapTarget) -> Void
    let navigateToAlbum: (AlbumTapTarget, String, URL?) -> Void
    let onDismiss: () -> Void

    var body: some View {
        let player = onScreenPlayer.audiblePlayer
        ImmersiveLyricsView(
            playbackViewModel: player,
            queueViewModel: queueViewModel,
            lyricsModel: lyricsModel,
            navigateToArtist: navigateToArtist,
            navigateToAlbum: navigateToAlbum,
            onDismiss: onDismiss,
            followsOtherService: player !== onScreenPlayer
        )
        .id(ObjectIdentifier(player))
    }
}
