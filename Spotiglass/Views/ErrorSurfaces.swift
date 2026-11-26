import AppKit
import SwiftUI

// The three ways a failure reaches the screen (#608). Every feature uses one of them with the
// ``DisplayError`` that ``ErrorReporting/report(_:while:in:context:level:showing:)`` returned:
//
// - ``ErrorPage``: nothing could load, so the failure takes the place of the content.
// - ``ErrorBanner``: what is shown is stale or partial, or a setting didn't take; one calm line.
// - ``ErrorToast``: a one-off action failed (or finished) and the screen is otherwise fine.
//
// Empty states are only for real emptiness.

/// A failure that takes the place of a page: what happened, Retry when asking again can help,
/// and the request details behind a button for a bug report (#148).
struct ErrorPage<Actions: View>: View {
    let error: DisplayError
    var systemImage = "exclamationmark.triangle"
    /// Loads what failed again; without it the page only explains the failure.
    var retry: (() -> Void)?
    let actions: Actions
    @State private var isShowingDiagnosticAlert = false

    init(
        error: DisplayError,
        systemImage: String = "exclamationmark.triangle",
        retry: (() -> Void)? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        self.error = error
        self.systemImage = systemImage
        self.retry = retry
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: SpotiglassDesign.spacingM) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(error.title)
                .font(.title3.weight(.semibold))

            Text(error.message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: SpotiglassDesign.Layout.messageMaxWidth)

            if let retry {
                Button(SpotiglassL10n.string("browser.retry"), action: retry)
            }

            actions

            // The details are a request line, a status, a header dump and a raw
            // JSON body. That is for a bug report, not for someone who wanted a
            // playlist, so it waits behind a button instead of opening itself
            // over the window (#148).
            if let diagnosticDetails = error.diagnosticDetails {
                Button(SpotiglassL10n.string("browser.showDetails")) {
                    isShowingDiagnosticAlert = true
                }
                .buttonStyle(.link)
                .help(SpotiglassL10n.string("browser.showDetails.hint"))
                .alert(error.title, isPresented: $isShowingDiagnosticAlert) {
                    Button(SpotiglassL10n.string("browser.copyError")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(diagnosticDetails, forType: .string)
                    }
                    Button(SpotiglassL10n.string("browser.ok"), role: .cancel) {}
                } message: {
                    Text(SpotiglassL10n.string("browser.diagnostics.message"))
                }
            }
        }
        .padding(SpotiglassDesign.spacingL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

extension ErrorPage where Actions == EmptyView {
    init(error: DisplayError, systemImage: String = "exclamationmark.triangle", retry: (() -> Void)? = nil) {
        self.init(error: error, systemImage: systemImage, retry: retry) { EmptyView() }
    }
}

/// One calm line about a failure next to what still works: stale or partial data, a setting
/// that didn't take. Retry and Dismiss when the caller offers them, as links after the text.
struct ErrorBanner: View {
    enum Style {
        /// In the layout, like a row: Settings, the queue panel, a Home section.
        case inline
        /// Over content at the bottom of a list, on its own background.
        case floating
    }

    let error: DisplayError?
    var style: Style = .inline
    /// Shows the title before the message, for a banner with no heading around it.
    var showsTitle = false
    var retry: (() -> Void)?
    var dismiss: (() -> Void)?

    /// A banner over cached data with no error of its own says the data is from before.
    private var message: String {
        error?.message ?? SpotiglassL10n.format("browser.cachedFallback", MusicServiceSelection.current.displayName)
    }

    var body: some View {
        switch style {
        case .inline:
            BannerLine(sentence, help: message) { buttons }
        case .floating:
            HStack(alignment: .firstTextBaseline, spacing: SpotiglassDesign.spacingS) {
                sentence
                    .multilineTextAlignment(.center)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(message)
                buttons
            }
            .font(.caption)
            .padding(SpotiglassDesign.spacingS)
            .background(.background, in: Capsule())
            .padding(SpotiglassDesign.spacingM)
            .accessibilityElement(children: .contain)
        }
    }

    private var sentence: Text {
        if showsTitle, let error {
            Text("\(Text(error.title).fontWeight(.semibold)) \(error.message)")
        } else {
            Text(message)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if let retry {
            Button(SpotiglassL10n.string("browser.retry"), action: retry)
                .buttonStyle(.link)
        }
        if let dismiss {
            Button(SpotiglassL10n.string("queue.dismiss"), action: dismiss)
                .buttonStyle(.link)
        }
    }
}

/// The inline banner's line: a triangle, the sentence, link buttons after it. ``ErrorBanner``
/// draws a reported failure with it; a notice that follows one (the copy kept of a file that
/// couldn't be read, rows of a file that were left out) uses it with its own actions.
struct BannerLine<Actions: View>: View {
    let text: Text
    let help: String
    let actions: Actions

    init(_ text: Text, help: String, @ViewBuilder actions: () -> Actions) {
        self.text = text
        self.help = help
        self.actions = actions()
    }

    init(_ string: String, @ViewBuilder actions: () -> Actions) {
        self.init(Text(string), help: string, actions: actions)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SpotiglassDesign.spacingS) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            text
                .multilineTextAlignment(.leading)
                .lineLimit(nil)
                // A narrow panel offers one line; the sentence wraps instead of ending in "…" (#470).
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(help)
            actions
                .buttonStyle(.link)
        }
        .font(.callout)
        .accessibilityElement(children: .contain)
    }
}

/// What a toast says: an action that went through, or one that failed (reported).
enum ToastMessage: Equatable {
    case done(LocalizedText)
    case failed(DisplayError)

    var text: String {
        switch self {
        case .done(let text): text.string
        case .failed(let error): error.message
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// A one-off action's result for a moment at the bottom of the window, then gone. Drawn over
/// whatever the page shows, loading and errors included, so it never waits for a state that
/// can show it.
struct ErrorToast: View {
    let message: ToastMessage

    static let displayDuration: Duration = .milliseconds(2_400)

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SpotiglassDesign.spacingS) {
            if message.isFailure {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(message.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, SpotiglassDesign.spacingM)
        .padding(.vertical, SpotiglassDesign.spacingS)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, SpotiglassDesign.spacingL)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Shows `message` as an ``ErrorToast`` at the bottom and clears it after a moment.
    func toast(_ message: Binding<ToastMessage?>) -> some View {
        overlay(alignment: .bottom) {
            if let shown = message.wrappedValue {
                ErrorToast(message: shown)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: shown) {
                        // VoiceOver says it: it is gone before anyone could move to it.
                        AccessibilityNotification.Announcement(shown.text).post()
                        try? await Task.sleep(for: ErrorToast.displayDuration)  // try?: a cancelled wait means a newer toast replaced this one
                        if message.wrappedValue == shown {
                            message.wrappedValue = nil
                        }
                    }
            }
        }
    }
}
