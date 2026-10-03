import AppKit
import SwiftUI

/// The recording sheet — `docs/LIVE_TRANSCRIPTION.md` → Interface.
///
/// With live transcription on, the committed and provisional text flow here; with it off,
/// only audio is recorded and the text is produced afterwards, in the queue.
struct RecordingView: View {
    @Environment(AppState.self) private var state
    @State private var processes: [AudioProcess] = []
    @State private var selectedPID: pid_t?

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
            refreshProcesses()
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
                    Picker("App", selection: $selectedPID) {
                        Text("All system audio").tag(pid_t?.none)
                        if !processes.isEmpty {
                            Divider()
                            ForEach(processes) { process in
                                Text(process.name).tag(pid_t?.some(process.pid))
                            }
                        }
                    }
                    .disabled(state.recording.isRecording)

                    Button {
                        refreshProcesses()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh the apps playing audio")
                    .disabled(state.recording.isRecording)
                    .accessibilityLabel("Refresh the list")
                }

                if processes.isEmpty {
                    Text("No app is playing audio. Start the audio in Zoom or a browser, then refresh.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onChange(of: selectedPID) { _, _ in applyScope() }
        .onChange(of: state.recordingSource) { _, _ in
            refreshProcesses()
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
    private func refreshProcesses() {
        processes = AudioProcessList.playing()
        if let selectedPID, !processes.contains(where: { $0.pid == selectedPID }) {
            self.selectedPID = nil
        }
        applyScope()
    }

    private func applyScope() {
        guard let selectedPID, let process = processes.first(where: { $0.pid == selectedPID }) else {
            state.recordingScope = .everything
            return
        }
        state.recordingScope = .processes([process])
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

            levelBar
                .accessibilityLabel("Audio level")
                .accessibilityValue("\(Int(state.recording.level * 100)) percent")

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

    /// Discrete bars: more readable than one continuous bar, and they hide the slow refresh
    /// rate (15 a second).
    private var levelBar: some View {
        let segments = 24
        let active = Int((state.recording.level * Float(segments)).rounded())
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
