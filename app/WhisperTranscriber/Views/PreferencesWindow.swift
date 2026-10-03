import AppKit
import SwiftUI

/// The Settings window, opened with ⌘, — four tabs.
///
/// `SettingsPane` in the main window holds a **job's** settings (model, language, format);
/// this is where the app's behaviour, the model cache and the runtime are managed.
struct PreferencesWindow: View {
    @Environment(AppState.self) private var state

    var body: some View {
        TabView {
            GeneralPreferences()
                .tabItem { Label("General", systemImage: "gearshape") }
            ModelPreferences()
                .tabItem { Label("Models", systemImage: "cube.box") }
            RuntimePreferences()
                .tabItem { Label("Runtime", systemImage: "shippingbox") }
            AboutPreferences()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

// MARK: - General

private struct GeneralPreferences: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        Form {
            Section("Queue") {
                Toggle("Start transcribing when a file is added", isOn: $state.preferences.autoStartOnAdd)
                Toggle("Keep the Mac awake while transcribing", isOn: $state.preferences.keepSystemAwake)
                Toggle("Confirm on quit while transcribing", isOn: $state.preferences.confirmOnQuit)
            }

            Section("When finished") {
                Toggle("Send a notification", isOn: $state.preferences.notifyOnFinish)
                Text("The notification is only shown while the app is in the background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Reveal the produced files in Finder", isOn: $state.preferences.revealOnFinish)
            }

            Section("Live transcription") {
                Toggle("Show the text live while recording", isOn: $state.preferences.liveTranscription)
                Toggle("Produce the accurate transcript afterwards", isOn: $state.preferences.runSecondPass)
                    // With both off, no text would come out of a recording at all.
                    .disabled(!state.preferences.liveTranscription)
                Text(
                    """
                    The live text is decoded greedily and is a preview. The accurate pass \
                    runs in the queue and writes its own files, so the live text is kept. \
                    An hour-long recording takes about 18 minutes with `small`; with the \
                    accurate pass off, the live text is the final output.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Recording") {
                LabeledContent("Recording folder") {
                    HStack {
                        Text(state.recordingDirectory.path)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(.secondary)
                        Button("Choose…") {
                            if let url = PreferencesWindow.pickDirectory() {
                                state.preferences.recordingDirectory = url
                            }
                        }
                        if state.preferences.recordingDirectory != nil {
                            Button("Default") { state.preferences.recordingDirectory = nil }
                        }
                    }
                }
                Text("Audio recordings are written here; an existing file is never overwritten.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("My presets") {
                if state.customPresets.isEmpty {
                    Text("No presets saved yet. You can save one from the list in the toolbar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(state.customPresets) { preset in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(preset.name)
                                Text(preset.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Delete", role: .destructive) { state.deletePreset(preset) }
                                .controlSize(.small)
                        }
                    }
                }
            }

            Section("Output") {
                Picker("Output location", selection: $state.settings.outputLocation) {
                    ForEach(WhisperSettings.OutputLocation.allCases) { location in
                        Text(location.title).tag(location)
                    }
                }
                if state.settings.outputLocation == .customFolder {
                    LabeledContent("Folder") {
                        HStack {
                            Text(state.settings.customOutputDirectory?.path ?? "Not chosen")
                                .lineLimit(1)
                                .truncationMode(.head)
                                .foregroundStyle(.secondary)
                            Button("Choose…") { chooseFolder(state: state) }
                        }
                    }
                }
                Toggle("Overwrite an existing file", isOn: $state.settings.overwrite)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder(state: AppState) {
        guard let url = PreferencesWindow.pickDirectory() else { return }
        state.settings.customOutputDirectory = url
    }
}

// MARK: - Models

private struct ModelPreferences: View {
    @Environment(AppState.self) private var state
    /// The model the confirmation dialog is asking about; `nil` while it is closed.
    @State private var modelToDelete: String?

    var body: some View {
        @Bindable var state = state

        Form {
            Section("Model folder") {
                LabeledContent("Location") {
                    Text(modelDirectory.path)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([modelDirectory])
                    }
                    Button("Change…") {
                        if let url = PreferencesWindow.pickDirectory() {
                            state.settings.modelDirectory = url
                        }
                    }
                    if state.settings.modelDirectory != nil {
                        Button("Reset to Default") { state.settings.modelDirectory = nil }
                    }
                }
                Text(
                    """
                    Models live in this folder. You can fetch one here instead of waiting for \
                    a transcription to do it, and delete one you no longer want. Only the \
                    models you act on are touched; the folder itself is left alone.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Models") {
                if let capabilities = state.capabilities {
                    ForEach(capabilities.models, id: \.self) { model in
                        row(model, capabilities: capabilities)
                    }
                } else {
                    Text("The model list is read once the runtime is ready.")
                        .foregroundStyle(.secondary)
                }
            }

            if let capabilities = state.capabilities, capabilities.cachedBytes > 0 {
                Section {
                    LabeledContent("Downloaded models") {
                        Text(
                            ByteCountFormatter.string(
                                fromByteCount: Int64(capabilities.cachedBytes), countStyle: .file)
                        )
                        .monospacedDigit()
                    }
                }
            }

            if let message = state.modelDeleteError ?? state.modelDownloadError {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        // A deleted model costs a download to get back, so the name and the size it frees
        // are both in the question.
        .confirmationDialog(
            deletePrompt,
            isPresented: .init(get: { modelToDelete != nil }, set: { if !$0 { modelToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Model", role: .destructive) {
                guard let model = modelToDelete else { return }
                modelToDelete = nil
                Task { await state.deleteModel(model) }
            }
            Button("Cancel", role: .cancel) { modelToDelete = nil }
        } message: {
            Text("You can download it again later. Nothing else in the folder is touched.")
        }
    }

    private var deletePrompt: String {
        guard let model = modelToDelete else { return String(localized: "Delete the model?") }
        guard let size = state.capabilities?.sizeLabel(for: model) else {
            return String(localized: "Delete \(model)?")
        }
        return String(localized: "Delete \(model) and free \(size)?")
    }

    private var modelDirectory: URL {
        state.settings.modelDirectory ?? WhisperSettings.defaultModelDirectory
    }

    private func row(_ model: String, capabilities: EngineCapabilities) -> some View {
        HStack {
            Image(systemName: capabilities.isCached(model) ? "checkmark.circle.fill" : "arrow.down.circle")
                .foregroundStyle(capabilities.isCached(model) ? .green : .secondary)
                .accessibilityLabel(capabilities.isCached(model) ? "downloaded" : "not downloaded")
            Text(model)
            if model == state.settings.model {
                Text("selected")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.tint.opacity(0.15), in: .capsule)
            }
            Spacer()
            // The size is only known for models that have been downloaded (docs/PROTOCOL.md).
            Text(capabilities.sizeLabel(for: model) ?? "—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            // Each row offers the one action that applies to it: delete what is here,
            // fetch what isn't. A row being downloaded shows the bar instead (ADR-019).
            if state.downloadingModel == model {
                if let fraction = state.downloadFraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 70)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            } else if capabilities.isCached(model) {
                Button {
                    modelToDelete = model
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete this model from the folder")
                .accessibilityLabel("Delete \(model)")
            } else {
                Button {
                    Task { await state.downloadModel(model) }
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
                // One at a time: a second download would only halve the first's bandwidth.
                .disabled(state.downloadingModel != nil)
                .help("Download this model now")
                .accessibilityLabel("Download \(model)")
            }
        }
    }
}

// MARK: - Runtime environment

private struct RuntimePreferences: View {
    @Environment(AppState.self) private var state
    @State private var confirmReinstall = false
    @State private var confirmRemove = false
    @State private var installedBytes: Int64?

    /// Whichever devices the worker reported; the list isn't hard-coded.
    private var devices: [Device] {
        guard let capabilities = state.capabilities else { return [.cpu] }
        return Device.allCases.filter { capabilities.devices.contains($0.rawValue) }
    }

    var body: some View {
        @Bindable var state = state

        return Form {
            Section("Status") {
                if case .ready(let info) = state.runtime {
                    LabeledContent("Status") { Label("Ready", systemImage: "checkmark.seal") }
                    LabeledContent("Python") { Text(info.python).monospacedDigit() }
                    LabeledContent("whisper") { Text(info.whisper).monospacedDigit() }
                    LabeledContent("torch") { Text(info.torch).monospacedDigit() }
                    LabeledContent("imageio-ffmpeg") { Text(info.imageioFfmpeg).monospacedDigit() }
                    LabeledContent("Installed") { Text(Self.installedLabel(info.installedAt)) }
                    LabeledContent("On disk") {
                        if let installedBytes {
                            Text(ByteCountFormatter.string(fromByteCount: installedBytes, countStyle: .file))
                                .monospacedDigit()
                        } else {
                            Text("calculating…").foregroundStyle(.secondary)
                        }
                    }
                } else {
                    LabeledContent("Status") { Text(statusText).foregroundStyle(.secondary) }
                }
            }

            Section("Location") {
                LabeledContent("Environment") {
                    Text(state.layout.runtime.path)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([state.layout.runtime])
                    }
                    Button("Open Logs") {
                        NSWorkspace.shared.open(state.layout.logs)
                    }
                }
            }

            Section("Device") {
                Picker("Compute", selection: $state.settings.device) {
                    ForEach(devices) { device in
                        Text(device.title).tag(device)
                    }
                }
                Text(
                    """
                    MPS is experimental: whisper doesn't run reliably on it for every model. \
                    If a job fails with MPS, it is retried automatically on the CPU.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("While transcribing") {
                Picker("CPU use", selection: $state.settings.cpuBudget) {
                    ForEach(CPUBudget.allCases) { budget in
                        Text(budget.title).tag(budget)
                    }
                }
                Text(state.settings.cpuBudget.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(
                    """
                    This changes how long a transcription takes, never what it produces. \
                    A running job keeps the setting it started with.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Maintenance") {
                HStack {
                    Button("Health Check") {
                        Task { await state.retryHealthCheck() }
                    }
                    Button("Reinstall…") { confirmReinstall = true }
                    Button("Delete Environment…", role: .destructive) { confirmRemove = true }
                }
                Text(
                    """
                    Reinstalling deletes the runtime and downloads ~850 MB again. \
                    The whisper models you downloaded are left alone.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Computing the size walks the directory tree; done once, when the tab opens.
        .task(id: state.runtime) {
            guard state.runtime.isReady else {
                installedBytes = nil
                return
            }
            installedBytes = await state.runtimeSize()
        }
        .alert("Reinstall the runtime?", isPresented: $confirmReinstall) {
            Button("Reinstall", role: .destructive) {
                Task { await state.reinstallRuntime() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current environment is deleted and downloaded again. Your models are kept.")
        }
        .alert("Delete the runtime?", isPresented: $confirmRemove) {
            Button("Delete", role: .destructive) {
                Task { await state.removeRuntime() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                """
                The environment is deleted and the app returns to the setup screen. \
                The whisper models you downloaded are not deleted.
                """
            )
        }
    }

    /// Turns the ISO-8601 stamp in `runtime.json` into a readable date.
    static func installedLabel(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var statusText: String {
        switch state.runtime {
        case .unknown, .checking: String(localized: "Checking…")
        case .notInstalled: String(localized: "Not installed")
        case .installing: String(localized: "Installing…")
        case .broken(let reason): reason
        case .ready: String(localized: "Ready")
        }
    }
}

// MARK: - About

private struct AboutPreferences: View {
    @Environment(AppState.self) private var state
    @Environment(UpdateController.self) private var updates

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text("Whisper Transcriber")
                .font(.title2.weight(.semibold))

            Text("Version \(Self.version) (\(Self.build))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Text(
                """
                Transcribes audio files to text with OpenAI Whisper. Everything happens \
                on this Mac; the audio is never sent to any server.
                """
            )
            .multilineTextAlignment(.center)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 24)

            if case .ready(let info) = state.runtime {
                Text("whisper \(info.whisper) · torch \(info.torch) · Python \(info.python)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            // Absent in a Debug build, which carries no feed URL (ADR-020).
            if updates.isConfigured {
                VStack(spacing: 6) {
                    Button("Check for Updates…") { updates.checkForUpdates() }
                        .disabled(!updates.canCheckForUpdates)

                    Toggle("Check automatically", isOn: automaticBinding)
                        .toggleStyle(.checkbox)
                        .font(.callout)

                    if let date = updates.lastCheckDate {
                        Text("Last checked \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.top, 4)
            }

            // The repository address comes from Info.plist; with none defined yet, no link
            // is shown — we don't want to link to an address that doesn't exist.
            if let repository = Self.repository {
                Link("Source code and release notes", destination: repository)
                    .font(.callout)
            }

            Text("MIT License · © 2026 Talha Turhan")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    /// Sparkle owns the stored preference, so the toggle reads and writes through it rather
    /// than keeping a copy that could disagree.
    private var automaticBinding: Binding<Bool> {
        Binding(
            get: { updates.automaticallyChecks },
            set: { updates.automaticallyChecks = $0 }
        )
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    /// `WTRepositoryURL` — defined in `app/project.yml`.
    static var repository: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "WTRepositoryURL") as? String,
            !value.isEmpty
        else {
            return nil
        }
        return URL(string: value)
    }
}

// MARK: - Shared

extension PreferencesWindow {

    /// Lets the user pick a folder. There is no sandbox, so we need no extra entitlement for
    /// the access (ADR-007).
    static func pickDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

#Preview {
    PreferencesWindow().environment(AppState())
}
