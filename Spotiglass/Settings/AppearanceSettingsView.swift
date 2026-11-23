import SwiftUI

/// Settings → Appearance: window and overlay visuals (command palette, future options).
struct AppearanceSettingsView: View {
    @ObservedObject var settingsStore: SpotiglassSettingsStore

    var body: some View {
        // Grouped Form matches System Settings. Each option gets its own group so
        // its hint can sit in the section footer instead of running as loose body
        // text between controls.
        //
        // No pane subtitle. The shell header already names the pane, and a footer
        // restating that sat between the first two groups, where it read as a
        // footnote to Language rather than a description of the pane.
        Form {
            Section {
                languageSection
            }

            Section {
                colorSchemeSection
            }

            Section {
                lyricsTextSizeSection
            } footer: {
                // The timing slider is gone (#640): each song's timing is fixed on its lyrics.
                Text(SpotiglassL10n.string("settings.appearance.lyricsTiming.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                commandPaletteSection
            }
        }
        .formStyle(.grouped)
    }

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXS) {
            Text(SpotiglassL10n.string("settings.appearance.language"))
                .font(.headline)
            Picker(SpotiglassL10n.string("settings.appearance.language"), selection: languageBinding) {
                ForEach(AppLanguage.allCases, id: \.self) { language in
                    Text(language.nativeDisplayName).tag(language)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(SpotiglassL10n.string("settings.appearance.language.hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { settingsStore.settings.appearance.language },
            set: { newValue in
                settingsStore.update { $0.appearance.language = newValue }
            }
        )
    }

    private var colorSchemeSection: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXS) {
            Text(SpotiglassL10n.string("settings.appearance.colorScheme"))
                .font(.headline)
            Picker(SpotiglassL10n.string("settings.appearance.colorScheme"), selection: colorSchemeBinding) {
                ForEach(AppearanceColorScheme.allCases, id: \.self) { scheme in
                    Text(scheme.displayName).tag(scheme)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .rebuildsOnLanguageChange(settingsStore.settings.appearance.language)
            Text(SpotiglassL10n.string("settings.appearance.colorScheme.hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
    }

    private var commandPaletteSection: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXS) {
            Text(SpotiglassL10n.string("settings.appearance.commandPalette"))
                .font(.headline)
            Toggle(SpotiglassL10n.string("settings.appearance.backdropBlur"), isOn: backdropBlurBinding)
                .toggleStyle(.switch)
                .accessibilityHint(SpotiglassL10n.string("settings.appearance.backdropBlur.hint"))
            Text(SpotiglassL10n.string("settings.appearance.backdropBlur.hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var colorSchemeBinding: Binding<AppearanceColorScheme> {
        Binding(
            get: { settingsStore.settings.appearance.colorScheme },
            set: { newValue in
                settingsStore.update { $0.appearance.colorScheme = newValue }
            }
        )
    }

    private var backdropBlurBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.settings.commandPalette.backdropBlur },
            set: { newValue in
                settingsStore.update { $0.commandPalette.backdropBlur = newValue }
            }
        )
    }

    // MARK: - Lyrics text size

    private var lyricsTextSizeSection: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
            Text(SpotiglassL10n.string("settings.appearance.lyricsTextSize"))
                .font(.headline)
            Picker(SpotiglassL10n.string("settings.appearance.lyricsTextSize"), selection: lyricsTextSizeBinding) {
                ForEach(LyricsTextSize.allCases, id: \.self) { size in
                    Text(size.displayName).tag(size)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .rebuildsOnLanguageChange(settingsStore.settings.appearance.language)

            lyricsTextScaleSlider

            LyricsTextSizePreview(metrics: settingsStore.settings.appearance.lyricsTextMetrics)

            Text(SpotiglassL10n.string("settings.appearance.lyricsTextSize.hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The picker reports the size actually in use, not the preset that was last
    /// tapped, and picking a preset means exactly that preset. Otherwise the two
    /// controls under this one heading can disagree, which is how the segmented
    /// control came to read Small beside a slider reading 300% (#165).
    private var lyricsTextSizeBinding: Binding<LyricsTextSize> {
        Binding(
            get: {
                LyricsTextSize.nearest(
                    activeFontSize: settingsStore.settings.appearance.lyricsTextMetrics.activeFontSize
                )
            },
            set: { newValue in
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    settingsStore.update {
                        $0.appearance.lyricsTextSize = newValue
                        $0.appearance.lyricsTextScale = 1.0
                    }
                }
            }
        )
    }

    /// Continuous size slider layered on top of the preset buttons. The "A" end
    /// caps mirror macOS text-size controls; the readout shows the multiplier.
    private var lyricsTextScaleSlider: some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            Text(verbatim: "A")
                .font(SpotiglassDesign.Typography.appearanceSliderSmall)
                .foregroundStyle(.secondary)
            Slider(
                value: lyricsTextScaleBinding,
                in: AppearanceSettings.lyricsTextScaleRange
            ) { editing in
                // Drag ticks only stage in memory (keeps the preview and the live
                // lyrics view updating); one atomic file write on knob release.
                if !editing {
                    // A failed save is logged and shown above the pane by the store.
                    try? settingsStore.persistStagedSettings()
                }
            }
            .accessibilityLabel(SpotiglassL10n.string("settings.appearance.lyricsTextScale"))
            Text(verbatim: "A")
                .font(SpotiglassDesign.Typography.appearanceSliderLarge)
                .foregroundStyle(.secondary)
            Text(
                verbatim: settingsStore.settings.appearance.lyricsTextScale
                    .formatted(
                        .percent
                            .precision(.fractionLength(0))
                            .locale(settingsStore.appLocale)
                    )
            )
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: SpotiglassDesign.Layout.valueLabelMinWidth, alignment: .trailing)
        }
    }

    private var lyricsTextScaleBinding: Binding<Double> {
        Binding(
            get: { settingsStore.settings.appearance.lyricsTextScale },
            set: { newValue in
                settingsStore.stage {
                    $0.appearance.lyricsTextScale = AppearanceSettings.clampedLyricsTextScale(newValue)
                }
            }
        )
    }
}

/// Live preview tile that mirrors the immersive lyrics styling for the picked
/// size preset combined with the scale slider.
private struct LyricsTextSizePreview: View {
    let metrics: LyricsTextMetrics

    /// The glow behind the active line is drawn by hand, and `shadow(color:)` wants a
    /// concrete color, so this is one of the few places that has to ask directly.
    @Environment(\.appearsActive) private var appearsActive

    private let lines: [(text: String, distance: Int)] = [
        (SpotiglassL10n.string("settings.appearance.lyricsPreview.line1"),   -1),
        (SpotiglassL10n.string("settings.appearance.lyricsPreview.line2"),   0),
        (SpotiglassL10n.string("settings.appearance.lyricsPreview.line3"),       1)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: max(SpotiglassDesign.spacingXS, metrics.timedLineSpacing * 0.55)) {
            ForEach(lines, id: \.distance) { line in
                Text(line.text)
                    .font(.system(
                        size: line.distance == 0 ? metrics.activeFontSize : metrics.inactiveFontSize,
                        weight: line.distance == 0 ? .semibold : .regular
                    ))
                    .foregroundStyle(.primary.opacity(line.distance == 0 ? 1.0 : 0.45))
                    .blur(radius: line.distance == 0 ? 0 : 0.4)
                    .shadow(
                        color: line.distance == 0
                            ? SpotiglassDesign.accent(appearsActive: appearsActive).opacity(0.22)
                            : .clear,
                        radius: line.distance == 0 ? metrics.activeGlowRadius * 0.6 : 0
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, SpotiglassDesign.spacingM)
        .padding(.vertical, SpotiglassDesign.spacingM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .spotiglassSurface(corner: .m)
        .animation(SpotiglassMotion.surfaceSpring, value: metrics)
        .accessibilityLabel(SpotiglassL10n.string("settings.appearance.lyricsPreview.label.generic"))
    }
}
