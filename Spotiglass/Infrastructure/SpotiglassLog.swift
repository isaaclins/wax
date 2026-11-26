import CryptoKit
import Foundation
import os

/// Unified logging for Wax. Mirrors every message to:
///   1. Apple's unified log (Console.app, subsystem `com.isaaclins.spotiglass`).
///   2. A plain-text file under `Application Support/Spotiglass/Logs/spotiglass.log`.
///      Each launch starts a fresh `spotiglass.log` and rotates the prior session
///      to `spotiglass.previous.log`. Inside a session the file is capped at
///      ``FileLogSink/defaultMaxBytes``: when it fills up, it moves to
///      `spotiglass.earlier.log` and a new `spotiglass.log` continues. At launch the
///      earlier part moves along with its session to `spotiglass.previous.earlier.log`,
///      so at most four capped files exist (two per session) and the newest lines are
///      never the ones dropped.
///
/// Under the unit-test host the files go to a temporary folder, so `make test` never
/// rotates away or fills the log a user would attach to a bug report.
///
/// The log holds everything Wax does (#734): every interaction (`interaction`), every call out
/// of the app (`calls`), every player change, the sound path, artwork and hangs (`performance`).
/// It stays on the user's Mac. What goes into a public bug report is the copy Settings saves
/// (``BugReportLogCopy``), with searches, names, IDs and addresses replaced by stand-ins; text a
/// person typed or that names something of theirs goes into a line through ``personal(_:)``, so
/// the copy knows to replace it. The unified log gets every message as private (#603). Never log
/// tokens, cookies, passwords, refresh credentials or raw OAuth callbacks: ``redactSecrets(_:)``
/// takes them out of anything that may carry one (a URL, an error).
enum SpotiglassLog {
    enum Category: String, CaseIterable {
        case auth, api, playback, browsing, pinning, settings, persistence
        case interaction, calls, performance, artwork
    }

    // Back-compat aliases so existing `SpotiglassLog.info(SpotiglassLog.playback, ...)` call sites
    // continue to compile unchanged. The type changed from `Logger` to `Category`; the entry-point
    // functions overload on Category below.
    static let auth = Category.auth
    static let api = Category.api
    static let playback = Category.playback
    static let browsing = Category.browsing
    static let pinning = Category.pinning
    static let settings = Category.settings
    static let persistence = Category.persistence

    private static let subsystem = AppMetadata.bundleIdentifier

    private static let osLoggers: [Category: Logger] = {
        Dictionary(uniqueKeysWithValues: Category.allCases.map { category in
            (category, Logger(subsystem: subsystem, category: category.rawValue))
        })
    }()

    /// File path of the current session's log; `nil` before `boot()` runs or if the file
    /// could not be opened.
    static var logFileURL: URL? { FileLogSink.shared.fileURL }

    /// Open a fresh per-session log file, rotating the previous session to
    /// `spotiglass.previous.log`. Safe to call once at app launch; subsequent calls
    /// are no-ops.
    static func boot() {
        if AppMetadata.isRunningUnitTests {
            removeFinishedTestLogFolders()
        }
        FileLogSink.shared.boot()
        installFlushOnExit()
    }

    private static let testLogFolderPrefix = "SpotiglassTestLogs-"

