import SwiftUI
import UniformTypeIdentifiers

/// The main window: three panes plus the toolbar — `docs/UI_SPEC.md`.
struct MainView: View {
    @Environment(AppState.self) private var state
    @State private var isDropTargeted = false
    @State private var isNamingPreset = false
    @State private var presetName = ""

    var body: some View {
        @Bindable var state = state
        // Because queue is a `let` it can't be bound through state; we bind directly to its
        // own @Observable object.
        @Bindable var queue = state.queue

        HSplitView {
            QueuePane()
                .frame(minWidth: 260, idealWidth: 320)

            VSplitView {
                SettingsPane()
                    .frame(minHeight: 220)
                OutputPane()
                    .frame(minHeight: 180)
            }
            .frame(minWidth: 340)
        }
        .frame(minWidth: 900, minHeight: 600)
        .toolbar { toolbar }
        // The whole window is a drop target.
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
            return true
        }
        .overlay {
            if isDropTargeted { dropOverlay }
        }
        .alert(item: $queue.lastRejection) { rejection in
            Alert(
                title: Text(rejectionTitle(rejection)),
                message: Text("Only audio and video files can be added."),
                dismissButton: .default(Text("OK"))
            )
        }
        .sheet(isPresented: $state.isRecordingSheetPresented) {
            RecordingView().environment(state)
        }
        .alert("Save as a preset", isPresented: $isNamingPreset) {
            TextField("Name", text: $presetName)
            Button("Save") { state.saveCurrentAsPreset(named: presetName) }
                .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The model, language and formats are saved; the output folder is not.")
        }
        .alert(item: $state.overwritePrompt) { prompt in
            Alert(
                title: Text("Overwrite the existing files?"),
                message: Text(overwriteMessage(prompt)),
                primaryButton: .destructive(Text("Overwrite")) {
                    state.confirmOverwriteAndStart()
                },
                secondaryButton: .cancel(Text("Cancel"))
            )
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                state.openFilePanel()
            } label: {
                Label("Add Files", systemImage: "plus")
            }
            .help("Choose the files to transcribe")
        }

        ToolbarItem(placement: .navigation) {
            Button {
                state.presentRecording()
            } label: {
                Label("Record", systemImage: "mic.fill")
            }
            .help("Record audio from the microphone")
            .disabled(state.recording.isRecording)
        }

        ToolbarItem(placement: .primaryAction) {
            if state.queue.isRunning {
                Button {
                    state.stopQueue()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .help("Cancel the running job")
            } else {
                Button {
                    state.startQueue()
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .disabled(!state.queue.hasPending || !state.settings.isRunnable)
                .help("Start working the queue")
            }
        }

        ToolbarItem(placement: .automatic) {
            Menu {
                ForEach(WhisperSettings.builtInPresets) { preset in
                    Button {
                        state.applyPreset(preset)
                    } label: {
                        Text(verbatim: "\(preset.name) — \(preset.detail)")
                    }
                }

                if !state.customPresets.isEmpty {
                    Divider()
                    ForEach(state.customPresets) { preset in
                        Button {
                            state.applyCustomPreset(preset)
                        } label: {
                            Text(verbatim: "\(preset.name) — \(preset.detail)")
                        }
                    }
                }

                Divider()
                Button("Save Current Settings…") {
                    presetName = ""
                    isNamingPreset = true
                }
            } label: {
                Label("Presets", systemImage: "slider.horizontal.3")
            }
            .help("Preset setting bundles")
        }

        ToolbarItem(placement: .automatic) {
            // SettingsLink opens the Settings scene itself; driving it by hand through
            // `showSettingsWindow:` breaks when the window is already open.
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Models, output and the runtime environment (⌘,)")
        }

        ToolbarItem(placement: .status) {
            statusIndicator
        }
    }

    private var statusIndicator: some View {
        HStack(spacing: 6) {
            // Colour alone carries no information; the text beside it says the same thing.
            Circle()
                .fill(state.queue.isRunning ? Color.accentColor : .green)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(state.queue.isRunning ? "Running" : "Ready")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Queue status")
    }

    // MARK: - Drag and drop

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
            .foregroundStyle(.tint)
            .background(.tint.opacity(0.06), in: .rect(cornerRadius: 10))
            .overlay {
                Label("Drop audio files", systemImage: "arrow.down.circle")
                    .font(.title3)
                    .foregroundStyle(.tint)
            }
            .padding(8)
            .allowsHitTesting(false)
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier)
                    as? Data,
                    let decoded = URL(dataRepresentation: url, relativeTo: nil)
                {
                    urls.append(decoded)
                }
            }
            guard !urls.isEmpty else { return }
            state.addFiles(urls)
        }
    }

    private func rejectionTitle(_ rejection: JobQueue.Rejection) -> String {
        rejection.count == 1
            ? String(localized: "\(rejection.firstName) is not supported")
            : String(localized: "\(rejection.count) files are not supported")
    }

    private func overwriteMessage(_ prompt: AppState.OverwritePrompt) -> String {
        let names = prompt.files.prefix(3).map(\.lastPathComponent).joined(separator: "\n")
        let more =
            prompt.files.count > 3
            ? "\n" + String(localized: "and \(prompt.files.count - 3) more files") : ""
        return String(localized: "These files already exist:") + "\n\(names)\(more)"
    }
}
