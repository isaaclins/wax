import Foundation

/// What a failure says on screen, before it is reported: a feature's mapping from an error to
/// words. Views never take one of these; they take the ``DisplayError`` that
/// ``ErrorReporting/report(_:while:in:context:level:showing:)`` returns, so a failure that is
/// shown has always been logged (#608).
struct ErrorMessage: Equatable {
    /// The way out a failure offers. The view decides what the button does; the message only
    /// says which one makes sense.
    enum Action: Equatable {
        /// Do the same thing again.
        case retry
        /// Connect the player again.
        case reconnect
        /// Sign in again.
        case reauthenticate
        /// Move playback to this Mac again.
        case retryTransfer
    }

    /// Looked up when shown, so an error on screen follows a language switch (#548).
    var titleText: LocalizedText
    var messageText: LocalizedText
    var action: Action?
    /// A request line, a status, a server body: for a bug report, behind a button (#148).
    var diagnosticDetails: String?
    /// A Spotify playlist the user follows but whose songs Spotify no longer lists (HTTP 403).
    var lockedPlaylist: LockedPlaylistInfo?
    /// One command failed and the thing itself is fine: shown for a moment, not kept (#430).
    var isMomentary = false

    /// `title` names the failure in the log and on a full page; a banner or toast shows only
    /// the message, so most of them leave the general title.
    init(
        title: @autoclosure @escaping () -> String = SpotiglassL10n.string("error.browsing.generic.title"),
        message: @autoclosure @escaping () -> String,
        action: Action? = nil,
        diagnosticDetails: String? = nil,
        lockedPlaylist: LockedPlaylistInfo? = nil,
        isMomentary: Bool = false
    ) {
        self.titleText = LocalizedText(title())
        self.messageText = LocalizedText(message())
        self.action = action
        self.diagnosticDetails = diagnosticDetails
        self.lockedPlaylist = lockedPlaylist
        self.isMomentary = isMomentary
    }

    /// A browsing failure: Retry or nothing.
    init(
        title: @autoclosure @escaping () -> String,
        message: @autoclosure @escaping () -> String,
        canRetry: Bool,
        diagnosticDetails: String? = nil,
        lockedPlaylist: LockedPlaylistInfo? = nil
    ) {
        self.init(
            title: title(),
            message: message(),
            action: canRetry ? .retry : nil,
            diagnosticDetails: diagnosticDetails,
            lockedPlaylist: lockedPlaylist
        )
    }

    var title: String { titleText.string }
    var message: String { messageText.string }
}

/// A failure as the user sees it. Only ``ErrorReporting/report(_:while:in:context:level:showing:)``
/// makes one, after writing the failure to the log, so showing an error without logging it
/// isn't possible (#608). Which of the three surfaces shows it is up to the view: a full page
/// (``ErrorPage``) when nothing could load, a banner (``ErrorBanner``) over data that is stale
/// or partial, a toast (``ErrorToast``) for a one-off action.
struct DisplayError: Error, Equatable, Identifiable {
    let id = UUID()
    private let content: ErrorMessage

    fileprivate init(_ content: ErrorMessage) {
        self.content = content
    }

    var title: String { content.title }
    var message: String { content.message }
    var action: ErrorMessage.Action? { content.action }
    var canRetry: Bool { content.action == .retry }
    var diagnosticDetails: String? { content.diagnosticDetails }
    var lockedPlaylist: LockedPlaylistInfo? { content.lockedPlaylist }
    var isMomentary: Bool { content.isMomentary }

    /// The same reported failure, told differently: a view model that learns more about where
    /// it is shown (no Reconnect on this player) changes the words without a second log line.
    func with(_ change: (inout ErrorMessage) -> Void) -> DisplayError {
        var content = content
        change(&content)
        return DisplayError(content)
    }

    /// Two reports of the same failure compare equal, so a view doesn't redraw for a repeat.
    static func == (lhs: DisplayError, rhs: DisplayError) -> Bool {
        lhs.content == rhs.content
    }
}

/// One named value that explains a failure in the log, such as a playlist ID or an HTTP status.
/// A private value (a search, a name, an ID that points at someone's library) is written through
/// ``SpotiglassLog/personal(_:)``: the log file on the Mac keeps it, the bug-report copy replaces
/// it with a stand-in (#603).
struct LogField: Equatable {
    let name: String
    let value: String
    let isPrivate: Bool

    static func `public`(_ name: String, _ value: CustomStringConvertible) -> LogField {
        LogField(name: name, value: value.description, isPrivate: false)
    }

    static func `private`(_ name: String, _ value: CustomStringConvertible) -> LogField {
        LogField(name: name, value: value.description, isPrivate: true)
    }
}

/// The one path a failure takes to the screen and the log (#608).
enum ErrorReporting {
    enum Level {
        /// Something went wrong.
        case error
        /// Expected and handled, such as a rate limit the app waits out; still worth a line.
        case info
        /// The line was already written where the failure was caught: one token refresh that
        /// many requests wait on logs once there, and each of them shows it (#602, #608).
        case loggedWhereCaught
    }

    /// Writes `error` to the log once, with what was being done and the fields that explain it,
    /// and returns what to show for it.
    ///
    /// - Parameters:
    ///   - error: The failure, or `nil` when there is none to name (a state, not a thrown error).
    ///   - operation: What the app was doing, in plain words: "loading playlist tracks".
    ///   - category: The log category the feature writes to.
    ///   - context: Fields that explain the failure; mark anything about the user's library `.private`.
    ///   - level: `.info` for failures the app expects and handles.
    ///   - message: What the user sees.
    @discardableResult
    static func report(
        _ error: (any Error)?,
        while operation: String,
        in category: SpotiglassLog.Category,
        context: [LogField] = [],
        level: Level = .error,
        showing message: ErrorMessage
    ) -> DisplayError {
        let line = logLine(error, while: operation, shown: message, context: context)
        switch level {
        case .error:
            SpotiglassLog.error(category, line)
        case .info:
            SpotiglassLog.info(category, line)
        case .loggedWhereCaught:
            break
        }
        return DisplayError(message)
    }

    /// `"<operation> failed: <error>; shown "<title>" [name=value ...]"`: one line, the same
    /// shape for every feature, so a search for "failed:" finds every failure in the log.
    private static func logLine(
        _ error: (any Error)?,
        while operation: String,
        shown message: ErrorMessage,
        context: [LogField]
    ) -> String {
        var line = "\(operation) failed"
        if let error {
            line += ": \(SpotiglassLog.describe(error))"
        }
        line += "; shown \"\(message.title)\""
        if let action = message.action {
            line += " with \(action)"
        }
        if !context.isEmpty {
            line += " " + fieldsText(context)
        }
        return line
    }

    private static func fieldsText(_ fields: [LogField]) -> String {
        fields.map { field in
            let value = SpotiglassLog.redactSecrets(field.value)
            return "\(field.name)=\(field.isPrivate ? SpotiglassLog.personal(value) : value)"
        }.joined(separator: " ")
    }
}
