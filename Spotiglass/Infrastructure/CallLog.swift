import Foundation
import os

/// Every call Wax makes outside itself goes into the log (#734): each MusicKit call (player, queue,
/// library, catalog) and each HTTP request (Apple Music API, Spotify, lyrics, artwork), with a line
/// when it starts and one when it ends, saying how long it took and how it ended. A failure carries
/// the whole error (``SpotiglassLog/describe(_:)``), so no call can fail without a line.
///
/// It also ties calls to what the user did: a call that starts shortly after an interaction is
/// marked with it, and when the interaction then waited longer than ``slowInteraction`` for the call,
/// the end line says so. The calls still running show up in the line about a blocked main thread
/// (``HangWatch``), so a wait can be told apart from a busy app.
enum CallLog {
    enum Kind: String {
        case musicKit = "MusicKit"
        case http = "HTTP"
    }

    /// A call that starts within this long after an interaction counts as one it waits on.
    static let interactionWindow: TimeInterval = 0.5
    /// An interaction that waited longer than this for a call is called out in the call's end line.
    static let slowInteraction: TimeInterval = 1

    struct Interaction: Equatable {
        let id: Int
        let label: String
        /// `ProcessInfo.systemUptime` of the input.
        let at: TimeInterval
    }

    private struct Running {
        let kind: Kind
        let name: String
        let start: TimeInterval
        let interaction: Interaction?
    }

    private struct State {
        var nextID = 1
        var running: [Int: Running] = [:]
        var lastInteraction: Interaction?
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// Where lines go; tests read the file the app writes.
    nonisolated(unsafe) static var write: (_ isError: Bool, _ message: String) -> Void = { isError, message in
        if isError {
            SpotiglassLog.error(.calls, message)
        } else {
            SpotiglassLog.info(.calls, message)
        }
    }

    /// The clock calls are timed with.
    nonisolated(unsafe) static var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    // MARK: - Interactions

    /// The user just did something (``InteractionLog``); calls that start soon after wait on it.
    static func noteInteraction(_ interaction: Interaction) {
        state.withLock { $0.lastInteraction = interaction }
    }

    /// The last interaction, for the line about a blocked main thread.
    static var lastInteraction: Interaction? {
        state.withLock { $0.lastInteraction }
    }

    // MARK: - Calls

    /// Runs `body`, the call named `name`, with a line when it starts and one when it ends.
    /// `summary` adds what came back (a status, a count) to the end line.
    static func run<T>(
        _ kind: Kind,
        _ name: @autoclosure () -> String,
        summary: (T) -> String = { _ in "" },
        describe: (Error) -> String = SpotiglassLog.describe,
        _ body: () async throws -> T
    ) async throws -> T {
        let name = SpotiglassLog.redactSecrets(name())
        let id = begin(kind, name)
        do {
            let value = try await body()
            end(id, outcome: summary(value), failed: false)
            return value
        } catch is CancellationError {
            end(id, outcome: "cancelled", failed: false)
            throw CancellationError()
        } catch let error as NSError where error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
            // MusicKit hands a cancelled read back as Foundation's "cancelled": the page that
            // asked went away, nothing failed.
            end(id, outcome: "cancelled", failed: false)
            throw error
        } catch {
            end(id, outcome: describe(error), failed: true)
            throw error
        }
    }

    /// An HTTP request through `session`: method, URL, status, bytes and time. A status of 400 or
    /// more is logged as an error too, though the caller still gets the response, unless it is
    /// one of `expected` (LRCLIB's 404 is "no lyrics for this song", an answer).
    static func http(_ request: URLRequest, session: URLSession, expected: Set<Int> = []) async throws -> (
        Data, URLResponse
    ) {
        let method = request.httpMethod ?? "GET"
        let url = request.url?.absoluteString ?? "(no URL)"
        return try await runHTTP("\(method) \(url)", expected: expected) {
            try await session.data(for: request, delegate: nil)
        }
    }

    /// An HTTP GET of `url` through `session`.
    static func http(_ url: URL, session: URLSession) async throws -> (Data, URLResponse) {
        try await runHTTP("GET \(url.absoluteString)", expected: []) {
            try await session.data(from: url, delegate: nil)
        }
    }

    private static func runHTTP(
        _ name: String,
        expected: Set<Int>,
        _ body: () async throws -> (Data, URLResponse)
    ) async throws -> (Data, URLResponse) {
        let name = SpotiglassLog.redactSecrets(name)
        let id = begin(.http, name)
        do {
            let (data, response) = try await body()
            let status = (response as? HTTPURLResponse)?.statusCode
            let outcome = "status \(status.map(String.init) ?? "none (not HTTP)"), \(data.count) bytes"
            end(id, outcome: outcome, failed: status.map { $0 >= 400 && !expected.contains($0) } ?? true)
            return (data, response)
        } catch is CancellationError {
            end(id, outcome: "cancelled", failed: false)
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            end(id, outcome: "cancelled", failed: false)
            throw error
        } catch {
            end(id, outcome: SpotiglassLog.describe(error), failed: true)
            throw error
        }
    }

    /// The calls running now, longest first: "MusicKit player.play (#12, 2.1 s)".
    static func runningSummary(limit: Int = 6) -> String {
        let at = now()
        let running = state.withLock { $0.running }
        guard !running.isEmpty else { return "no calls running" }
        let sorted = running.sorted { $0.value.start < $1.value.start }
        var parts = sorted.prefix(limit).map { id, call in
            "\(call.kind.rawValue) \(call.name) (#\(id), \(seconds(at - call.start)))"
        }
        if sorted.count > limit { parts.append("\(sorted.count - limit) more") }
        return "calls running: " + parts.joined(separator: "; ")
    }

    private static func begin(_ kind: Kind, _ name: String) -> Int {
        let at = now()
        let (id, interaction) = state.withLock { state -> (Int, Interaction?) in
            let id = state.nextID
            state.nextID += 1
            let interaction = state.lastInteraction.flatMap { at - $0.at <= interactionWindow ? $0 : nil }
            state.running[id] = Running(kind: kind, name: name, start: at, interaction: interaction)
            return (id, interaction)
        }
        let after = interaction.map { " (after interaction #\($0.id) \($0.label))" } ?? ""
        write(false, "→ #\(id) \(kind.rawValue) \(name)\(after)")
        return id
    }

    private static func end(_ id: Int, outcome: String, failed: Bool) {
        let at = now()
        guard let call = state.withLock({ $0.running.removeValue(forKey: id) }) else { return }
        var line =
            "← #\(id) \(call.kind.rawValue) \(call.name) \(failed ? "failed" : "done") after \(milliseconds(at - call.start))"
        // An error's text can carry what a request sent (MusicKit's prints its headers).
        if !outcome.isEmpty { line += ": \(SpotiglassLog.redactSecrets(outcome))" }
        if let interaction = call.interaction, at - interaction.at > slowInteraction {
            line +=
                " — SLOW: interaction #\(interaction.id) \(interaction.label) waited \(seconds(at - interaction.at)) for this"
        }
        write(failed, line)
    }

    static func milliseconds(_ interval: TimeInterval) -> String {
        String(format: "%.1f ms", interval * 1000)
    }

    static func seconds(_ interval: TimeInterval) -> String {
        String(format: "%.2f s", interval)
    }
}
