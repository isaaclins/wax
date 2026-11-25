import AppKit
import SwiftUI

enum CommandPaletteSearchFocusField {
    case query
}

/// Whether this window's command palette is open, for the views behind it that change then: the
/// toolbar items and the page step out of VoiceOver's reach (#501), the Search page hides its own
/// field (#472). Those views observe it; the environment only carries the object, which stays the
/// same. As an environment value that changed on open and close, every AppKit control in the
/// window was updated each time (#671).
@MainActor
final class CommandPalettePresence: ObservableObject {
    /// For views outside a window with a palette (previews, tests): never open.
    static let none = CommandPalettePresence()

    /// The panel on screen. Follows the palette at once: this is what ⌘K and esc show.
    @Published private(set) var isShown = false
    /// Everything else that follows the palette: the page hidden from VoiceOver, the Search page's
    /// field stepped aside, the panel's own controls usable. It follows one run-loop turn after
    /// ``isShown``, so that work lands after the frame that shows or hides the panel instead of
    /// holding it back past 50 ms (#671). Nobody can tell a frame's difference in any of it.
    @Published private(set) var isPresented = false

    func set(_ presented: Bool) {
        guard isShown != presented else { return }
        isShown = presented
        afterThisFrame { [weak self] in
            // An open and a close in the same turn end where they started.
            guard let self, self.isShown == presented, self.isPresented != presented else { return }
            self.isPresented = presented
        }
    }
}

/// Runs `work` on the main run loop right after it commits the frame being built now. A timer due
/// at once fires after the commit, in any run-loop mode and also inside a run loop run from
/// main-queue work, where a main-queue block would have to wait for that work to end.
@MainActor
func afterThisFrame(_ work: @escaping @MainActor () -> Void) {
    let timer = Timer(timeInterval: 0, repeats: false) { _ in
        MainActor.assumeIsolated(work)
    }
    RunLoop.main.add(timer, forMode: .common)
}

extension EnvironmentValues {
    @Entry var commandPalettePresence: CommandPalettePresence = MainActor.assumeIsolated { .none }
}

extension View {
    /// Makes the palette modal over this content: while it is open the dimmed page is out of
    /// VoiceOver's reach until it closes, like a sheet (#501), and the views in it that observe
    /// `presence` know the palette is open (the Search page hides its own field then, #472). The
    /// palette itself has to sit outside this content, in an overlay, to stay reachable.
    func commandPaletteModal(_ presence: CommandPalettePresence) -> some View {
        modifier(HiddenFromAccessibilityWhilePresented(presence: presence))
            .environment(\.commandPalettePresence, presence)
    }

    /// Shows `viewModel`'s palette over this content, modal while it is open.
    func commandPalettePresentation(_ viewModel: CommandPaletteViewModel) -> some View {
        modifier(CommandPalettePresentation(viewModel: viewModel))
    }

    /// Takes a toolbar item out of VoiceOver's reach while the palette is open. The toolbar lives
    /// outside the window's content, so hiding the dimmed page alone left its buttons reachable
    /// behind the palette (#501).
    func hiddenFromAccessibilityBehindPalette() -> some View {
        modifier(HiddenFromAccessibilityBehindPalette())
    }
}

/// The palette over the window's page. It observes only whether the palette is open, so typing
/// in it runs only the palette's own views, and opening or closing it runs this and the palette:
/// observed by the window's root, each of them ran the whole window's body and the menu bar's
/// again first (#671).
private struct CommandPalettePresentation: ViewModifier {
    let viewModel: CommandPaletteViewModel
    @ObservedObject var presence: CommandPalettePresence

    init(viewModel: CommandPaletteViewModel) {
        self.viewModel = viewModel
        presence = viewModel.presence
    }

    func body(content: Content) -> some View {
        content
            .commandPaletteModal(presence)
            .overlay {
                // Built once and kept, hidden while closed: building it on each ⌘K (its field,
                // materials and list) took the frame past 50 ms (#671).
                CommandPaletteView(viewModel: viewModel)
                    .opacity(presence.isShown ? 1 : 0)
                    .scaleEffect(presence.isShown ? 1 : 0.97)
                    .allowsHitTesting(presence.isShown)
                    // Closed, its field can't take focus (Tab from a field on the page).
                    .disabled(!presence.isPresented)
                    .accessibilityHidden(!presence.isPresented)
                    .animation(.spring(response: 0.32, dampingFraction: 0.86), value: presence.isShown)
            }
    }
}

private struct HiddenFromAccessibilityBehindPalette: ViewModifier {
    @Environment(\.commandPalettePresence) private var presence

    func body(content: Content) -> some View {
        content.modifier(HiddenFromAccessibilityWhilePresented(presence: presence))
    }
}

private struct HiddenFromAccessibilityWhilePresented: ViewModifier {
    @ObservedObject var presence: CommandPalettePresence

    func body(content: Content) -> some View {
        content.accessibilityHidden(presence.isPresented)
    }
}

/// The command palette: one panel near the top of the window, like Spotlight, holding the
/// field, the filters, the results and a footer with the key hints (#472).
struct CommandPaletteView: View {
    @ObservedObject var viewModel: CommandPaletteViewModel
    @EnvironmentObject private var settingsStore: SpotiglassSettingsStore

