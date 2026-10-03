import AppKit
import SwiftUI

/// The recording sheet — `docs/LIVE_TRANSCRIPTION.md` → Interface.
///
/// With live transcription on, the committed and provisional text flow here; with it off,
/// only audio is recorded and the text is produced afterwards, in the queue.
struct RecordingView: View {
    @Environment(AppState.self) private var state
    @State private var apps: [AudioApplication] = []
    /// The app's `id`, not a pid: the processes behind it change between refreshes.
    @State private var selectedAppID: String?

    var body: some View {
        @Bindable var state = state

        return VStack(spacing: 20) {
            header
            Divider()
            sources(state: state)
            Divider()

            switch state.recording.state {
            case .failed:
                failure
            default:
                meter
                if state.preferences.liveTranscription {
                    Divider()
                    liveText
                }
            }

            Divider()
            actions
        }
        .padding(24)
        .frame(width: 460)
        .task {
            refreshApps()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            Label("Audio recording", systemImage: "mic.circle.fill")
                .font(.title3.weight(.semibold))
                .labelStyle(.titleAndIcon)
            Text("When recording stops, the file joins the queue and is transcribed as usual.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Source selection

    @ViewBuilder
    private func sources(state: AppState) -> some View {
        @Bindable var state = state

        VStack(alignment: .leading, spacing: 8) {
            // The name is given before recording: the output files derive from it too, and
            // renaming afterwards would touch three files at once.
            LabeledContent("Name") {
                TextField(
                    RecordingFile.defaultName(at: Date()),
                    text: $state.recordingName
                )
                .disabled(state.recording.isRecording)
            }

            Picker("Source", selection: $state.recordingSource) {
                ForEach(AudioSource.allCases) { source in
                    Text(source.title).tag(source)
                }
            }
            .pickerStyle(.radioGroup)
            .disabled(state.recording.isRecording)

            Toggle("Show the text live while speaking", isOn: $state.preferences.liveTranscription)
                .disabled(state.recording.isRecording)
                .help("With this off, only audio is recorded; the text is produced afterwards")

            if state.preferences.liveTranscription {
                Picker("Live model", selection: $state.preferences.liveModel) {
                    ForEach(liveModels, id: \.self) { model in
                        Text(modelLabel(model)).tag(model)
                    }
                }
                .disabled(state.recording.isRecording)
                .help("The live preview's model; the accurate pass uses the one in Settings")
            }

            if state.recordingSource.capturesSystemAudio {
                HStack(spacing: 8) {
                    Picker("App", selection: $selectedAppID) {
                        Text("All system audio").tag(String?.none)
                        if !apps.isEmpty {
                            Divider()
                            ForEach(apps) { app in
                                Text(app.name).tag(String?.some(app.id))
                            }
                        }
                    }
                    .disabled(state.recording.isRecording)

                    Button {
                        refreshApps()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh the apps playing audio")
                    .disabled(state.recording.isRecording)
                    .accessibilityLabel("Refresh the list")
                }

                if apps.isEmpty {
                    Text("No app is playing audio. Start the audio in Zoom or a browser, then refresh.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onChange(of: selectedAppID) { _, _ in applyScope() }
        .onChange(of: state.recordingSource) { _, _ in
            refreshApps()
            applyScope()
        }
    }

    private var liveModels: [String] {
        state.capabilities?.models ?? [state.preferences.liveModel]
    }

    private func modelLabel(_ model: String) -> String {
        guard let capabilities = state.capabilities else { return model }
        guard let size = capabilities.sizeLabel(for: model) else { return "\(model) ⬇︎" }
        return "\(model) · \(size)"
    }

    /// The list comes from Core Audio; the app names aren't hard-coded.
    private func refreshApps() {
        apps = AudioProcessList.playing()
        if let selectedAppID, !apps.contains(where: { $0.id == selectedAppID }) {
            self.selectedAppID = nil
        }
        applyScope()
    }

    private func applyScope() {
        guard let selectedAppID, let app = apps.first(where: { $0.id == selectedAppID }) else {
            state.recordingScope = .everything
            return
        }
        state.recordingScope = .apps([app])
    }

    // MARK: - Level and duration

    private var meter: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                Circle()
                    .fill(state.recording.state == .recording ? Color.red : Color.secondary)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                Text(TranscriptionItem.clock(state.recording.duration))
                    .font(.system(.largeTitle, design: .rounded).monospacedDigit())
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Recording duration")

            meters

            VStack(spacing: 2) {
                Text(folderLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Button("Change Folder…") { chooseFolder() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(state.recording.isRecording)
            }
        }
    }

    /// One meter per source when both are captured, and one when there is only one.
    ///
    /// The split exists because a single meter fed by the sum cannot answer the question that
    /// actually goes wrong: a live microphone and a stone-dead tap make a meter that dances
    /// convincingly, and the user only finds out when they read the transcript and half the
    /// conversation is missing (ADR-026).
    @ViewBuilder
    private var meters: some View {
        let levels = state.recording.levels
        if let microphone = levels.microphone, let system = levels.system {
            VStack(spacing: 8) {
                labelledMeter("Microphone", level: microphone, symbol: "mic.fill")
                labelledMeter("System audio", level: system, symbol: "speaker.wave.2.fill")
            }
        } else {
            levelBar(state.recording.level)
                .accessibilityLabel("Audio level")
                .accessibilityValue("\(Int(state.recording.level * 100)) percent")
        }

        if state.recording.receivedNoAudio {
            warning(
                "No audio is arriving at all.",
                detail:
                    "Nothing is being recorded. Stop, pick a different app or source, and start again."
            )
        } else if state.recording.systemAudioSilent {
            warning(
                "No system audio is arriving.",
                detail:
                    "The microphone is still being recorded. Check that the audio is playing, and that the app above is the one playing it."
            )
        }
    }

    private func labelledMeter(
        _ title: LocalizedStringKey, level: Float, symbol: String
    )
        -> some View
    {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .accessibilityHidden(true)
            levelBar(level, segments: 20)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue("\(Int(level * 100)) percent")
    }

    /// Says what is happening and what to do about it.
    ///
    /// Worded so it never claims more than it knows: when only system audio is missing, the
    /// microphone side really is being written, and saying "recording failed" would send the
    /// user to stop a recording that is half good.
    private func warning(_ title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.medium))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
    }

    /// Discrete bars: more readable than one continuous bar, and they hide the slow refresh
    /// rate (15 a second).
    private func levelBar(_ level: Float, segments: Int = 24) -> some View {
        let active = Int((level * Float(segments)).rounded())
        return HStack(spacing: 3) {
            ForEach(0..<segments, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(index < active ? Color.accentColor : Color.secondary.opacity(0.18))
                    .frame(width: 8, height: index < active ? 20 : 10)
            }
        }
        .frame(height: 22)
        .animation(.linear(duration: 0.08), value: active)
    }

    private var folderLabel: String {
        state.recording.fileURL?.deletingLastPathComponent().path
            ?? state.recordingDirectory.path
    }

    // MARK: - Live text

    /// Committed text in the primary colour, provisional text faded.
    ///
    /// The two are shown as a single stream: while waiting for the rest of a sentence, the
    /// user shouldn't see a gap in the middle of the text.
    private var liveText: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if state.recording.transcript.isEmpty && state.recording.partialText.isEmpty {
                            Text(placeholder)
                                .foregroundStyle(.tertiary)
                        } else {
                            (Text(state.recording.transcript.joined)
                                .foregroundStyle(.primary)
                                + Text(state.recording.partialText.isEmpty ? "" : " ")
                                + Text(state.recording.partialText)
                                .foregroundStyle(.secondary))
                        }
                    }
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .id("live-end")
                }
                .frame(height: 120)
                .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 6))
                .onChange(of: state.recording.partialText) {
                    withAnimation { proxy.scrollTo("live-end", anchor: .bottom) }
                }
            }

            if let liveFailure = state.recording.liveFailure {
                Label(liveFailure, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text("The live text is a preview; the accurate transcript is produced afterwards.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var placeholder: String {
        state.recording.isRecording
            ? String(localized: "The text will appear here as you speak…")
            : String(localized: "Start the recording.")
    }

    // MARK: - Error

    @ViewBuilder
    private var failure: some View {
        if let failure = state.recording.failure {
            VStack(spacing: 10) {
                Image(systemName: "mic.slash")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.secondary)
                Text(failure.message)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let suggestion = failure.suggestion {
                    Text(suggestion)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Open Privacy Settings") { openPrivacySettings() }
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 12) {
            Button("Cancel", role: .cancel) { state.cancelRecording() }

            Spacer()

            if !state.recording.isRecording {
                Button("Start Recording") {
                    Task { await state.startRecording() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }

            if state.recording.state == .paused {
                Button("Resume") { state.recording.resume() }
            } else {
                Button("Pause") { state.recording.pause() }
                    .disabled(state.recording.state != .recording)
            }

            Button("Finish") { Task { await state.finishRecording() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!state.recording.isRecording)
        }
    }

    // MARK: - Helpers

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        panel.directoryURL = state.recordingDirectory
        if panel.runModal() == .OK, let url = panel.url {
            state.preferences.recordingDirectory = url
        }
    }

    private func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}
