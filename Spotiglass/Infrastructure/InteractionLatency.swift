import Foundation

/// Every interaction in Wax shows its first visible result within 50 ms (#656). These types hold
/// what the latency probe measures and decide whether a run passes; the probe itself
/// (``InteractionLatencyProbe``) drives the real app.
enum InteractionLatency {
    /// The most any interaction may take, from the input to the first frame that shows it.
    static let budgetMilliseconds = 50.0

    /// Set by `scripts/latency-test.sh` to the file the report is written to. Only read in
    /// screenshot mode, so a normal launch never runs the probe.
    static let environmentKey = "WAX_LATENCY_PROBE"

    /// Where the probe writes its report, or `nil` when the probe isn't on. Screenshot mode must be
    /// on too: the probe presses keys and clicks in the window, which only the sample library may
    /// see.
    static func reportURL(in environment: [String: String], screenshotModeActive: Bool) -> URL? {
        guard screenshotModeActive,
            let path = environment[environmentKey],
            path.hasPrefix("/")
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// One interaction as the probe ran it: every try's time, or why it never showed.
    struct Measurement: Codable, Equatable {
        /// Stable id, e.g. `palette.open`; the docs table and CI output use it.
        let id: String
        /// What the user does, in plain words.
        let title: String
        /// Milliseconds from the input to the first frame that showed it, one per try. A try whose
        /// result never showed within the probe's timeout isn't in here: see ``timedOut``.
        let milliseconds: [Double]
        /// Tries whose result never showed.
        let timedOut: Int
        /// For each try that never showed, what went wrong and what the app showed then, so a
        /// failure can be told apart from a probe that lost its way.
        var problems: [String] = []

        var median: Double? {
            let sorted = milliseconds.sorted()
            guard !sorted.isEmpty else { return nil }
            let middle = sorted.count / 2
            return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        }

        /// The time the budget is checked against. Shared CI machines now and then stall a whole
        /// process for a frame or two, so the one worst try is dropped (a try that never showed
        /// counts as the worst); a second slow one fails the run. Every try still shows in the
        /// report.
        var gated: Double? {
            let tries = milliseconds.sorted() + Array(repeating: Double.infinity, count: timedOut)
            guard tries.count >= 3 else { return tries.last }
            return tries[tries.count - 2]
        }

        var isWithinBudget: Bool {
            guard let gated else { return false }
            return gated <= InteractionLatency.budgetMilliseconds
        }
    }

    struct Report: Codable, Equatable {
        /// `CFBundleShortVersionString` of the build that was measured.
        let appVersion: String
        /// `Release` or `Debug`: only Release times count.
        let configuration: String
        /// One display refresh in milliseconds, already added to every time: the frame the probe
        /// sees committed reaches the screen at the next refresh.
        let frameMilliseconds: Double
        let measurements: [Measurement]
        /// Set when the probe couldn't start measuring at all (no window, the library never
        /// loaded), so a broken setup fails instead of passing with nothing measured.
        let setupFailure: String?

        var passes: Bool {
            setupFailure == nil && !measurements.isEmpty && measurements.allSatisfy(\.isWithinBudget)
        }

        /// One line per interaction, for the CI log and `scripts/latency-test.sh`.
        func summaryLines() -> [String] {
            var lines = [
                "Wax \(appVersion) (\(configuration)), one frame = \(Self.format(frameMilliseconds)) ms included: "
                    + (passes ? "every interaction within budget" : "over budget")
            ]
            if let setupFailure { lines.append("setup failed: \(setupFailure)") }
            for m in measurements {
                let verdict = m.isWithinBudget ? "ok  " : "SLOW"
                let tries = m.milliseconds.map { Self.format($0) }.joined(separator: " ")
                let timeouts =
                    m.timedOut > 0
                    ? "  (\(m.timedOut) never showed: \(Set(m.problems).sorted().joined(separator: "; ")))" : ""
                lines.append(
                    "\(verdict) \(m.id.padding(toLength: 24, withPad: " ", startingAt: 0)) "
                        + "median \(m.median.map(Self.format) ?? "-") ms, checked \(m.gated.map { $0.isFinite ? Self.format($0) : "never" } ?? "-") ms"
                        + "  [\(tries)]\(timeouts)  \(m.title)"
                )
            }
            return lines
        }

        static func format(_ value: Double) -> String {
            String(format: "%.1f", value)
        }
    }
}
