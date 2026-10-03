import AppKit
import Foundation
import Observation
import UserNotifications

/// The single source of data for the interface.
///
/// Views read only from here; the heavy work happens in the `PythonWhisperEngine` actor
/// and in a separate Python process.
@MainActor
@Observable
final class AppState {

    // MARK: - Runtime environment

    private(set) var runtime: RuntimeState = .unknown
    private(set) var setupLog: [String] = []
    private(set) var setupError: SetupError?

    // MARK: - Engine and queue

    private(set) var capabilities: EngineCapabilities?
    private(set) var capabilitiesError: String?
    let queue: JobQueue

    // MARK: - Recording

    let recording: RecordingController
    /// Is the recording sheet open?
    var isRecordingSheetPresented = false
    /// The source selection on the recording screen; stored in the preferences.
    var recordingSource: AudioSource {
        get { preferences.recordingSource }
        set { preferences.recordingSource = newValue }
    }
    /// Which apps to record while system audio is selected.
    var recordingScope: SystemAudioScope = .everything
    /// The file name typed on the recording screen; derived from the date when empty.
    var recordingName = ""

    // MARK: - Settings

    var settings: WhisperSettings {
        didSet { persistSettings() }
    }

    /// The app's behaviour — independent of the presets and of a job's settings.
    var preferences: AppPreferences {
        didSet {
            // Turning live transcription off makes the accurate pass mandatory;
            // otherwise the recording would never become text at all.
            if !preferences.liveTranscription, !preferences.runSecondPass {
                preferences.runSecondPass = true
                return
            }
            PreferencesStore.save(preferences)
        }
    }

    /// The presets the user saved themselves — `presets.json`.
    private(set) var customPresets: [StoredPreset] = []

    /// The selected row in the queue; the text and log in the bottom pane follow it.
    var selectedItemID: TranscriptionItem.ID?

    var overwritePrompt: OverwritePrompt?

    let layout: RuntimeLayout
    private let provisioner: RuntimeProvisioner
    private let engine: PythonWhisperEngine
    private var provisionTask: Task<Void, Never>?
    private var activity: (any NSObjectProtocol)?

