@testable import Spotiglass

extension DisplayError {
    /// A reported error for a test that sets up a screen in a failed state. It goes through
    /// ``ErrorReporting/report(_:while:in:context:level:showing:)`` like the app's own (#608).
    static func reported(_ message: ErrorMessage) -> DisplayError {
        ErrorReporting.report(nil, while: "setting up a test", in: .browsing, level: .info, showing: message)
    }
}

extension ErrorMessage {
    var canRetry: Bool { action == .retry }
}