    /// Each test run logs to its own folder (runs from several checkouts may overlap); the
    /// folders of runs whose process has ended go, so they don't pile up.
    static func removeFinishedTestLogFolders(
        in parent: URL = FileManager.default.temporaryDirectory,
        isRunning: (pid_t) -> Bool = { kill($0, 0) == 0 || errno == EPERM }
    ) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else { return }
        for name in names where name.hasPrefix(testLogFolderPrefix) {
            guard let pid = pid_t(name.dropFirst(testLogFolderPrefix.count)), !isRunning(pid) else { continue }
            try? FileManager.default.removeItem(at: parent.appendingPathComponent(name)) // Test leftovers only.
        }
    }

    private static var flushObserver: NSObjectProtocol?
    private static var previousExceptionHandler: (@convention(c) (NSException) -> Void)?

    /// Info and debug lines are written in the background; a quit or an uncaught exception
    /// must not leave the last of them in the queue (#602). Errors are written at once anyway.
    private static func installFlushOnExit() {
        guard flushObserver == nil else { return }
        flushObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("NSApplicationWillTerminateNotification"),
            object: nil,
            queue: nil
        ) { _ in
            SpotiglassLog.info(.persistence, "Wax quitting")
            SpotiglassLog.flush()
        }
        // Exceptions AppKit catches on the main thread don't come here; errors are written
        // at once anyway. A handler installed earlier still runs after this one.
        previousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            SpotiglassLog.error(.persistence, "Uncaught exception \(exception.name.rawValue): \(exception.reason ?? "no reason")")
            SpotiglassLog.flush()
            SpotiglassLog.previousExceptionHandler?(exception)
        }
    }

    /// Waits until every line handed to the log so far is in the file. Lines go straight
    /// to the file descriptor, so once this returns they survive a crash.
    static func flush() {
        FileLogSink.shared.flush()
    }

    static func debug(_ category: Category, _ message: String) {
        osLoggers[category]?.debug("\(message, privacy: .private)")
        FileLogSink.shared.write(level: "DEBUG", category: category.rawValue, message: message)
    }

    /// Errors are written before this returns: they are the lines a crash right after
    /// must not lose.
    static func error(_ category: Category, _ message: String) {
        osLoggers[category]?.error("\(message, privacy: .private)")
        FileLogSink.shared.write(level: "ERROR", category: category.rawValue, message: message, synchronously: true)
    }

    static func info(_ category: Category, _ message: String) {
        osLoggers[category]?.info("\(message, privacy: .private)")
        FileLogSink.shared.write(level: "INFO", category: category.rawValue, message: message)
    }

    /// `text` in the log's quotes, “like this”: a search, a name, a response body. The full log
    /// keeps it as it is; the bug-report copy replaces everything in these quotes that isn't one
    /// of Wax's own words (#603).
    static func personal(_ text: String) -> String {
        "“\(text.replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\""))”"
    }

    /// An error with everything that explains it (#734): its domain, code and description, the
    /// URL it failed on, and the errors underneath it, so a failure in the log needs no guessing.
    /// Secrets (tokens, codes, cookies) are taken out by ``redactSecrets(_:)``.
    static func describe(_ error: Error) -> String {
        redactSecrets(describe(error, depth: 0))
    }

    private static func describe(_ error: Error, depth: Int) -> String {
        if let decodingError = error as? DecodingError {
            return describe(decodingError)
        }
        let nsError = error as NSError
        var text = "\(nsError.domain) \(nsError.code)"
        // Foundation's stand-in sentence ("The operation couldn't be completed") says no more
        // than the domain and code, so only a description the error carries goes in.
        let description = nsError.userInfo[NSLocalizedDescriptionKey] as? String
        if let description { text += ": \(description)" }
        // A Swift error's own description names its case and values; a bridged Foundation
        // error prints as "Error Domain=...", which repeats the above.
        let swiftDescription = String(describing: error)
        if swiftDescription != description, !swiftDescription.hasPrefix("Error Domain=") {
            text += " (\(swiftDescription))"
        }
        if let url = nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String {
            text += " url=\(url)"
        } else if let url = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
            text += " url=\(url.absoluteString)"
        }
        for key in [NSLocalizedFailureReasonErrorKey, NSDebugDescriptionErrorKey, NSLocalizedRecoverySuggestionErrorKey] {
            if let extra = nsError.userInfo[key] as? String, !text.contains(extra) {
                text += " \(key == NSDebugDescriptionErrorKey ? "debug" : "reason")=\(extra)"
            }
        }
        if depth < 4, let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            text += "; underlying: \(describe(underlying, depth: depth + 1))"
        }
        return text
    }

    private static func describe(_ decodingError: DecodingError) -> String {
        switch decodingError {
        case let .typeMismatch(_, context), let .valueNotFound(_, context),
             let .keyNotFound(_, context), let .dataCorrupted(context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return "could not decode the response at \(path.isEmpty ? "the top level" : path): \(context.debugDescription)"
        @unknown default:
            return "could not decode the response: \(decodingError)"
        }
    }

    /// Query items and headers that carry a secret. Their values never reach the log.
    private static let secretPatterns: [(NSRegularExpression?, String)] = [
        // A URL's query: `?code=...&state=...`, `access_token=...`.
        (pattern(#"(?i)\b(access_token|refresh_token|id_token|client_secret|code_verifier|token|password)=[^&\s"',;)]+"#), "$1=<hidden>"),
        // An OAuth `code=`, but not a bare number: `Code=-1001` in an error's own text is no secret.
        (pattern(#"(?i)\b(code)=(?!-?\d+(?:[&\s"',;)]|$))[^&\s"',;)]+"#), "$1=<hidden>"),
        // A header written out, `Authorization: Bearer ...`, `Cookie: ...`, or as a printed
        // dictionary, `"Music-User-Token": "..."` (MusicKit's request errors print their headers).
        (pattern(#"(?i)\b(proxy-authorization|authorization|set-cookie|cookie|password|music-user-token|media-user-token|x-apple-[a-z-]*token)("?\s*[:=]\s*"?)[^\n,;"]+"#), "$1$2<hidden>"),
        (pattern(#"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#), "Bearer <hidden>"),
    ]

    private static func pattern(_ pattern: String) -> NSRegularExpression? {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            // Constant patterns; FullLogTests.testSecretsAreHidden fails on a broken one.
            let diagnostics = Logger(subsystem: subsystem, category: "log-file")
            diagnostics.fault("Secret pattern does not compile: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// `text` with every token, code, cookie and password value replaced by `<hidden>`.
    static func redactSecrets(_ text: String) -> String {
        var result = text
        for (pattern, template) in secretPatterns {
            guard let pattern else { continue }
            result = pattern.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: template
            )
        }
        return result
    }

    /// The folder the log files go to: the real `Logs` folder for the app, a per-run
    /// temporary folder under the unit-test host.
    static func logDirectory(
        isRunningUnitTests: Bool = AppMetadata.isRunningUnitTests,
        applicationSupport: () throws -> URL = {
            try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }
    ) throws -> URL {
        if isRunningUnitTests {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("\(testLogFolderPrefix)\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        return try applicationSupport()
            .appendingPathComponent("\(AppMetadata.storageDirectoryName)/Logs", isDirectory: true)
    }
}

final class FileLogSink {
    static let shared = FileLogSink()

    /// A few hours of the full log (#734: every interaction, call and player change); four
    /// files of this size at most.
    static let defaultMaxBytes: UInt64 = 32 * 1024 * 1024

    static let currentFileName = "spotiglass.log"
    static let earlierFileName = "spotiglass.earlier.log"
    static let previousFileName = "spotiglass.previous.log"
    static let previousEarlierFileName = "spotiglass.previous.earlier.log"

    private let queue = DispatchQueue(label: "com.isaaclins.spotiglass.filelog", qos: .utility)
    private let directory: () throws -> URL
    private let maxBytes: UInt64
    private let moveItem: (URL, URL) throws -> Void
    private let diagnostics = Logger(subsystem: AppMetadata.bundleIdentifier, category: "log-file")
    private var handle: FileHandle?
    private var bytesWritten: UInt64 = 0
    /// Set when the previous session's file could not be moved aside and this session appends to it.
    private var holdsPreviousSession = false
    private var booted = false
    private var _fileURL: URL?

    var fileURL: URL? { queue.sync { _fileURL } }

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(
        directory: @escaping () throws -> URL = { try SpotiglassLog.logDirectory() },
        maxBytes: UInt64 = FileLogSink.defaultMaxBytes,
        moveItem: @escaping (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    ) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.moveItem = moveItem
    }

    func boot() {
        queue.sync {
            guard !booted else { return }
            booted = true
            let dir: URL
            do {
                dir = try directory()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                diagnostics.error("Log folder unavailable, the log file stays off this session: \(String(describing: error), privacy: .public)")
                return
            }
            let url = dir.appendingPathComponent(Self.currentFileName)
            // Keep the previous session's log: a crash followed by a relaunch must not wipe
            // the evidence users are asked to attach to bug reports.
            var rotationNote: String?
            if FileManager.default.fileExists(atPath: url.path) {
                let previousURL = dir.appendingPathComponent(Self.previousFileName)
                let earlierURL = dir.appendingPathComponent(Self.earlierFileName)
                let previousEarlierURL = dir.appendingPathComponent(Self.previousEarlierFileName)
                do {
                    for old in [previousURL, previousEarlierURL] where FileManager.default.fileExists(atPath: old.path) {
                        try FileManager.default.removeItem(at: old)
                    }
                    try moveItem(url, previousURL)
                } catch {
                    // Appending keeps the previous session's lines; the size cap below still holds.
                    holdsPreviousSession = true
                    rotationNote = "Could not move the previous session's log aside (\(SpotiglassLog.describe(error))); appending to it instead"
                    diagnostics.error("\(rotationNote ?? "", privacy: .public)")
                }
                // The first part of a long session that just ended stays with it.
                if rotationNote == nil, FileManager.default.fileExists(atPath: earlierURL.path) {
                    do {
                        try moveItem(earlierURL, previousEarlierURL)
                    } catch {
                        diagnostics.error("Could not keep the previous session's earlier log (\(String(describing: error), privacy: .public)); this session's overflow replaces it")
                    }
                }
            }
            guard open(url, header: "=== Wax log started \(Self.formatter.string(from: Date())) ===\n") else { return }
            if let rotationNote {
                append(Self.line(level: "ERROR", category: "log-file", message: rotationNote))
            }
        }
    }

    func write(level: String, category: String, message: String, synchronously: Bool = false) {
        let line = Self.line(level: level, category: category, message: message)
        if synchronously {
            queue.sync { append(line) }
        } else {
            queue.async { [weak self] in self?.append(line) }
        }
    }

    func flush() {
        queue.sync {
            try? handle?.synchronize() // Lines are already in the kernel; this only adds fsync.
        }
    }

    private static func line(level: String, category: String, message: String) -> String {
        "\(formatter.string(from: Date())) [\(level)] [\(category)] \(oneLine(message))\n"
    }

    /// Every entry is one line: a newline or other control character in a message (a response
    /// body, an error from outside) is written escaped, so it can't start a line of its own that
    /// looks like Wax wrote it (#603, #594).
    static func oneLine(_ message: String) -> String {
        guard message.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return message }
        var result = ""
        result.reserveCapacity(message.utf8.count + 8)
        for scalar in message.unicodeScalars {
            switch scalar {
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.properties.generalCategory == .control {
                    result += "\\u{\(String(scalar.value, radix: 16))}"
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }

    /// Opens `url` for appending (creating it when missing). Says in Console when it can't.
    private func open(_ url: URL, header: String) -> Bool {
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                diagnostics.error("Could not create the log file at \(url.path, privacy: .public)")
                return false
            }
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            bytesWritten = try handle.seekToEnd()
            self.handle = handle
            _fileURL = url
        } catch {
            diagnostics.error("Could not open the log file at \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
        append(header)
        return true
    }

    private func append(_ line: String) {
        guard handle != nil else { return }
        let data = Data(line.utf8)
        if bytesWritten + UInt64(data.count) > maxBytes, bytesWritten > 0 {
            rotateWithinSession()
        }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            bytesWritten += UInt64(data.count)
        } catch {
            diagnostics.error("Writing to the log file failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The current file is full: it becomes `spotiglass.earlier.log` (replacing an older
    /// part of this session) and a fresh file continues under the same name.
    private func rotateWithinSession() {
        guard let url = _fileURL else { return }
        let earlierURL = url.deletingLastPathComponent().appendingPathComponent(Self.earlierFileName)
        try? handle?.close() // The file is moved next; a failed close only leaks a descriptor.
        handle = nil
        let stamp = Self.formatter.string(from: Date())
        let header: String
        do {
            if FileManager.default.fileExists(atPath: earlierURL.path) {
                try FileManager.default.removeItem(at: earlierURL)
            }
            try moveItem(url, earlierURL)
            header = "=== Log continued \(stamp), earlier lines in \(Self.earlierFileName) ===\n"
        } catch {
            if holdsPreviousSession {
                // Starting over would empty the previous session's lines, which a report needs
                // most; the file stops here and Console keeps the rest of this session.
                diagnostics.error("Could not move the full log aside (\(String(describing: error), privacy: .public)); the file stops, Console keeps logging")
                if let stopped = try? FileHandle(forWritingTo: url) {
                    _ = try? stopped.seekToEnd()
                    try? stopped.write(contentsOf: Data("=== Log file full at \(stamp) and could not be moved aside; the rest of this session is in Console only ===\n".utf8))
                    try? stopped.close() // Best effort: the line only explains the end of the file.
                }
                return
            }
            // Without the move the only way to stay under the cap is to start this session's
            // file over; it holds this session's lines only.
            diagnostics.error("Could not move the full log aside (\(String(describing: error), privacy: .public)); starting it over")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            header = "=== Log started over \(stamp): the full log could not be moved aside (\(SpotiglassLog.describe(error))) ===\n"
        }
        holdsPreviousSession = false
        _ = open(url, header: header)
    }
}

/// The log as it goes into a public bug report (#603). The log on the Mac keeps everything Wax
/// does (#734); this copy keeps what explains a failure (levels, categories, times, status and
/// error codes, counts, Wax's own words) and replaces what belongs to the person: text in the
/// log's quotes (``SpotiglassLog/personal(_:)``: searches, names, bodies), song, album, playlist,
/// library and queue IDs, Connect and other device IDs, the query of every address, the user in
/// a Spotify path, typed keys and the home folder's name. Each value gets a stand-in like
/// `#3f2a9c` that is the same everywhere in one copy, so "the player went from #3f2a9c to
/// #9c1d04" still reads; a new copy uses new stand-ins, so two reports can't be matched up.
enum BugReportLogCopy {
    /// The log files in the order they were written: the previous session, then this one.
    static func sourceFiles(in folder: URL) -> [URL] {
        [FileLogSink.previousEarlierFileName, FileLogSink.previousFileName, FileLogSink.earlierFileName, FileLogSink.currentFileName]
            .map { folder.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Writes the cleaned copy of every log file in `folder` to `destination`. The four files
    /// can hold 128 MB, so each is cleaned in pieces on all cores; a stand-in depends only on
    /// the value and this copy's salt, so the pieces agree on it.
    static func write(from folder: URL, to destination: URL, keeping ownWords: Set<String> = appWords()) throws {
        let salt = Data((0 ..< 16).map { _ in UInt8.random(in: 0 ... 255) })
        var output = Data("=== Wax log for a bug report, saved \(ISO8601DateFormatter().string(from: Date())). Searches, names, IDs and addresses are replaced by stand-ins like #3f2a9c. ===\n".utf8)
        for file in sourceFiles(in: folder) {
            let text = try String(contentsOf: file, encoding: .utf8)
            output.append(Data("=== \(file.lastPathComponent) ===\n".utf8))
            let pieces = Self.pieces(of: text)
            let cleaned = OSAllocatedUnfairLock(initialState: [String](repeating: "", count: pieces.count))
            DispatchQueue.concurrentPerform(iterations: pieces.count) { index in
                var cleaner = Cleaner(ownWords: ownWords, salt: salt)
                let piece = cleaner.clean(String(pieces[index]))
                cleaned.withLock { $0[index] = piece }
            }
            for piece in cleaned.withLock({ $0 }) {
                output.append(Data(piece.utf8))
            }
            if !text.hasSuffix("\n") { output.append(Data("\n".utf8)) }
        }
        try output.write(to: destination, options: .atomic)
    }

    /// `text` cut at line ends into pieces of about `size` characters.
    static func pieces(of text: String, size: Int = 256 * 1024) -> [Substring] {
        var pieces: [Substring] = []
        var start = text.startIndex
        while start < text.endIndex {
            var end = text.index(start, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            if end < text.endIndex {
                end = text[end...].firstIndex(of: "\n").map { text.index(after: $0) } ?? text.endIndex
            }
            pieces.append(text[start ..< end])
            start = end
        }
        return pieces
    }

    /// Every word and sentence Wax itself shows, in every language it ships: a control named
    /// “Next” or “Shuffle” stays readable in the copy, a song or playlist name doesn't.
    static func appWords(bundle: Bundle = .main) -> Set<String> {
        var words: Set<String> = [AppMetadata.displayName, "\(AppMetadata.displayName) Settings", "Settings"]
        for localization in bundle.localizations {
            for table in ["Localizable", "InfoPlist"] {
                guard let url = bundle.url(forResource: table, withExtension: "strings", subdirectory: nil, localization: localization),
                      let strings = NSDictionary(contentsOf: url) as? [String: String] else { continue }
                words.formUnion(strings.values)
            }
        }
        return words
    }

    struct Cleaner {
        let ownWords: Set<String>
        /// Random for each copy, so a stand-in can't be worked back to a value by trying names.
        private let salt: Data
        private var standIns: [String: String] = [:]

        init(ownWords: Set<String>, salt: Data) {
            self.ownWords = ownWords
            self.salt = salt
        }

        mutating func clean(_ text: String) -> String {
            var result = text
            // The previous session's file may come from a build before #603, which wrote these
            // names without the log's quotes. Put them in quotes, so the rule below replaces them.
            for pattern in Self.unquotedNames {
                result = quoteGroups(pattern, in: result)
            }
            // Quotes first: what's inside them is replaced as a whole, before the shape rules
            // below could take pieces of it.
            result = replace(Self.quoted, in: result) { cleaner, match in
                let inner = String(match.dropFirst().dropLast())
                if inner.isEmpty || cleaner.ownWords.contains(inner) { return match }
                return "“\(cleaner.standIn(inner))”"
            }
            result = replace(Self.homeFolder, in: result) { _, _ in "/Users/<user>" }
            result = replace(Self.query, in: result) { _, match in
                // Whatever came before the `?` (the end of a path) stays.
                (match.first == "?" ? "" : String(match.prefix(1))) + "?<query>"
            }
            // A cover's address names the album it belongs to; the stand-in still ties the
            // lines of one cover together.
            result = replace(Self.coverAddress, in: result) { cleaner, match in
                guard let slash = match.range(of: "/", range: match.index(match.startIndex, offsetBy: 8) ..< match.endIndex) else { return match }
                return "\(match[..<slash.lowerBound])/\(cleaner.standIn(String(match[slash.upperBound...])))"
            }
            result = replace(Self.serviceURI, in: result) { cleaner, match in
                let parts = match.split(separator: ":", maxSplits: 2).map(String.init)
                return "\(parts[0]):\(parts[1]):\(cleaner.standIn(parts[2]))"
            }
            result = replace(Self.spotifyUser, in: result) { cleaner, match in
                "/users/\(cleaner.standIn(String(match.dropFirst("/users/".count))))"
            }
            result = replace(Self.identifierValue, in: result) { cleaner, match in
                guard let equals = match.firstIndex(of: "=") else { return match }
                let key = match[..<equals]
                let value = String(match[match.index(after: equals)...])
                // A service URI already carries its stand-in (`applemusic:song:#3f2a9c`) and keeps its kind.
                if ["<nil>", "nil", "none", "?"].contains(value) || cleaner.isStandIn(value) || value.contains(":#") { return match }
                return "\(key)=\(cleaner.standIn(value))"
            }
            // `catalog artist 909253 top songs`: older catalog IDs are shorter than the shapes below.
            result = replace(Self.namedCatalogID, in: result) { cleaner, match in
                guard let space = match.lastIndex(of: " ") else { return match }
                return "\(match[...space])\(cleaner.standIn(String(match[match.index(after: space)...])))"
            }
            for shape in Self.identifierShapes {
                result = replace(shape, in: result) { cleaner, match in
                    cleaner.isStandIn(match) ? match : cleaner.standIn(match)
                }
            }
            result = replace(Self.typedKey, in: result) { _, _ in "key ·" }
            return result
        }

        private mutating func standIn(_ value: String) -> String {
            if let known = standIns[value] { return known }
            var data = salt
            data.append(Data(value.utf8))
            let digest = SHA256.hash(data: data)
            let standIn = "#" + digest.prefix(3).map { String(format: "%02x", $0) }.joined()
            standIns[value] = standIn
            return standIn
        }

        private func isStandIn(_ value: String) -> Bool {
            value.count == 7 && value.first == "#"
        }

        /// Every captured group of `pattern` in `text`, put in the log's quotes.
        private func quoteGroups(_ pattern: NSRegularExpression?, in text: String) -> String {
            guard let pattern else { return text }
            let result = NSMutableString(string: text)
            for match in pattern.matches(in: text, range: NSRange(location: 0, length: result.length)).reversed() {
                for group in (1 ..< match.numberOfRanges).reversed() where match.range(at: group).location != NSNotFound {
                    let range = match.range(at: group)
                    let inner = result.substring(with: range).replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
                    result.replaceCharacters(in: range, with: "“\(inner)”")
                }
            }
            return result as String
        }

        private mutating func replace(
            _ pattern: NSRegularExpression?,
            in text: String,
            with replacement: (inout Cleaner, String) -> String
        ) -> String {
            guard let pattern else { return text }
            let source = text as NSString
            var result = ""
            var last = 0
            for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
                let range = match.range
                result += source.substring(with: NSRange(location: last, length: range.location - last))
                result += replacement(&self, source.substring(with: range))
                last = range.location + range.length
            }
            guard last > 0 else { return text }
            result += source.substring(from: last)
            return result
        }

        private static func pattern(_ text: String) -> NSRegularExpression? {
            // try?: constant patterns; a broken one leaves its value in and the copy test fails.
            try? NSRegularExpression(pattern: text)
        }

        /// Names that builds before #603 wrote without quotes: a palette search, the song that
        /// came on in Apple Music, the album search behind a pin and Autoplay's artist search.
        private static let unquotedNames: [NSRegularExpression?] = [
            pattern(#"palette search '(.*?)'(?= provider| answered|$)"#),
            pattern(#"current entry -> \S+ "(.*?)"(?: by (.*?))? (?=\(position )"#),
            pattern(#"album search for a pin \((?!“)(.*) / (.*?)\)(?= done| failed| \(after|$)"#),
            pattern(#"autoplay artist search \((?!“)(.*?)\)(?= done| failed| \(after|$)"#),
        ]
        /// “…”: ``SpotiglassLog/personal(_:)``, control and window names in interaction lines.
        private static let quoted = pattern(#"“[^“”\n]*”"#)
        private static let homeFolder = pattern(#"/Users/[^/\s"'”]+"#)
        /// A query: `?q=night&type=track` after an address or path.
        private static let query = pattern(#"[^\s]?\?[A-Za-z_][\w.\[\]-]*=[^\s"'”)]*"#)
        /// Cover art on Apple's and Spotify's image servers.
        private static let coverAddress = pattern(#"https?://[^/\s]*(?:mzstatic\.com|scdn\.co|spotifycdn\.com)/[^\s"'”)]+"#)
        /// `spotify:track:6rqhFgbbKwnb9MLmUQDhG6`, `applemusic:song:4651336237147474264`.
        private static let serviceURI = pattern(#"\b(?:spotify|applemusic):[a-z]+:[^\s,;)'"\]]+"#)
        /// `/v1/users/<name>/playlists`: a Spotify user ID is often the person's name.
        private static let spotifyUser = pattern(#"/users/[^/\s?"'”)]+"#)
        /// `deviceID=…`, `playlistID=…`, `clickedURI=…`, `uid=…`: every value of a key that names an identifier.
        private static let identifierValue = pattern(#"\b(?:\w*(?:ID|Id|URI|Uri|UID|Uid)|id|uri|uid|\w+_id)=[^\s,;)\]"'”]+"#)
        /// A short catalog ID after the kind it names, as MusicKit call names write it.
        private static let namedCatalogID = pattern(#"\b(?:album|song|artist|playlist) \d{5,8}\b"#)
        private static let identifierShapes: [NSRegularExpression?] = [
            // UUIDs: queue entries, sessions.
            pattern(#"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#),
            // MusicKit queue entry IDs, `b7aXaLAhy::5GlvfRUeI`.
            pattern(#"\b\w+::\w+\b"#),
            // MusicKit library and catalog IDs: `i.KoJeg8VC4v3Bo`, `p.QvDQE5RIVbzOel`, `pl.u-…`.
            pattern(#"\b(?:i|l|p|pl|r|ra)\.[A-Za-z0-9_-]{6,}\b"#),
            // Long hex: Spotify Connect device IDs, hashes.
            pattern(#"\b[0-9a-fA-F]{24,}\b"#),
            // Spotify's base-62 IDs, always 22 letters and digits with at least one digit.
            pattern(#"\b(?=[0-9A-Za-z]*\d)[0-9A-Za-z]{22}\b"#),
            // Catalog and persistent IDs: nine or more digits.
            pattern(#"(?<![\w.:])-?\d{9,}\b"#),
        ]
        /// `key A` in an interaction line: a letter or digit typed into a field. Shortcuts and
        /// named keys (`shortcut ⌘F`, `key Return`) stay.
        private static let typedKey = pattern(#"\bkey [^\s;](?=[\s;]|$)"#)
    }
}
