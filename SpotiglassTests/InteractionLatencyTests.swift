import XCTest

@testable import Spotiglass

/// The verdicts `scripts/latency-test.sh` and CI rely on (#656).
final class InteractionLatencyTests: XCTestCase {
    private typealias Measurement = InteractionLatency.Measurement

    func testProbeIsOffInANormalLaunch() {
        XCTAssertNil(InteractionLatency.reportURL(in: [:], screenshotModeActive: false))
        // Asked for, but not in screenshot mode: it would press keys in someone's real library.
        XCTAssertNil(
            InteractionLatency.reportURL(in: ["WAX_LATENCY_PROBE": "/tmp/report.json"], screenshotModeActive: false)
        )
        XCTAssertNil(InteractionLatency.reportURL(in: [:], screenshotModeActive: true))
    }

    func testProbeWritesWhereTheScriptAsks() {
        XCTAssertEqual(
            InteractionLatency.reportURL(in: ["WAX_LATENCY_PROBE": "/tmp/wax/report.json"], screenshotModeActive: true),
            URL(fileURLWithPath: "/tmp/wax/report.json")
        )
        // A relative path would land wherever the app happened to start.
        XCTAssertNil(InteractionLatency.reportURL(in: ["WAX_LATENCY_PROBE": "report.json"], screenshotModeActive: true))
    }

    /// The times my work Mac logged for play/pause before #645 was fixed: 50-610 ms per press.
    func testPlayPauseTimesFrom645FailTheBudget() {
        let before645 = Measurement(
            id: "playback.toggle.key", title: "Space", milliseconds: [52, 610, 140, 95, 71, 88, 230], timedOut: 0
        )
        XCTAssertFalse(before645.isWithinBudget)
        XCTAssertEqual(before645.median, 95)
        XCTAssertEqual(before645.gated, 230)
    }

    /// One stalled frame on a shared CI machine is dropped; a second slow try fails.
    func testOneSlowTryIsForgivenButNotTwo() {
        let oneStall = Measurement(id: "a", title: "a", milliseconds: [31, 33, 30, 97, 32, 34, 31], timedOut: 0)
        XCTAssertTrue(oneStall.isWithinBudget)
        XCTAssertEqual(oneStall.gated, 34)

        let twoStalls = Measurement(id: "a", title: "a", milliseconds: [31, 33, 61, 97, 32, 34, 31], timedOut: 0)
        XCTAssertFalse(twoStalls.isWithinBudget)
        XCTAssertEqual(twoStalls.gated, 61)
    }

    func testExactlyTheBudgetPasses() {
        XCTAssertTrue(Measurement(id: "a", title: "a", milliseconds: [50, 50, 50], timedOut: 0).isWithinBudget)
        XCTAssertFalse(Measurement(id: "a", title: "a", milliseconds: [50.1, 50.1, 50.1], timedOut: 0).isWithinBudget)
    }

    /// A press that never shows counts as the slowest try: one is forgiven like a stall, two fail.
    func testAnInteractionThatNeverShowedCountsAsTheSlowestTry() {
        let once = Measurement(id: "a", title: "a", milliseconds: [20, 21, 22, 20, 21, 20, 21], timedOut: 1)
        XCTAssertTrue(once.isWithinBudget)
        XCTAssertEqual(once.gated, 22)
        let twice = Measurement(id: "a", title: "a", milliseconds: [20, 21, 22, 20, 21, 20], timedOut: 2)
        XCTAssertFalse(twice.isWithinBudget)
        let never = Measurement(id: "a", title: "a", milliseconds: [], timedOut: 8)
        XCTAssertFalse(never.isWithinBudget)
        XCTAssertNil(never.median)
    }

    func testMedianOfAnEvenCount() {
        XCTAssertEqual(Measurement(id: "a", title: "a", milliseconds: [10, 40, 20, 30], timedOut: 0).median, 25)
    }

    func testAReportWithNothingMeasuredFails() {
        let empty = InteractionLatency.Report(
            appVersion: "1", configuration: "Release", frameMilliseconds: 16.7, measurements: [], setupFailure: nil
        )
        XCTAssertFalse(empty.passes)
        let brokenSetup = InteractionLatency.Report(
            appVersion: "1", configuration: "Release", frameMilliseconds: 16.7,
            measurements: [Measurement(id: "a", title: "a", milliseconds: [10, 10, 10], timedOut: 0)],
            setupFailure: "the library never loaded"
        )
        XCTAssertFalse(brokenSetup.passes)
        XCTAssertEqual(brokenSetup.summaryLines()[1], "setup failed: the library never loaded")
    }

    func testReportRoundTripsAndSaysWhatIsSlow() throws {
        let report = InteractionLatency.Report(
            appVersion: "0.8.62", configuration: "Release", frameMilliseconds: 16.7,
            measurements: [
                Measurement(id: "playback.toggle.key", title: "Space pauses or resumes", milliseconds: [39, 40, 39], timedOut: 0),
                Measurement(
                    id: "palette.open", title: "⌘K opens the command palette", milliseconds: [83, 87, 129], timedOut: 1,
                    problems: ["not shown after 3 s (palette closed)"]
                ),
            ],
            setupFailure: nil
        )
        XCTAssertFalse(report.passes)
        let decoded = try JSONDecoder().decode(InteractionLatency.Report.self, from: JSONEncoder().encode(report))
        XCTAssertEqual(decoded, report)
        let lines = report.summaryLines()
        XCTAssertEqual(lines[0], "Wax 0.8.62 (Release), one frame = 16.7 ms included: over budget")
        XCTAssertTrue(lines[1].hasPrefix("ok   playback.toggle.key"))
        XCTAssertTrue(lines[2].hasPrefix("SLOW palette.open"))
        XCTAssertTrue(lines[2].contains("1 never showed: not shown after 3 s (palette closed)"))
    }
}
