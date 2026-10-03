import AppKit
import SwiftUI

/// The top-right pane: the transcription settings — `docs/WHISPER_OPTIONS.md`.
///
/// Only the things that genuinely change from job to job are here. The decoding parameters
/// (beam_size, temperature, the thresholds) aren't in the interface; the worker applies the
/// whisper command line's defaults (ADR-015). Device selection is in the Settings window.
struct SettingsPane: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                presets(state: state)
                basics(state: state)
                warnings
                footnote
            }
            .padding(16)
        }
        .frame(minWidth: 320)
    }

    // MARK: - Presets

    /// The visible counterpart of the toolbar menu — discovering the presets shouldn't depend
    /// on them staying buried in a menu.
    private func presets(state: AppState) -> some View {
        ViewThatFits(in: .horizontal) {
            presetRow(state: state)
            ScrollView(.horizontal, showsIndicators: false) { presetRow(state: state) }
        }
        .accessibilityLabel("Presets")
    }

    private func presetRow(state: AppState) -> some View {
        HStack(spacing: 6) {
            ForEach(WhisperSettings.builtInPresets) { preset in
                Button(preset.name) { state.applyPreset(preset) }
                    .controlSize(.small)
                    .help(preset.detail)
            }
        }
    }

    // MARK: - Core

    @ViewBuilder
    private func basics(state: AppState) -> some View {
        @Bindable var state = state

        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                Text("Model")
                Picker("Model", selection: $state.settings.model) {
                    ForEach(models, id: \.self) { model in
                        Text(modelLabel(model)).tag(model)
                    }
                }
                .labelsHidden()
            }

            GridRow {
                Text("Language")
                Picker("Language", selection: $state.settings.language) {
                    Text("Detect automatically").tag(String?.none)
                    Divider()
                    ForEach(languages) { language in
                        Text(LanguageNames.display(for: language)).tag(String?.some(language.code))
                    }
                }
                .labelsHidden()
            }

            GridRow {
                Text("Task")
                Picker("Task", selection: $state.settings.task) {
                    ForEach(TranscriptionTask.allCases) { task in
                        Text(task.title).tag(task)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            GridRow {
                Text("Format").gridColumnAlignment(.leading)
                formatToggles(state: state)
            }

            GridRow {
                Text("Output")
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Output location", selection: $state.settings.outputLocation) {
                        ForEach(WhisperSettings.OutputLocation.allCases) { location in
                            Text(location.title).tag(location)
                        }
                    }
                    .labelsHidden()

                    if state.settings.outputLocation == .customFolder {
                        HStack(spacing: 6) {
                            Text(
                                state.settings.customOutputDirectory?.lastPathComponent ?? "No folder chosen"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            Button("Choose…") { chooseOutputFolder(state: state) }
                                .controlSize(.small)
                        }
                    }

                    Toggle("Overwrite an existing file", isOn: $state.settings.overwrite)
                        .font(.callout)
                }
            }
        }
    }

    /// Six formats don't fit on one line; two rows of three neither overflow in a narrow
    /// window nor break the reading order.
    private func formatToggles(state: AppState) -> some View {
        @Bindable var state = state
        let columns = 3
        let formats = OutputFormat.allCases
        let rows = stride(from: 0, to: formats.count, by: columns).map { start in
            Array(formats[start..<min(start + columns, formats.count)])
        }

        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 10) {
                    ForEach(row) { format in
                        Toggle(
                            format.label,
                            isOn: Binding(
                                get: { state.settings.outputFormats.contains(format) },
                                set: { isOn in
                                    if isOn {
                                        state.settings.outputFormats.insert(format)
                                    } else {
                                        state.settings.outputFormats.remove(format)
                                    }
                                }
                            )
                        )
                        .toggleStyle(.checkbox)
                        .help(Text(format.title))
                        .frame(width: 72, alignment: .leading)
                    }
                }
            }
        }
        .accessibilityLabel("Output formats")
    }

    // MARK: - Warnings

    @ViewBuilder
    private var warnings: some View {
        let warnings = state.settings.warnings(capabilities: state.capabilities)
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(warnings) { warning in
                    Label(warning.text, systemImage: warning.symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))
        }
    }

    private var footnote: some View {
        Text("Changing a setting doesn't affect the running job; it applies from the next one on.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Data

    private var models: [String] {
        state.capabilities?.models ?? [state.settings.model]
    }

    private var languages: [EngineCapabilities.Language] {
        state.capabilities?.sortedLanguages ?? []
    }

    /// `small · 462 MB`, or `medium ⬇︎` if it hasn't been downloaded.
    private func modelLabel(_ model: String) -> String {
        guard let capabilities = state.capabilities else { return model }
        guard let size = capabilities.sizeLabel(for: model) else { return "\(model) ⬇︎" }
        return "\(model) · \(size)"
    }

    private func chooseOutputFolder(state: AppState) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK {
            state.settings.customOutputDirectory = panel.url
        }
    }
}