    @FocusState private var focusedField: CommandPaletteSearchFocusField?
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.isEnabled) private var isEnabled
    /// Height the palette can use; starts tall so the first frame sits at the full inset.
    @State private var availableHeight: CGFloat = .infinity

    /// Space above the panel: the Spotlight-like top inset in a tall window, shrinking to
    /// `spacingS` as the window gets short, so the space gives way before the results do.
    static func topInset(forAvailableHeight height: CGFloat) -> CGFloat {
        min(SpotiglassDesign.Layout.paletteTopInset, max(SpotiglassDesign.spacingS, ((height - 300) / 4).rounded()))
    }

    var body: some View {
        ZStack(alignment: .top) {
            CommandPaletteBackdropView(
                backdropBlur: settingsStore.settings.commandPalette.backdropBlur,
                onDismiss: { viewModel.hide() }
            )

            VStack(spacing: 0) {
                // The space above follows the window's height only, never the panel's: when it
                // depended on what was left over, a short window moved the panel down each time
                // the results got shorter.
                Color.clear
                    .frame(height: Self.topInset(forAvailableHeight: availableHeight))
                    .allowsHitTesting(false)
                CommandPalettePanelView(
                    viewModel: viewModel,
                    focusedField: $focusedField,
                    accessibilityReduceMotion: accessibilityReduceMotion
                )
                .frame(maxWidth: SpotiglassDesign.Layout.paletteMaxWidth)
                .layoutPriority(1)
                Spacer(minLength: SpotiglassDesign.spacingS)
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, SpotiglassDesign.spacingXL)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { availableHeight = $0 }
        }
        // The panel stays built between openings; its field takes focus once it is usable again.
        .onChange(of: isEnabled) { _, isEnabled in
            if isEnabled { scheduleSearchFieldFocus() }
        }
        .onChange(of: viewModel.isLoading) { _, isLoading in
            if !isLoading {
                scheduleSearchFieldFocus()
            }
        }
        // The rows keep the names they were built with; build them again so an open palette
        // follows a language switch (#548).
        .onChange(of: settingsStore.settings.appearance.language) {
            viewModel.languageDidChange()
        }
    }

    /// SwiftUI on macOS often ignores immediate `@FocusState` updates in `onAppear`; deferring fixes typing-at-open.
    /// A palette closed in between (⌘K then esc at once) doesn't take focus back from the page
    /// it just handed it to (#501).
    private func scheduleSearchFieldFocus() {
        let viewModel = viewModel
        afterThisFrame {
            guard viewModel.isPresented else { return }
            focusedField = .query
            afterThisFrame {
                guard viewModel.isPresented else { return }
                focusedField = .query
            }
        }
    }
}

// MARK: - Panel

struct CommandPalettePanelView: View {
    @ObservedObject var viewModel: CommandPaletteViewModel
    var focusedField: FocusState<CommandPaletteSearchFocusField?>.Binding
    let accessibilityReduceMotion: Bool

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: SpotiglassDesign.cornerL, style: .continuous)
    }

    var body: some View {
        VStack(spacing: 0) {
            CommandPaletteSearchCardView(viewModel: viewModel, focusedField: focusedField)
            if viewModel.currentScope == .songs {
                CommandPaletteCategoryPillsRowView(viewModel: viewModel)
                    .padding(.horizontal, SpotiglassDesign.spacingM)
                    .padding(.bottom, SpotiglassDesign.spacingS)
            }
            if shouldShowResults {
                Divider()
                CommandPaletteResultsCardView(
                    viewModel: viewModel,
                    accessibilityReduceMotion: accessibilityReduceMotion
                )
            }
            Divider()
            CommandPaletteFooterView(viewModel: viewModel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: shape)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(.separator, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.28), radius: SpotiglassDesign.spacingL, x: 0, y: SpotiglassDesign.spacingS)
        .animation(accessibilityReduceMotion ? nil : .smooth(duration: 0.24), value: shouldShowResults)
    }

    /// The results area shows whenever there is something in it: results, the recent searches and
    /// quick actions before typing, a loading or error state, or a "no results" line.
    private var shouldShowResults: Bool {
        if viewModel.prefetchProgress != nil { return true }
        if !viewModel.sections.isEmpty || viewModel.isLoading || viewModel.errorText != nil { return true }
        let parsed = CommandPaletteScope.parse(viewModel.query)
        let stripped = parsed.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.isEmpty { return false }
        if parsed.scope == .songs, stripped.count < CommandPaletteViewModel.minimumPaletteSearchQueryCharacters {
            return false
        }
        return true
    }
}

/// What had focus in the window the palette opens over, handed back when it closes (#501). It is
/// read as the palette opens, before its own field takes focus.
///
/// While a text field is being edited the window's first responder is its shared field editor,
/// and the palette's own field takes that editor over, so handing the editor back focused
/// nothing: esc on the Search page left its field without focus. The field the editor was
/// serving is what comes back, with the caret or selection it had: a field that takes focus
/// selects all its text, so the next key would have replaced the query instead of going on.
struct CommandPaletteFocusReturn {
    private weak var window: NSWindow?
    private weak var responder: NSResponder?
    /// The field's text and caret or selection as the palette opened; nil for anything else.
    private let text: String?
    private let selection: NSRange?

    init?(window: NSWindow?) {
        guard let window, let current = window.firstResponder else { return nil }
        self.window = window
        if let editor = current as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSTextField {
            responder = field
            text = editor.string
            selection = editor.selectedRange()
        } else {
            responder = current
            text = nil
            selection = nil
        }
    }

    /// Gives focus back. The caret goes back only onto the same text: when the field got another
    /// query meanwhile ("Show all results" puts the palette's query there), an old caret would
    /// land mid-word, so it goes to the end instead.
    func restore() {
        guard let window, let responder, window.makeFirstResponder(responder), let selection,
              let editor = (responder as? NSTextField)?.currentEditor() else { return }
        let length = (editor.string as NSString).length
        editor.selectedRange = editor.string == text ? selection : NSRange(location: length, length: 0)
    }
}