    struct SetupError: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let detail: String
    }

    struct OverwritePrompt: Identifiable {
        let id = UUID()
        var files: [URL]
        var urls: [URL]
    }

    init(layout: RuntimeLayout = RuntimeLayout()) {
        self.layout = layout
        self.provisioner = RuntimeProvisioner(layout: layout)
        let engine = PythonWhisperEngine(layout: layout)
        self.engine = engine
        self.queue = JobQueue(engine: engine)
        self.settings = SettingsStore.load()
        self.preferences = PreferencesStore.load()
        // Recording diagnostics go to a file of their own, so we can read back where
        // the microphone permission was refused (docs/LIVE_TRANSCRIPTION.md).
        let logs = layout.logs
        self.recording = RecordingController(
            engine: engine,
            log: { line in RecordingLog.append(line, to: logs) }
        )
        self.customPresets = PresetStore.load(from: layout.presets)
        self.queue.onFinish = { [weak self] in self?.queueDidFinish() }
    }

    var selectedItem: TranscriptionItem? {
        guard let selectedItemID else { return queue.items.last }
        return queue.items.first { $0.id == selectedItemID } ?? queue.items.last
    }

    // MARK: - Runtime environment

    func refreshRuntimeState() async {
        guard !runtime.isInstalling else { return }
        runtime = .checking
        runtime = await provisioner.currentState()
        if runtime.isReady {
            await loadCapabilities()
        }
    }

    func startProvisioning() {
        guard provisionTask == nil else { return }
        setupError = nil
        setupLog = []
        runtime = .installing(step: .installPython, fraction: 0)

        provisionTask = Task { [provisioner] in
            do {
                let info = try await provisioner.provision { [weak self] state in
                    Task { @MainActor in self?.apply(state) }
                }
                self.runtime = .ready(info)
                await self.loadCapabilities()
            } catch is CancellationError {
                self.runtime = .notInstalled
            } catch let error as RuntimeError {
                self.fail(
                    error.errorDescription ?? String(localized: "Setup failed."), error.detail)
            } catch {
                self.fail(String(localized: "Setup failed."), error.localizedDescription)
            }
            self.provisionTask = nil
        }
    }

    /// Runs the health check again — it does **not** delete the environment.
    ///
    /// Re-downloading 890 MB because of a transient probe failure is the wrong response;
    /// we try the cheap thing first.
    func retryHealthCheck() async {
        setupError = nil
        await refreshRuntimeState()
    }

    func cancelProvisioning() {
        provisionTask?.cancel()
        provisionTask = nil
        runtime = .notInstalled
    }

    func reinstallRuntime() async {
        try? await provisioner.removeRuntime()
        capabilities = nil
        runtime = .notInstalled
        startProvisioning()
    }

    func removeRuntime() async {
        try? await provisioner.removeRuntime()
        capabilities = nil
        runtime = .notInstalled
    }

    /// How much disk the installed environment occupies — for the Settings window.
    func runtimeSize() async -> Int64 {
        await provisioner.installedSize()
    }

    /// The model/language/format lists come from the worker; the app hard-codes none.
    func loadCapabilities() async {
        do {
            capabilities = try await engine.capabilities()
            capabilitiesError = nil
            alignSettingsWithCapabilities()
        } catch {
            capabilitiesError = error.localizedDescription
        }
    }

    /// If the installed whisper version doesn't know the selected model, we fall back to a
    /// supported one rather than silently sending a broken job.
    private func alignSettingsWithCapabilities() {
        guard let capabilities else { return }
        if !capabilities.models.contains(settings.model) {
            settings.model =
                capabilities.models.contains("small") ? "small" : (capabilities.models.first ?? "small")
        }
        if settings.device == .mps, !capabilities.supportsMPS {
            settings.device = .cpu
        }
    }

    // MARK: - Recording

    /// The folder recordings are written to.
    var recordingDirectory: URL {
        preferences.recordingDirectory ?? AppPreferences.defaultRecordingDirectory
    }

    func presentRecording() {
        isRecordingSheetPresented = true
    }

    func startRecording() async {
        await recording.start(
            source: recordingSource,
            scope: recordingScope,
            live: preferences.liveTranscription ? liveConfig() : nil,
            named: recordingName,
            in: recordingDirectory
        )
    }

    private func liveConfig() -> LiveConfig {
        LiveConfig(
            jobID: UUID().uuidString,
            model: preferences.liveModel,
            modelDir: (settings.modelDirectory ?? WhisperSettings.defaultModelDirectory).path,
            language: settings.language,
            task: settings.task,
            // The live side is always CPU: MPS is experimental and the cost of failing
            // mid-recording is high (ADR-012).
            device: .cpu
        )
    }

    /// Finishes the recording, writes the live text **at once** and queues the second pass.
    ///
    /// The order matters: the second pass can take minutes, and the user shouldn't spend
    /// that time with no text at all in hand.
    func finishRecording() async {
        let result = await recording.finish()
        isRecordingSheetPresented = false
        // The name mustn't carry over to the next recording; otherwise the second one
        // would take the same name as "… (2)".
        recordingName = ""
        guard let result else { return }

        // If the accurate pass is coming too, the live text goes to its own file
        // (`… (live).txt`); otherwise it is the final output and takes the plain name.
        let transcript = recording.transcript
        let written = LiveTranscriptWriter.write(
            transcript, for: result.url, settings: settings, suffixed: preferences.runSecondPass)
        if !written.isEmpty {
            RecordingLog.append(
                "live text written: \(written.map(\.lastPathComponent).joined(separator: ", "))",
                to: layout.logs
            )
        }

        guard preferences.runSecondPass else { return }

        queue.enqueue([result.url], settings: settings)
        selectedItemID = queue.items.last?.id
        if preferences.autoStartOnAdd {
            startQueue()
        }
    }

    func cancelRecording() {
        recording.cancel()
        isRecordingSheetPresented = false
        recordingName = ""
    }

    // MARK: - Queue

    func addFiles(_ urls: [URL]) {
        let added = queue.enqueue(urls, settings: settings)
        if added > 0, selectedItemID == nil {
            selectedItemID = queue.items.last?.id
        }
        // Auto-start doesn't skip the overwrite confirmation — startQueue() asks.
        if added > 0, preferences.autoStartOnAdd, !queue.isRunning {
            startQueue()
        }
    }

    func openFilePanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = SupportedMedia.contentTypes
        panel.allowsOtherFileTypes = true
        panel.prompt = String(localized: "Add")
        panel.message = String(localized: "Choose the audio or video files to transcribe")

        if panel.runModal() == .OK {
            addFiles(panel.urls)
        }
    }

    /// Starts the queue. If a file would be overwritten, it asks for confirmation first.
    func startQueue() {
        guard settings.isRunnable else { return }

        if !settings.overwrite {
            let pending = queue.items.filter { $0.state == .queued }
            let existing =
                pending
                .flatMap { $0.settings.expectedOutputs(for: $0.url) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }

            if !existing.isEmpty {
                overwritePrompt = OverwritePrompt(files: existing, urls: pending.map(\.url))
                return
            }
        }

        beginActivity()
        queue.start()
    }

    /// After confirmation: allow overwriting for this round.
    func confirmOverwriteAndStart() {
        overwritePrompt = nil
        for item in queue.items where item.state == .queued {
            item.settings.overwrite = true
        }
        beginActivity()
        queue.start()
    }

    func stopQueue() {
        queue.stop()
        endActivity()
    }

    func retry(_ item: TranscriptionItem) {
        queue.retry(item, settings: settings)
        beginActivity()
    }

    func queueDidFinish() {
        endActivity()
        if preferences.notifyOnFinish {
            notifyCompletion()
        }
        if preferences.revealOnFinish {
            revealFinishedOutputs()
        }
    }

    /// Reveals the files produced in this round, selected, in Finder.
    private func revealFinishedOutputs() {
        let urls = queue.items
            .filter { $0.state == .completed }
            .compactMap { $0.result?.outputs.first?.url }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: - Preventing sleep

    /// Keeps the Mac awake during a long transcription.
    private func beginActivity() {
        guard preferences.keepSystemAwake, activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Transcribing audio files"
        )
    }

    private func endActivity() {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
        activity = nil
    }

    // MARK: - Notification

    private func notifyCompletion() {
        let completed = queue.items.count { $0.state == .completed }
        let failed = queue.items.count { $0.state == .failed }
        guard completed + failed > 0, !NSApp.isActive else { return }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Transcription finished")
        content.body =
            failed > 0
            ? String(localized: "\(completed) files completed, \(failed) failed")
            : String(localized: "\(completed) files completed")

        // async rather than the callback form: `UNUserNotificationCenter` and
        // `UNMutableNotificationContent` aren't Sendable and can't be moved into a
        // @Sendable closure. Here everything stays on the main actor.
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            guard
                let granted = try? await center.requestAuthorization(options: [.alert, .sound]),
                granted
            else {
                return
            }
            try? await center.add(
                UNNotificationRequest(
                    identifier: UUID().uuidString,
                    content: content,
                    trigger: nil
                )
            )
        }
    }

    // MARK: - Settings persistence

    func applyPreset(_ preset: WhisperSettings.Preset) {
        var next = preset.settings
        // The user's folder and device preferences don't change with a preset.
        next.outputLocation = settings.outputLocation
        next.customOutputDirectory = settings.customOutputDirectory
        next.modelDirectory = settings.modelDirectory
        next.device = settings.device
        next.overwrite = settings.overwrite
        settings = next
    }

    private func persistSettings() {
        SettingsStore.save(settings)
    }

    // MARK: - User presets

    /// Saves the current settings under the given name, replacing one of the same name.
    ///
    /// Machine-specific preferences like the folder and the model directory do **not** go
    /// into a preset: a preset carries "how to transcribe", not "where to write".
    func saveCurrentAsPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var stored = settings
        stored.outputLocation = WhisperSettings().outputLocation
        stored.customOutputDirectory = nil
        stored.modelDirectory = nil

        customPresets = PresetStore.upsert(
            StoredPreset(name: trimmed, settings: stored),
            into: customPresets
        )
        PresetStore.save(customPresets, to: layout.presets)
    }

    func deletePreset(_ preset: StoredPreset) {
        customPresets.removeAll { $0.id == preset.id }
        PresetStore.save(customPresets, to: layout.presets)
    }

    func applyCustomPreset(_ preset: StoredPreset) {
        applyPreset(.init(name: preset.name, detail: preset.detail, settings: preset.settings))
    }

    // MARK: - Setup helpers

    private func apply(_ state: RuntimeState) {
        runtime = state
        if case .installing(let step, _) = state {
            appendLog("\(step.rawValue)/\(ProvisionStep.count) \(step.title)")
        }
    }

    private func appendLog(_ line: String) {
        guard setupLog.last != line else { return }
        setupLog.append(line)
        if setupLog.count > 200 {
            setupLog.removeFirst(setupLog.count - 200)
        }
    }

    private func fail(_ message: String, _ detail: String) {
        setupError = SetupError(message: message, detail: detail)
        runtime = .broken(reason: message)
    }
}

/// Appends recording diagnostics to `logs/recording.log`.
enum RecordingLog {
    static func append(_ line: String, to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("recording.log")
        let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(stamped.utf8))
            try? handle.close()
        } else {
            try? Data(stamped.utf8).write(to: url)
        }
    }
}

/// Stores the app preferences in `UserDefaults`.
enum PreferencesStore {
    private static let key = "appPreferences"

    static func load() -> AppPreferences {
        guard
            let data = UserDefaults.standard.data(forKey: key),
            let preferences = try? JSONDecoder().decode(AppPreferences.self, from: data)
        else {
            return AppPreferences()
        }
        return preferences
    }

    static func save(_ preferences: AppPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// Stores the settings in `UserDefaults`.
enum SettingsStore {
    private static let key = "whisperSettings"

    static func load() -> WhisperSettings {
        guard
            let data = UserDefaults.standard.data(forKey: key),
            let settings = try? JSONDecoder().decode(WhisperSettings.self, from: data)
        else {
            return WhisperSettings()
        }
        return settings
    }

    static func save(_ settings: WhisperSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
