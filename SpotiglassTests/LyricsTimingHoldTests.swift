import AppKit
import SwiftUI
import ViewInspector
import XCTest
@testable import Spotiglass

/// Fixing a song's lyric timing by holding the lyrics (#640).
@MainActor
final class LyricsTimingHoldTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "LyricsTimingHoldTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    // MARK: - Lines

    /// One line every 4 s, starting at 10 s.
    private let lines = (0..<8).map { SyncedLyricLine(id: $0, startTimeMs: 10_000 + $0 * 4_000, words: "Line \($0)") }

    private func makeStore(maxSongs: Int = LyricsTimingStore.defaultMaxSongs, now: @escaping () -> Date = Date.init) -> LyricsTimingStore {
        LyricsTimingStore(defaults: defaults, maxSongs: maxSongs, now: now)
    }

    // MARK: - Store

    func testEachSongKeepsItsOwnShiftAcrossLaunches() {
        let store = makeStore()
        XCTAssertEqual(store.offsetMs(for: "song:a"), 0)
        XCTAssertEqual(store.offsetMs(for: nil), 0)
        XCTAssertFalse(store.hasShift(for: "song:a"))

        store.setOffset(2_100, for: "song:a")
        store.setOffset(-400, for: "song:b")

        let relaunched = makeStore()
        XCTAssertEqual(relaunched.offsetMs(for: "song:a"), 2_100)
        XCTAssertEqual(relaunched.offsetMs(for: "song:b"), -400)
        XCTAssertEqual(relaunched.offsetMs(for: "song:c"), 0, "other songs aren't touched")
        XCTAssertTrue(relaunched.hasShift(for: "song:a"))
    }

    func testResetForgetsOnlyThatSong() {
        let store = makeStore()
        store.setOffset(2_100, for: "song:a")
        store.setOffset(900, for: "song:b")
        store.reset(for: "song:a")

        XCTAssertFalse(store.hasShift(for: "song:a"))
        XCTAssertNil(store.entries["song:a"], "a reset song leaves nothing behind")
        XCTAssertEqual(makeStore().offsetMs(for: "song:b"), 900)
    }

    func testNoLimitOnHowFarASongCanBeShifted() {
        let store = makeStore()
        store.setOffset(95_000, for: "song:a")
        XCTAssertEqual(makeStore().offsetMs(for: "song:a"), 95_000)
    }

    func testOldestFixesAreDroppedPastTheLimit() {
        var clock = Date(timeIntervalSince1970: 1_000)
        let store = makeStore(maxSongs: 2) {
            clock = clock.addingTimeInterval(1)
            return clock
        }
        store.setOffset(100, for: "song:a")
        store.setOffset(200, for: "song:b")
        store.setOffset(300, for: "song:c")

        XCTAssertEqual(Set(store.entries.keys), ["song:b", "song:c"])
        XCTAssertEqual(Set(makeStore().entries.keys), ["song:b", "song:c"])
    }

    func testUnreadableSavedShiftsStartEmpty() {
        defaults.set(Data("not json".utf8), forKey: LyricsTimingStore.defaultsKey)
        XCTAssertTrue(makeStore().entries.isEmpty)
    }

    // MARK: - Hold

    func testDraggingMovesTheHighlightLineByLineAndLettingGoMakesItNow() throws {
        let hold = LyricsTimingHold()
        XCTAssertTrue(hold.begin(songID: "song:a", lines: lines, savedOffsetMs: 0, rawPositionMs: { 19_000 }))
        XCTAssertEqual(hold.session?.heldIndex, 2)

        XCTAssertEqual(hold.drag(contentUpBy: 30, linePitch: 40), 0, "less than a line moves nothing yet")
        XCTAssertEqual(hold.drag(contentUpBy: 30, linePitch: 40), 1)
        XCTAssertEqual(hold.drag(contentUpBy: 85, linePitch: 40), 2)
        XCTAssertEqual(hold.session?.heldIndex, 5)

        // Line 5 starts at 30 s and the song is at 21 s: the lyrics come 9 s sooner.
        let result = try XCTUnwrap(hold.finish(rawPositionMs: 21_000))
        XCTAssertEqual(result.songID, "song:a")
        XCTAssertEqual(result.offsetMs, 9_000)
        XCTAssertNil(hold.session)
    }

    func testDraggingDownShowsEarlierLinesAndStopsAtTheFirst() throws {
        let hold = LyricsTimingHold()
        hold.begin(songID: "song:a", lines: lines, savedOffsetMs: 0, rawPositionMs: { 19_000 })
        XCTAssertEqual(hold.drag(contentUpBy: -400, linePitch: 40), -2)
        XCTAssertEqual(hold.session?.heldIndex, 0)
        XCTAssertEqual(hold.drag(contentUpBy: 40, linePitch: 40), 1, "back up at once, the overshoot is dropped")
        let result = try XCTUnwrap(hold.finish(rawPositionMs: 20_000))
        XCTAssertEqual(result.offsetMs, -6_000, "line 1 starts at 14 s, the song is at 20 s")
    }

    func testDraggingPastTheLastLineStops() {
        let hold = LyricsTimingHold()
        hold.begin(songID: "song:a", lines: lines, savedOffsetMs: 0, rawPositionMs: { 19_000 })
        XCTAssertEqual(hold.drag(contentUpBy: 4_000, linePitch: 40), 5)
        XCTAssertEqual(hold.session?.heldIndex, lines.count - 1)
    }

    /// Paused at 12 s with the 10 s line still highlighted: letting go without moving lines that
    /// line up with now. Dragging away and back counts the same.
    func testLettingGoOnTheStartingLineMakesItNow() throws {
        let hold = LyricsTimingHold()
        hold.begin(songID: "song:a", lines: lines, savedOffsetMs: 0, rawPositionMs: { 12_000 })
        XCTAssertEqual(hold.session?.heldIndex, 0)
        XCTAssertEqual(try XCTUnwrap(hold.finish(rawPositionMs: 12_000)).offsetMs, -2_000)

        hold.begin(songID: "song:a", lines: lines, savedOffsetMs: 500, rawPositionMs: { 18_500 })
        XCTAssertEqual(hold.drag(contentUpBy: 45, linePitch: 40), 1)
        XCTAssertEqual(hold.drag(contentUpBy: -45, linePitch: 40), -1)
        XCTAssertEqual(try XCTUnwrap(hold.finish(rawPositionMs: 19_000)).offsetMs, -1_000, "line 2 starts at 18 s")
        XCTAssertNil(hold.session)
    }

    func testASongWithOneTimedLineCanBeFixed() throws {
        let hold = LyricsTimingHold()
        let single = [SyncedLyricLine(id: 0, startTimeMs: 5_000, words: "Only line")]
        hold.begin(songID: "song:a", lines: single, savedOffsetMs: 0, rawPositionMs: { 9_000 })
        XCTAssertEqual(try XCTUnwrap(hold.finish(rawPositionMs: 9_000)).offsetMs, -4_000)
    }

    func testNoHoldWithoutTimedLines() {
        let hold = LyricsTimingHold()
        XCTAssertFalse(hold.begin(songID: "song:a", lines: [], savedOffsetMs: 0, rawPositionMs: { 0 }))
        XCTAssertEqual(hold.drag(contentUpBy: 100, linePitch: 40), 0)
        XCTAssertNil(hold.finish(rawPositionMs: 0))
    }

    func testLabelSaysHowFarTheTimingMoved() {
        XCTAssertEqual(LyricsTimingHold.label(forShiftMs: 2_140), "Lyrics 2.1 s sooner")
        XCTAssertEqual(LyricsTimingHold.label(forShiftMs: -400), "Lyrics 0.4 s later")
        XCTAssertEqual(LyricsTimingHold.label(forShiftMs: 95_000), "Lyrics 95.0 s sooner")
        XCTAssertEqual(LyricsTimingHold.label(forShiftMs: 40), "Original timing")
        XCTAssertEqual(LyricsTimingHold.label(forShiftMs: 0), "Original timing")
    }

    // MARK: - Render model

    func testHeldLineIsTheActiveOneWithTheShiftLettingGoWouldSave() {
        // The song is at 18 s with a saved shift of +1 s, so the lyrics show 19 s (line 2).
        let model = LyricsScrollRenderModel.timed(
            lines: lines,
            positionMs: 19_000,
            hold: .init(lineID: 5, rawPositionMs: 18_000)
        )
        XCTAssertEqual(model.activeID, 5)
        XCTAssertTrue(model.isHolding)
        XCTAssertEqual(model.holdShiftMs, 12_000, "line 5 starts at 30 s, the song is at 18 s")
        XCTAssertEqual(model.lines.first { $0.id == 5 }?.distance, 0)
    }

    func testBeforeMovingTheLabelShowsWhatLettingGoWouldSave() {
        let model = LyricsScrollRenderModel.timed(
            lines: lines,
            positionMs: 19_000,
            hold: .init(lineID: 2, rawPositionMs: 18_000)
        )
        XCTAssertEqual(model.holdShiftMs, 0, "line 2 starts at 18 s, the song is at 18 s")
    }

    /// Found in the app: with a saved shift that put the lyrics before the song's start, the
    /// shown position stops at zero and the label worked from that, saying "0.5 s later" while
    /// letting go saved 17 s sooner. The label uses the song's own position.
    func testLabelUsesTheSongsPositionWhenTheShiftedOneStopsAtZero() {
        let model = LyricsScrollRenderModel.timed(
            lines: lines,
            positionMs: 0,
            hold: .init(lineID: 2, rawPositionMs: 30_000)
        )
        XCTAssertEqual(model.holdShiftMs, -12_000, "line 2 starts at 18 s, the song is at 30 s")
    }

    func testWithoutAHoldTheLyricsFollowTheSong() {
        let model = LyricsScrollRenderModel.timed(lines: lines, positionMs: 19_000)
        XCTAssertEqual(model.activeID, 2)
        XCTAssertFalse(model.isHolding)
        XCTAssertNil(model.holdShiftMs)
    }

    func testHeldLineShowsTheHighlightAndLabel() async throws {
        let hold = LyricsTimingHold()
        hold.begin(songID: "song:a", lines: lines, savedOffsetMs: 0, rawPositionMs: { 19_000 })
        _ = hold.drag(contentUpBy: 80, linePitch: 40)
        let view = ImmersiveLyricsReadyContentView(
            lyrics: .synced(lines),
            maxHeight: 400,
            positionMs: 19_000,
            trackDurationMs: 60_000,
            reduceMotion: true,
            usesLyricsScrollEdgeFade: true,
            lyricsTextSize: .medium
        )
        .environment(\.lyricsTimingHold, hold)
        .frame(width: 500, height: 420)
        ViewTestHost.host(view, size: CGSize(width: 500, height: 420))
        await ViewTestHost.renderPendingUpdates()

        // Line 4 starts at 26 s and the song is at 19 s.
        let held = Text(verbatim: "Line 4").modifier(LyricsTimingHighlight(shiftMs: 7_000))
        XCTAssertNoThrow(try held.inspect().find(text: "Lyrics 7.0 s sooner"))
        let notHeld = Text(verbatim: "Line 3").modifier(LyricsTimingHighlight(shiftMs: nil))
        XCTAssertThrowsError(try notHeld.inspect().find(text: "Lyrics 7.0 s sooner"))
    }

    // MARK: - Input

    private final class RecordingHaptics: LyricsHaptics {
        var played: [String] = []
        func holdStarted() { played.append("start") }
        func lineChanged() { played.append("tick") }
        func saved() { played.append("saved") }
    }

    private struct InputRig {
        let input: LyricsTimingHoldInput
        let hold: LyricsTimingHold
        let store: LyricsTimingStore
        let haptics: RecordingHaptics
        let clock: ManualPlaybackClock
        let position: PositionBox
    }

    private final class PositionBox {
        var rawMs = 19_000
    }

    private func makeInput(songID: String = "song:a", lines: [SyncedLyricLine]? = nil) -> InputRig {
        let hold = LyricsTimingHold()
        let store = makeStore()
        let haptics = RecordingHaptics()
        let clock = ManualPlaybackClock()
        let position = PositionBox()
        let lines = lines ?? self.lines
        let input = LyricsTimingHoldInput(hold: hold, store: store, haptics: haptics, clock: clock) {
            LyricsTimingHoldInput.Context(
                songID: songID,
                lines: lines,
                savedOffsetMs: store.offsetMs(for: songID),
                rawPositionMs: { position.rawMs },
                linePitch: 40
            )
        }
        return InputRig(input: input, hold: hold, store: store, haptics: haptics, clock: clock, position: position)
    }

    func testHoldingStartsAfterAMomentWithAFirmTap() async {
        let rig = makeInput()
        XCTAssertTrue(rig.input.handle(.rightDown(CGPoint(x: 100, y: 200), inside: true)))
        XCTAssertNil(rig.hold.session)
        let armed = await rig.clock.waitForSleepers()
        XCTAssertTrue(armed)
        rig.clock.advance(by: LyricsTimingHoldInput.holdDelay)
        await waitUntil { rig.hold.session != nil }
        XCTAssertEqual(rig.hold.session?.heldIndex, 2)
        XCTAssertEqual(rig.haptics.played, ["start"])
    }

    func testDragThenLetGoSavesTheShiftForThatSongWithTicksAndAFirmerTap() {
        let rig = makeInput()
        XCTAssertTrue(rig.input.handle(.rightDown(CGPoint(x: 100, y: 200), inside: true)))
        // Moving starts the hold at once, without waiting.
        XCTAssertTrue(rig.input.handle(.rightDragged(CGPoint(x: 100, y: 245))))
        XCTAssertEqual(rig.hold.session?.heldIndex, 3)
        XCTAssertTrue(rig.input.handle(.rightDragged(CGPoint(x: 100, y: 285))))
        XCTAssertEqual(rig.hold.session?.heldIndex, 4)

        // Music played on while holding: the song is at 22 s when the button comes up.
        rig.position.rawMs = 22_000
        XCTAssertTrue(rig.input.handle(.rightUp(CGPoint(x: 100, y: 285))))
        XCTAssertNil(rig.hold.session)
        XCTAssertEqual(rig.store.offsetMs(for: "song:a"), 4_000, "line 4 starts at 26 s")
        XCTAssertEqual(rig.haptics.played, ["start", "tick", "tick", "saved"])
        XCTAssertFalse(rig.input.handle(.rightUp(CGPoint(x: 0, y: 0))), "the next release isn't the hold's")
    }

    func testPausedWhileHoldingNowIsThePausedPosition() {
        let rig = makeInput()
        _ = rig.input.handle(.rightDown(CGPoint(x: 0, y: 0), inside: true))
        _ = rig.input.handle(.rightDragged(CGPoint(x: 0, y: -45)))
        // Paused at 19.5 s: the position stays where it is until the release.
        rig.position.rawMs = 19_500
        _ = rig.input.handle(.rightUp(CGPoint(x: 0, y: -45)))
        XCTAssertEqual(rig.store.offsetMs(for: "song:a"), -5_500, "line 1 starts at 14 s")
    }

    func testTrackpadScrollWhileHoldingMovesTheLyricsToo() async {
        let rig = makeInput()
        _ = rig.input.handle(.rightDown(CGPoint(x: 0, y: 0), inside: true))
        let armed = await rig.clock.waitForSleepers()
        XCTAssertTrue(armed)
        rig.clock.advance(by: LyricsTimingHoldInput.holdDelay)
        await waitUntil { rig.hold.session != nil }
        XCTAssertEqual(rig.hold.session?.heldIndex, 2)
        // Content moving up (negative delta) brings later lines in.
        XCTAssertTrue(rig.input.handle(.scroll(deltaY: -40, precise: true)))
        XCTAssertEqual(rig.hold.session?.heldIndex, 3)
        // A mouse wheel notch is a line's worth.
        XCTAssertTrue(rig.input.handle(.scroll(deltaY: 1, precise: false)))
        XCTAssertEqual(rig.hold.session?.heldIndex, 2)
    }

    /// A held two-finger click that moves may report the motion as a drag and as scrolling: once
    /// the pointer drags, the scrolling is left out so the lyrics move once.
    func testScrollAlongsideAPointerDragDoesntMoveTheLyricsTwice() {
        let rig = makeInput()
        _ = rig.input.handle(.rightDown(CGPoint(x: 0, y: 0), inside: true))
        _ = rig.input.handle(.rightDragged(CGPoint(x: 0, y: 40)))
        XCTAssertEqual(rig.hold.session?.heldIndex, 3)
        XCTAssertTrue(rig.input.handle(.scroll(deltaY: -40, precise: true)), "still the hold's")
        XCTAssertEqual(rig.hold.session?.heldIndex, 3)
        _ = rig.input.handle(.rightDragged(CGPoint(x: 0, y: 80)))
        XCTAssertEqual(rig.hold.session?.heldIndex, 4)
    }

    /// A point of pointer jitter mustn't turn trackpad scrolling off for the rest of the hold:
    /// a moment after the last drag, scrolling moves the lyrics again.
    func testScrollingWorksAgainAMomentAfterAPointerDrag() {
        let rig = makeInput()
        _ = rig.input.handle(.rightDown(CGPoint(x: 0, y: 0), inside: true))
        _ = rig.input.handle(.rightDragged(CGPoint(x: 0, y: 5)))
        _ = rig.input.handle(.rightDragged(CGPoint(x: 0, y: 6)))
        XCTAssertEqual(rig.hold.session?.heldIndex, 2)
        rig.clock.advance(by: LyricsTimingHoldInput.dragEchoWindow)
        XCTAssertTrue(rig.input.handle(.scroll(deltaY: -40, precise: true)))
        XCTAssertEqual(rig.hold.session?.heldIndex, 3)
    }

    func testASecondEscAfterACancelStaysWithTheHold() {
        let rig = makeInput()
        _ = rig.input.handle(.rightDown(.zero, inside: true))
        _ = rig.input.handle(.rightDragged(CGPoint(x: 0, y: 80)))
        XCTAssertTrue(rig.input.handle(.escape))
        XCTAssertTrue(rig.input.handle(.escape), "the button is still down, so the lyrics stay open")
        XCTAssertTrue(rig.input.handle(.rightUp(.zero)))
        XCTAssertFalse(rig.input.handle(.escape))
    }

    func testASidewaysDragLeavesScrollingWorking() async {
        let rig = makeInput()
        _ = rig.input.handle(.rightDown(CGPoint(x: 0, y: 0), inside: true))
        let armed = await rig.clock.waitForSleepers()
        XCTAssertTrue(armed)
        rig.clock.advance(by: LyricsTimingHoldInput.holdDelay)
        await waitUntil { rig.hold.session != nil }
        _ = rig.input.handle(.rightDragged(CGPoint(x: 30, y: 0)))
        XCTAssertTrue(rig.input.handle(.scroll(deltaY: -40, precise: true)))
        XCTAssertEqual(rig.hold.session?.heldIndex, 3)
    }

    /// An input that goes away mid-press (its lyrics closed) must not leave Esc taken for good.
    func testAnInputGoneMidPressNoLongerHoldsEsc() {
        var rig: InputRig? = makeInput()
        XCTAssertTrue(rig?.input.handle(.rightDown(.zero, inside: true)) == true)
        XCTAssertTrue(LyricsTimingHoldInput.isHoldInProgress)
        rig = nil
        XCTAssertFalse(LyricsTimingHoldInput.isHoldInProgress)
    }

    func testScrollWithoutAHoldIsLeftToTheLyrics() {
        let rig = makeInput()
        XCTAssertFalse(rig.input.handle(.scroll(deltaY: -40, precise: true)))
        XCTAssertFalse(rig.input.handle(.escape))
    }

    func testEscapeCancelsAndTheReleaseSavesNothing() {
        let rig = makeInput()
        _ = rig.input.handle(.rightDown(CGPoint(x: 0, y: 0), inside: true))
        _ = rig.input.handle(.rightDragged(CGPoint(x: 0, y: 120)))
        XCTAssertNotNil(rig.hold.session)

        XCTAssertTrue(rig.input.handle(.escape), "Esc is the hold's, so it doesn't also close the lyrics")
        XCTAssertNil(rig.hold.session)
        XCTAssertTrue(rig.input.handle(.rightDragged(CGPoint(x: 0, y: 200))))
        XCTAssertTrue(rig.input.handle(.scroll(deltaY: 3, precise: true)))
        XCTAssertNil(rig.hold.session, "nothing moves after the cancel")
        XCTAssertTrue(rig.input.handle(.rightUp(CGPoint(x: 0, y: 200))))
        XCTAssertFalse(rig.store.hasShift(for: "song:a"))
        XCTAssertEqual(rig.haptics.played, ["start", "tick"])
    }

    func testEscapeBeforeTheHoldStartsCancelsThePress() async {
        let rig = makeInput()
        _ = rig.input.handle(.rightDown(CGPoint(x: 0, y: 0), inside: true))
        XCTAssertTrue(rig.input.handle(.escape))
        rig.clock.advance(by: LyricsTimingHoldInput.holdDelay)
        await ViewTestHost.renderPendingUpdates()
        XCTAssertNil(rig.hold.session)
        XCTAssertTrue(rig.input.handle(.rightUp(.zero)))
        XCTAssertTrue(rig.haptics.played.isEmpty)
    }

    func testSongChangeWhileHoldingCancelsWithoutSaving() {
        let rig = makeInput()
        _ = rig.input.handle(.rightDown(CGPoint(x: 0, y: 0), inside: true))
        _ = rig.input.handle(.rightDragged(CGPoint(x: 0, y: 120)))
        rig.input.cancel(buttonStillDown: true)
        XCTAssertNil(rig.hold.session)
        XCTAssertTrue(rig.input.handle(.rightUp(CGPoint(x: 0, y: 120))))
        XCTAssertFalse(rig.store.hasShift(for: "song:a"))
        XCTAssertFalse(rig.haptics.played.contains("saved"))
    }

    func testLosingFocusEndsTheHold() {
        let rig = makeInput()
        _ = rig.input.handle(.rightDown(CGPoint(x: 0, y: 0), inside: true))
        _ = rig.input.handle(.rightDragged(CGPoint(x: 0, y: 120)))
        rig.input.cancel(buttonStillDown: false)
        XCTAssertNil(rig.hold.session)
        XCTAssertFalse(rig.input.handle(.rightUp(.zero)), "a release after that isn't the hold's")
        rig.input.cancel(buttonStillDown: false)
    }

    func testShortClickOnASongWithAShiftOffersReset() {
        let rig = makeInput()
        var menuFor: [String] = []
        rig.input.showResetMenu = { _, songID in menuFor.append(songID) }

        _ = rig.input.handle(.rightDown(.zero, inside: true))
        XCTAssertTrue(rig.input.handle(.rightUp(.zero)))
        XCTAssertEqual(menuFor, [], "no menu while the song has its own timing")

        rig.store.setOffset(1_200, for: "song:a")
        _ = rig.input.handle(.rightDown(.zero, inside: true))
        _ = rig.input.handle(.rightDragged(CGPoint(x: 1, y: 1)))
        XCTAssertTrue(rig.input.handle(.rightUp(CGPoint(x: 1, y: 1))))
        XCTAssertEqual(menuFor, ["song:a"])
        XCTAssertNil(rig.hold.session)
        XCTAssertTrue(rig.haptics.played.isEmpty)
    }

    func testRightClicksOutsideTheLyricsOrWithoutTimedLinesAreLeftAlone() {
        let rig = makeInput()
        XCTAssertFalse(rig.input.handle(.rightDown(.zero, inside: false)))
        XCTAssertFalse(rig.input.handle(.rightDragged(CGPoint(x: 0, y: 100))))
        XCTAssertFalse(rig.input.handle(.rightUp(.zero)))

        let plain = makeInput()
        plain.input.context = { nil }
        XCTAssertFalse(plain.input.handle(.rightDown(.zero, inside: true)))
    }

    func testLyricsGoneWhenTheHoldWouldStartIgnoresTheRestOfThePress() {
        let rig = makeInput(lines: [])
        XCTAssertTrue(rig.input.handle(.rightDown(.zero, inside: true)))
        XCTAssertTrue(rig.input.handle(.rightDragged(CGPoint(x: 0, y: 100))))
        XCTAssertNil(rig.hold.session)
        XCTAssertTrue(rig.input.handle(.rightUp(.zero)))
        XCTAssertTrue(rig.haptics.played.isEmpty)
    }

    // MARK: - Surface and menu

    private func makeHostedSurface(lyrics: FetchedLyrics?, songID: String? = "song:a") throws -> (LyricsTimingHoldView, NSWindow, LyricsTimingStore) {
        let store = makeStore()
        let playback = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(
            playbackAPI: MockPlaybackAPI(),
            webCommander: MockWebPlaybackCommander()
        ))
        let view = Color.black
            .frame(width: 400, height: 300)
            .lyricsTimingHold(
                playbackViewModel: playback,
                songID: songID,
                lyrics: lyrics,
                textSize: .medium,
                store: store,
                haptics: RecordingHaptics(),
                clock: ManualPlaybackClock()
            )
        let host = ViewTestHost.host(view, size: CGSize(width: 400, height: 300))
        host.view.layoutSubtreeIfNeeded()
        let surface = try XCTUnwrap(host.view.firstDescendant(of: LyricsTimingHoldView.self))
        let window = try XCTUnwrap(host.view.window)
        return (surface, window, store)
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    func testSurfaceTakesTheHoldsEventsAndPassesTheRestOn() throws {
        let (surface, window, store) = try makeHostedSurface(lyrics: .synced(lines))
        let center = CGPoint(x: 200, y: 150)

        XCTAssertNil(surface.route(mouse(.rightMouseDown, at: center, in: window)))
        XCTAssertNil(surface.route(mouse(.rightMouseDragged, at: CGPoint(x: 200, y: 260), in: window)))
        XCTAssertNil(surface.route(mouse(.rightMouseUp, at: CGPoint(x: 200, y: 260), in: window)))
        XCTAssertTrue(store.hasShift(for: "song:a"), "the drag moved the lyrics and the release saved it")

        let leftClick = mouse(.leftMouseDown, at: center, in: window)
        XCTAssertTrue(surface.route(leftClick) === leftClick, "left clicks still reach the lyrics")
        let otherKey = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "a",
            charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0
        ))
        XCTAssertNil(surface.holdEvent(for: otherKey))
        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: LyricsTimingHoldView.escapeKeyCode
        ))
        XCTAssertEqual(surface.holdEvent(for: escape), .escape)
        XCTAssertTrue(surface.route(escape) === escape, "Esc without a hold still closes the lyrics")

        let scroll = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 12, wheel2: 0, wheel3: 0))
        let elsewhere = try XCTUnwrap(NSEvent(cgEvent: scroll))
        XCTAssertNil(surface.holdEvent(for: elsewhere), "scrolling in another window stays that window's")
        scroll.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        scroll.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        let here = try XCTUnwrap(NSEvent(cgEvent: scroll))
        if here.window === window {
            XCTAssertEqual(surface.holdEvent(for: here), .scroll(deltaY: here.scrollingDeltaY, precise: here.hasPreciseScrollingDeltas))
        }
    }

    func testRightClickOutsideTheSurfaceIsLeftAlone() throws {
        let (surface, window, _) = try makeHostedSurface(lyrics: .synced(lines))
        let down = mouse(.rightMouseDown, at: CGPoint(x: 900, y: 900), in: window)
        XCTAssertEqual(surface.holdEvent(for: down), .rightDown(CGPoint(x: 900, y: 900), inside: false))
        XCTAssertTrue(surface.route(down) === down)
    }

    /// Closed lyrics stay built under the page (#674). From the moment they start to close, a
    /// right click there belongs to the page, while they still fade out too.
    func testClosingLyricsLeaveARightClickToThePage() throws {
        let (surface, window, _) = try makeHostedSurface(lyrics: .synced(lines))
        surface.startsHolds = false
        let down = mouse(.rightMouseDown, at: CGPoint(x: 200, y: 150), in: window)
        XCTAssertNil(surface.holdEvent(for: down))
        XCTAssertTrue(surface.route(down) === down)

        surface.startsHolds = true
        XCTAssertNil(surface.route(down), "opened again, a right click starts a hold")
    }

    func testPlainLyricsCantBeHeld() throws {
        let (surface, window, _) = try makeHostedSurface(lyrics: .unsyncedPlain(["a", "b"]))
        let down = mouse(.rightMouseDown, at: CGPoint(x: 200, y: 150), in: window)
        XCTAssertTrue(surface.route(down) === down)
    }

    func testShortRightClickOnAShiftedSongBuildsTheResetMenu() throws {
        let (surface, window, store) = try makeHostedSurface(lyrics: .synced(lines))
        store.setOffset(1_500, for: "song:a")
        let point = CGPoint(x: 200, y: 150)
        XCTAssertNil(surface.route(mouse(.rightMouseDown, at: point, in: window)))
        XCTAssertNil(surface.route(mouse(.rightMouseUp, at: point, in: window)))

        let item = try XCTUnwrap(surface.resetMenu?.items.first)
        XCTAssertEqual(item.title, "Reset timing")
        let target = try XCTUnwrap(item.target as? LyricsTimingResetTarget)
        target.reset()
        XCTAssertFalse(store.hasShift(for: "song:a"))
    }

    func testRemovingTheSurfaceStopsWatching() throws {
        let (surface, window, store) = try makeHostedSurface(lyrics: .synced(lines))
        XCTAssertNil(surface.route(mouse(.rightMouseDown, at: CGPoint(x: 200, y: 150), in: window)))
        surface.removeFromSuperview()
        XCTAssertNil(surface.window)
        let up = mouse(.rightMouseUp, at: .zero, in: window)
        XCTAssertTrue(surface.route(up) === up, "the press ended with the surface")
        XCTAssertFalse(store.hasShift(for: "song:a"))
    }

    // MARK: - Haptics

    private final class RecordingPerformer: NSObject, NSHapticFeedbackPerformer {
        var patterns: [NSHapticFeedbackManager.FeedbackPattern] = []
        func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern, performanceTime: NSHapticFeedbackManager.PerformanceTime) {
            patterns.append(pattern)
        }
    }

    func testWithoutTheTrackpadActuatorTheStandardPatternsPlay() {
        let performer = RecordingPerformer()
        let haptics = TrackpadLyricsHaptics(
            actuators: MultitouchActuators(frameworkPath: "/nonexistent/MultitouchSupport"),
            fallback: performer
        )
        haptics.holdStarted()
        haptics.lineChanged()
        haptics.saved()
        XCTAssertEqual(performer.patterns, [.levelChange, .alignment, .levelChange])
    }

    func testTheActuatorsPlayOnlyWhereThereIsATrackpadToPlayOn() {
        XCTAssertFalse(MultitouchActuators(frameworkPath: "/nonexistent").actuate(6), "no framework, nothing plays")
        // The system's framework loads; a machine without a Force Touch trackpad (CI, a Mac
        // mini) has no actuator, and asking again looks for one again.
        let actuators = MultitouchActuators()
        let played = actuators.actuate(TrackpadLyricsHaptics.Strength.tick.rawValue)
        XCTAssertEqual(actuators.actuate(TrackpadLyricsHaptics.Strength.tick.rawValue), played)
    }

    // MARK: - Helpers

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            await ViewTestHost.renderPendingUpdates(passes: 1)
        }
    }
}

private extension NSView {
    func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        if let match = self as? T { return match }
        for subview in subviews {
            if let match = subview.firstDescendant(of: type) { return match }
        }
        return nil
    }

}
