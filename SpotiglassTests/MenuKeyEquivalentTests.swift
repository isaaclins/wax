import AppKit
import SwiftUI
import XCTest
@testable import Spotiglass

@MainActor
final class MenuKeyEquivalentTests: XCTestCase {
    private func makeStore() -> CommandPaletteKeymapStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpotiglassMenuKeyEquivalent-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
        return CommandPaletteKeymapStore(fileURL: url)
    }

    private func makeSettingsStore() -> SpotiglassSettingsStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpotiglassMenuLocalization-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
        return SpotiglassSettingsStore(fileURL: url)
    }

    private func makeCommands(manager: CommandPaletteManager) -> SpotiglassMenuCommands {
        let scene = SpotiglassSceneHost(commandPaletteManager: manager)
        let registry = SpotiglassSceneRegistry()
        registry.activate(scene)
        return SpotiglassMenuCommands(
            sceneRegistry: registry,
            keymapStore: manager.keymapStore,
            settingsStore: makeSettingsStore(),
            serviceStore: MusicServiceStore(
                storage: InMemoryMusicServiceSelectionStorage(services: [.spotify], active: .spotify)
            ),
            isSignedIn: true
        )
    }

    func testModifierBearingChordBecomesMenuKeyEquivalent() throws {
        let shortcut = try XCTUnwrap(try CommandShortcut(keystroke: "shift-cmd-right").menuKeyboardShortcut)

        XCTAssertEqual(shortcut.key.character, KeyEquivalent.rightArrow.character)
        XCTAssertEqual(shortcut.modifiers, [.command, .shift])
    }

    /// A menu key equivalent is matched before the key reaches the focused view,
    /// so the bare Space binding for Play/Pause must never reach the menu bar.
    func testBareAndShiftOnlyChordsAreRefusedAsMenuKeyEquivalents() throws {
        XCTAssertNil(try CommandShortcut(keystroke: "space").menuKeyboardShortcut)
        XCTAssertNil(try CommandShortcut(keystroke: "shift-return").menuKeyboardShortcut)
        XCTAssertNotNil(try CommandShortcut(keystroke: "ctrl-space").menuKeyboardShortcut)
        XCTAssertNotNil(try CommandShortcut(keystroke: "alt-cmd-q").menuKeyboardShortcut)
    }

    func testDefaultKeymapDrivesTheMenuBarShortcuts() throws {
        let store = makeStore()

        let next = try XCTUnwrap(store.menuShortcut(for: CommandPaletteCommandID.nextTrack))
        XCTAssertEqual(next.key.character, KeyEquivalent.rightArrow.character)
        XCTAssertEqual(next.modifiers, [.command, .shift])

        let queue = try XCTUnwrap(store.menuShortcut(for: CommandPaletteCommandID.toggleQueue))
        XCTAssertEqual(queue.key.character, "q")
        XCTAssertEqual(queue.modifiers, [.command, .option])

        let lyrics = try XCTUnwrap(store.menuShortcut(for: CommandPaletteCommandID.toggleLyrics))
        XCTAssertEqual(lyrics.key.character, "l")
        XCTAssertEqual(lyrics.modifiers, [.command, .option])

        XCTAssertNil(store.menuShortcut(for: CommandPaletteCommandID.togglePlayback))
        XCTAssertNil(store.menuShortcut(for: CommandPaletteCommandID.toggleShuffle))
    }

    /// Rebinding a command in Settings → Keyboard has to move its menu shortcut,
    /// otherwise the menu bar would keep firing the abandoned chord.
    func testRebindingACommandMovesItsMenuShortcut() throws {
        let store = makeStore()
        try store.setBinding(
            commandID: CommandPaletteCommandID.nextTrack,
            shortcut: try CommandShortcut(keystroke: "ctrl-alt-n"),
            replaceConflicting: true
        )

        let rebound = try XCTUnwrap(store.menuShortcut(for: CommandPaletteCommandID.nextTrack))
        XCTAssertEqual(rebound.key.character, "n")
        XCTAssertEqual(rebound.modifiers, [.control, .option])
    }

    func testClearingABindingRemovesTheMenuShortcut() throws {
        let store = makeStore()
        try store.clearBinding(commandID: CommandPaletteCommandID.toggleQueue)

        XCTAssertNil(store.menuShortcut(for: CommandPaletteCommandID.toggleQueue))
    }

    /// The menu bar dispatches through the same manager the palette and the keymap
    /// use, so shuffle and repeat must land on the wired playback closures.
    func testMenuOnlyShuffleAndRepeatDispatchThroughTheManager() {
        let manager = CommandPaletteManager(keymapStore: makeStore())
        var shuffled = 0
        var repeated = 0
        // The closures end the wait themselves, so it ends because they ran.
        let shuffleRan = expectation(description: "the shuffle closure ran")
        let repeatRan = expectation(description: "the repeat closure ran")
        manager.toggleShuffle = {
            shuffled += 1
            shuffleRan.fulfill()
        }
        manager.cycleRepeat = {
            repeated += 1
            repeatRan.fulfill()
        }
        manager.playbackTransportMutationPrerequisite = { true }
        manager.repeatMutationPrerequisite = { true }

        manager.execute(commandID: CommandPaletteCommandID.toggleShuffle)
        manager.execute(commandID: CommandPaletteCommandID.cycleRepeat)

        wait(for: [shuffleRan, repeatRan], timeout: mustHappenTimeout)

        XCTAssertEqual(shuffled, 1)
        XCTAssertEqual(repeated, 1)
    }

    func testMenuKeyEquivalentsAreUniqueAcrossMenuTree() throws {
        AppKitTestSupport.activateAppIfNeeded()
        // The app sets up its menus and AppKit hands it the Services menu on a later turn of the
        // run loop: wait for both, however late that is.
        XCTAssertTrue(AppKitTestSupport.pumpRunLoop(until: { NSApp.mainMenu != nil && NSApp.servicesMenu != nil }))
        let menu = try XCTUnwrap(NSApp.mainMenu)
        XCTAssertNotNil(
            NSApp.servicesMenu,
            "The Services menu must be reachable so its system-injected items can be skipped"
        )
        let keyedItems = menuKeyEquivalentItems(in: menu)
        XCTAssertFalse(keyedItems.isEmpty, "Expected the application menu to expose key equivalents")

        let grouped = Dictionary(grouping: keyedItems) { item in
            "\(item.key.lowercased())|\(item.modifiers.rawValue)"
        }
        let duplicates = grouped.values.filter { $0.count > 1 }
        XCTAssertTrue(
            duplicates.isEmpty,
            "Every menu key equivalent must be unique; duplicates: \(duplicates.map { $0.map(\.path) })"
        )
    }

    func testRepeatCycleCommandAdvancesThroughAllModes() async {
        let manager = CommandPaletteManager(keymapStore: makeStore())
        manager.playbackTransportMutationPrerequisite = { true }
        manager.repeatMutationPrerequisite = { true }
        var mode = MusicRepeatMode.off

        for expectedMode in [MusicRepeatMode.context, .track, .off] {
            let advanced = expectation(description: "repeat advanced to \(expectedMode.rawValue)")
            manager.cycleRepeat = {
                mode = mode.next
                advanced.fulfill()
            }

            manager.execute(commandID: CommandPaletteCommandID.cycleRepeat)
            await fulfillment(of: [advanced], timeout: mustHappenTimeout)
            XCTAssertEqual(mode, expectedMode)
        }
    }

    func testPlaybackMenuUsesEffectiveToggleReadiness() {
        let manager = CommandPaletteManager(keymapStore: makeStore())
        let commands = makeCommands(manager: manager)
        XCTAssertFalse(commands.isPlaybackToggleEnabled)

        manager.setPlaybackToggleAvailability(true)
        XCTAssertTrue(commands.isPlaybackToggleEnabled)
    }

    func testPlaybackMenuMirrorsLiveShuffleAndRepeatState() {
        let manager = CommandPaletteManager(keymapStore: makeStore())
        let playback = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander()))
        manager.bindPlaybackReadiness(to: playback)
        let commands = makeCommands(manager: manager)

        playback.deviceID = "device-1"
        playback.setConnectionState(.ready(deviceID: "device-1"))
        playback.setTransportStateKnown(true)
        playback.shuffleEnabled = true
        playback.repeatMode = .track

        XCTAssertTrue(commands.isShuffleEnabled)
        XCTAssertEqual(commands.selectedRepeatMode, .track)
        XCTAssertTrue(commands.isPlaybackTransportMutationEnabled)
        XCTAssertTrue(commands.isRepeatMutationEnabled, "one service: Repeat follows the same player")
    }

    func testPlaybackMenuCanSelectSpecificRepeatMode() async {
        let manager = CommandPaletteManager(keymapStore: makeStore())
        manager.playbackTransportMutationPrerequisite = { true }
        manager.repeatMutationPrerequisite = { true }
        let selected = expectation(description: "specific repeat mode selected")
        var selectedMode: MusicRepeatMode?
        manager.setRepeatModeAction = { mode in
            selectedMode = mode
            selected.fulfill()
        }

        manager.requestRepeatMode(.track)
        await fulfillment(of: [selected], timeout: mustHappenTimeout)

        XCTAssertEqual(selectedMode, .track)
    }

    func testPrefetchMenuTitleReflectsInFlightState() {
        let manager = CommandPaletteManager(keymapStore: makeStore())
        let commands = makeCommands(manager: manager)

        XCTAssertEqual(commands.prefetchItemTitle, SpotiglassL10n.string("menu.file.loadAllSongs"))
        manager.setPrefetchProgress(
            PrefetchAllPlaylistsProgress(
                phase: .running, total: 4, completed: 1, skipped: 0, failed: 0
            )
        )
        XCTAssertTrue(commands.isPrefetchInFlight)
        XCTAssertEqual(commands.prefetchItemTitle, SpotiglassL10n.string("menu.file.stopLoadingSongs"))

        manager.setPrefetchProgress(
            PrefetchAllPlaylistsProgress(
                phase: .finished, total: 4, completed: 4, skipped: 0, failed: 0
            )
        )
        XCTAssertFalse(commands.isPrefetchInFlight)
        XCTAssertEqual(commands.prefetchItemTitle, SpotiglassL10n.string("menu.file.loadAllSongs"))
    }

    func testPrefetchProgressSurvivesOpeningAndClosingPalette() {
        let manager = CommandPaletteManager(keymapStore: makeStore())
        let progress = PrefetchAllPlaylistsProgress(
            phase: .running, total: 4, completed: 1, skipped: 0, failed: 0
        )
        manager.setPrefetchProgress(progress)

        manager.viewModel.show()
        XCTAssertEqual(manager.prefetchProgress, progress)
        XCTAssertEqual(manager.viewModel.prefetchProgress, progress)
        manager.viewModel.hide()
        XCTAssertEqual(manager.viewModel.prefetchProgress, progress)
    }

    func testLyricsMenuRequiresCurrentMusicTrack() {
        let manager = CommandPaletteManager(keymapStore: makeStore())
        let playback = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander()))
        manager.bindPlaybackReadiness(to: playback)
        let commands = makeCommands(manager: manager)

        XCTAssertFalse(commands.isLyricsToggleEnabled)
        playback.setConnectionState(.playing(
            PlaybackNowPlaying(
                name: "Episode",
                artists: ["Host"],
                albumName: nil,
                albumID: nil,
                albumArtURL: nil,
                durationMilliseconds: 100,
                positionMilliseconds: 0,
                uri: "spotify:episode:1"
            )
        ))
        XCTAssertFalse(commands.isLyricsToggleEnabled)

        playback.setConnectionState(.playing(
            PlaybackNowPlaying(
                name: "Song",
                artists: ["Artist"],
                albumName: nil,
                albumID: nil,
                albumArtURL: nil,
                durationMilliseconds: 100,
                positionMilliseconds: 0,
                uri: "spotify:track:1"
            )
        ))
        XCTAssertTrue(commands.isLyricsToggleEnabled)

        playback.setConnectionState(.ready(deviceID: "device-1"))
        XCTAssertFalse(commands.isLyricsToggleEnabled)
    }

    /// #486: while the lyrics wait for a song that is on its way, the bar has none, and
    /// View › Hide Lyrics (and ⌥⌘L, which goes through the menu) stays enabled.
    func testHideLyricsStaysEnabledWhileTheLyricsShowWithoutASong() {
        let manager = CommandPaletteManager(keymapStore: makeStore())
        let playback = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander()))
        manager.bindPlaybackReadiness(to: playback)
        let scene = SpotiglassSceneHost(commandPaletteManager: manager)
        let registry = SpotiglassSceneRegistry()
        registry.activate(scene)
        let commands = SpotiglassMenuCommands(
            sceneRegistry: registry,
            keymapStore: manager.keymapStore,
            settingsStore: makeSettingsStore(),
            serviceStore: MusicServiceStore(
                storage: InMemoryMusicServiceSelectionStorage(services: [.spotify], active: .spotify)
            ),
            isSignedIn: true
        )

        XCTAssertFalse(commands.isLyricsToggleEnabled, "Show Lyrics with no song in the bar")
        scene.lyricsOverlayController.isPresented = true
        XCTAssertTrue(commands.isLyricsToggleEnabled, "Hide Lyrics is greyed out while the lyrics show")
        scene.lyricsOverlayController.isPresented = false
    }

    /// #438: View › Refresh (⌘R) reloaded the page hidden under the lyrics. It dims while they're open.
    func testRefreshMenuItemDimsWhileLyricsAreOpen() {
        let manager = CommandPaletteManager(keymapStore: makeStore())
        let scene = SpotiglassSceneHost(commandPaletteManager: manager)
        let registry = SpotiglassSceneRegistry()
        registry.activate(scene)
        let commands = SpotiglassMenuCommands(
            sceneRegistry: registry,
            keymapStore: manager.keymapStore,
            settingsStore: makeSettingsStore(),
            serviceStore: MusicServiceStore(
                storage: InMemoryMusicServiceSelectionStorage(services: [.spotify], active: .spotify)
            ),
            isSignedIn: true
        )

        XCTAssertTrue(commands.isRefreshEnabled)
        scene.lyricsOverlayController.isPresented = true
        XCTAssertFalse(commands.isRefreshEnabled, "View › Refresh still reloads the page under the lyrics")
        scene.lyricsOverlayController.isPresented = false
        XCTAssertTrue(commands.isRefreshEnabled)
    }

    /// #438: with the lyrics open, Back (⌘[) and the selection commands (⌥⌘E, ⌥⌘P) acted on
    /// the page under them, which you can't see; the toolbar already hides Back there.
    func testPageCommandsDimWhileLyricsAreOpen() {
        let manager = CommandPaletteManager(keymapStore: makeStore())
        manager.canNavigateBack = true
        manager.canEnqueueTrackSelection = true
        manager.trackSelectionPinState = .pin
        let scene = SpotiglassSceneHost(commandPaletteManager: manager)
        let registry = SpotiglassSceneRegistry()
        registry.activate(scene)
        let commands = SpotiglassMenuCommands(
            sceneRegistry: registry,
            keymapStore: manager.keymapStore,
            settingsStore: makeSettingsStore(),
            serviceStore: MusicServiceStore(
                storage: InMemoryMusicServiceSelectionStorage(services: [.spotify], active: .spotify)
            ),
            isSignedIn: true
        )

        XCTAssertTrue(commands.isBackEnabled)
        XCTAssertTrue(commands.isTrackSelectionEnqueueEnabled)
        XCTAssertTrue(commands.isTrackSelectionPinEnabled)
        scene.lyricsOverlayController.isPresented = true
        XCTAssertFalse(commands.isBackEnabled, "Back still goes back from the page under the lyrics")
        XCTAssertFalse(commands.isTrackSelectionEnqueueEnabled, "Add to Queue still queues rows you can't see")
        XCTAssertFalse(commands.isTrackSelectionPinEnabled, "Pin still pins rows you can't see")
        scene.lyricsOverlayController.isPresented = false
        XCTAssertTrue(commands.isBackEnabled)
        XCTAssertTrue(commands.isTrackSelectionEnqueueEnabled)
        XCTAssertTrue(commands.isTrackSelectionPinEnabled)
    }

    func testLyricsMenuTitleReflectsPresentedState() {
        let manager = CommandPaletteManager(keymapStore: makeStore())
        let scene = SpotiglassSceneHost(commandPaletteManager: manager)
        let registry = SpotiglassSceneRegistry()
        registry.activate(scene)
        let commands = SpotiglassMenuCommands(
            sceneRegistry: registry,
            keymapStore: manager.keymapStore,
            settingsStore: makeSettingsStore(),
            serviceStore: MusicServiceStore(
                storage: InMemoryMusicServiceSelectionStorage(services: [.spotify], active: .spotify)
            ),
            isSignedIn: true
        )

        XCTAssertEqual(commands.lyricsItemTitle, SpotiglassL10n.string("menu.view.showLyrics"))
        scene.lyricsOverlayController.isPresented = true
        XCTAssertEqual(commands.lyricsItemTitle, SpotiglassL10n.string("menu.view.hideLyrics"))
    }

    /// The View menu's Show/Hide Queue item watches the queue flag on its own (#673). The app's
    /// scene no longer reads the flag, so nothing else would bring the menu up to date when the
    /// queue opens or closes: read the title off the real menu bar each time.
    func testViewMenuQueueItemFollowsTheQueueOpeningAndClosing() async throws {
        AppKitTestSupport.activateAppIfNeeded()
        XCTAssertTrue(AppKitTestSupport.pumpRunLoop(until: { NSApp.mainMenu != nil }))
        let flag = StoredFlag.queuePanelVisible
        flag.isOn = false
        defer { flag.isOn = false }
        let show = SpotiglassL10n.string("menu.view.showQueue")
        let hide = SpotiglassL10n.string("menu.view.hideQueue")
        func titles() -> Set<String> {
            guard let menu = NSApp.mainMenu else { return [] }
            return Set(Self.allItems(in: menu).map(\.title)).intersection([show, hide])
        }
        for visible in [false, true, false, true, false] {
            flag.isOn = visible
            let expected: Set<String> = [visible ? hide : show]
            let shown = await AppKitTestSupport.settle(until: { titles() == expected })
            XCTAssertTrue(shown, "with the queue \(visible ? "open" : "closed") the View menu says \(titles().sorted())")
        }
    }

    /// Every item, each submenu brought up to date the way AppKit does just before it opens.
    private static func allItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        return menu.items.flatMap { item in [item] + (item.submenu.map { allItems(in: $0) } ?? []) }
    }

    private struct MenuKeyEquivalentItem {
        let path: String
        let key: String
        let modifiers: NSEvent.ModifierFlags
    }

    private static let systemEditActions: Set<Selector> = [
        NSSelectorFromString("startDictation:"),
        #selector(NSApplication.orderFrontCharacterPalette(_:)),
    ]

    /// Walks the menu tree, skipping the Services submenu. macOS populates that
    /// one from whatever other apps are installed on the running machine, and
    /// those items bring their own key equivalents (Terminal alone contributes
    /// Cmd-A and Cmd-M). They are not ours to deduplicate, and including them
    /// makes this test fail or pass depending on the host, not on the code.
    private func menuKeyEquivalentItems(
        in menu: NSMenu,
        parentPath: String = ""
    ) -> [MenuKeyEquivalentItem] {
        menu.items.flatMap { item in
            guard item.submenu !== NSApp.servicesMenu else { return [MenuKeyEquivalentItem]() }
            // AppKit adds Start Dictation… and Emoji & Symbols to the Edit menu itself, each with a
            // hidden twin; once the menu has been updated (opened, or after a change since #677)
            // the pair share one shortcut. The hidden twin is the system's; the visible item is
            // still checked against the app's own shortcuts.
            if item.isHidden, let action = item.action, Self.systemEditActions.contains(action) { return [] }
            let path = parentPath.isEmpty ? item.title : "\(parentPath) > \(item.title)"
            let current = item.keyEquivalent.isEmpty
                ? []
                : [
                    MenuKeyEquivalentItem(
                        path: path,
                        key: item.keyEquivalent,
                        modifiers: item.keyEquivalentModifierMask
                    )
                ]
            let children = item.submenu.map {
                menuKeyEquivalentItems(in: $0, parentPath: path)
            } ?? []
            return current + children
        }
    }

    // MARK: - Help menu (#177)

    /// The default Help item was a silent no-op: the bundle declares no
    /// CFBundleHelpBookName, so choosing it did nothing at all. These are the
    /// destinations that replaced it, and a typo in either one would ship a
    /// Help menu that fails exactly as quietly as the old one did.
    @MainActor
    func testHelpMenuPointsAtRealDestinations() {
        XCTAssertEqual(
            SpotiglassMenuCommands.readmeURL.absoluteString,
            "https://github.com/isaaclins/spotiglass#readme"
        )
        XCTAssertEqual(
            SpotiglassMenuCommands.newIssueURL.absoluteString,
            "https://github.com/isaaclins/spotiglass/issues/new"
        )
        for url in [SpotiglassMenuCommands.readmeURL, SpotiglassMenuCommands.newIssueURL] {
            XCTAssertEqual(url.scheme, "https", "help destinations must not be plain http")
            XCTAssertNotNil(url.host, "a hostless URL opens nothing")
        }
    }

}
