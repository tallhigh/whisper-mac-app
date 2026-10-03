import Foundation
import Testing

@testable import WhisperTranscriber

@Suite("The recording file name")
struct RecordingFileTests {

    private var date: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 10
        components.day = 2
        components.hour = 14
        components.minute = 30
        return Calendar(identifier: .gregorian).date(from: components) ?? Date()
    }

    @Test("The name carries the date and the time")
    func nameCarriesTimestamp() {
        #expect(RecordingFile.stamp(date) == "2026-10-02 14-30")
        #expect(RecordingFile.name(at: date).hasSuffix("2026-10-02 14-30.m4a"))
    }

    /// The recording itself is unrecoverable data; overwriting an existing file would mean
    /// destroying the user's previous recording.
    @Test("On a collision a number is appended, nothing is overwritten")
    func avoidsCollision() {
        let directory = URL(filePath: "/tmp/recordings")
        let taken: Set<String> = [
            "/tmp/recordings/Recording 2026-10-02 14-30.m4a",
            "/tmp/recordings/Recording 2026-10-02 14-30 (2).m4a",
        ]

        let url = RecordingFile.uniqueURL(in: directory, at: date) { taken.contains($0.path) }
        #expect(url.lastPathComponent == "Recording 2026-10-02 14-30 (3).m4a")
    }

    @Test("The name the user gave is used")
    func usesGivenName() {
        let url = RecordingFile.uniqueURL(
            in: URL(filePath: "/tmp/k"), named: "Team meeting", at: date) { _ in false }
        #expect(url.lastPathComponent == "Team meeting.m4a")
    }

    /// `/` is the path separator on macOS and `:` was Finder's old one.
    @Test("Characters a file name cannot hold are stripped")
    func sanitizesIllegalCharacters() {
        #expect(RecordingFile.sanitize("2026/10/02: meeting şçğü") == "2026-10-02- meeting şçğü")
        #expect(RecordingFile.sanitize("  şçğü  ") == "şçğü")
        // A leading dot would hide the file.
        #expect(RecordingFile.sanitize("...hidden") == "hidden")
    }

    @Test("An empty name falls back to the default")
    func emptyNameFallsBackToDefault() {
        #expect(RecordingFile.sanitize("   ") == nil)
        #expect(RecordingFile.sanitize("") == nil)
        // A name made only of forbidden characters doesn't empty out, it becomes hyphens:
        // that is the valid name closest to what the user typed.
        #expect(RecordingFile.sanitize("///") == "---")

        let url = RecordingFile.uniqueURL(in: URL(filePath: "/tmp/k"), named: "  ", at: date) { _ in
            false
        }
        #expect(url.lastPathComponent == "Recording 2026-10-02 14-30.m4a")
    }

    @Test("An overly long name is truncated")
    func truncatesLongName() throws {
        let long = String(repeating: "ş", count: 400)
        let cleaned = try #require(RecordingFile.sanitize(long))
        #expect(cleaned.count == 120)
    }

    @Test("A given name goes through the collision check too")
    func givenNameAvoidsCollision() {
        let taken: Set<String> = ["/tmp/k/Meeting.m4a"]
        let url = RecordingFile.uniqueURL(in: URL(filePath: "/tmp/k"), named: "Meeting", at: date) {
            taken.contains($0.path)
        }
        #expect(url.lastPathComponent == "Meeting (2).m4a")
    }

    @Test("In an empty folder no number is appended")
    func noSuffixWhenFree() {
        let url = RecordingFile.uniqueURL(in: URL(filePath: "/tmp/k"), at: date) { _ in false }
        #expect(url.lastPathComponent == "Recording 2026-10-02 14-30.m4a")
    }
}

@Suite("Audio format conversion")
struct CaptureFormatTests {

    /// `whisper_worker.decode_audio` takes s16le from ffmpeg and divides by 32768; the live
    /// path must produce the same representation so no difference remains between the passes.
    @Test("float32 samples are scaled to int16")
    func scalesToInt16() {
        #expect(CaptureFormat.int16Samples(from: [0]) == [0])
        #expect(CaptureFormat.int16Samples(from: [1]) == [32767])
        #expect(CaptureFormat.int16Samples(from: [-1]) == [-32767])
        #expect(CaptureFormat.int16Samples(from: [0.5]) == [16383])
    }

    @Test("Out-of-range samples are clipped")
    func clampsOutOfRange() {
        #expect(CaptureFormat.int16Samples(from: [2.5, -9]) == [32767, -32767])
    }

    @Test("The target format is the one whisper expects")
    func targetFormatMatchesWhisper() throws {
        let format = try #require(CaptureFormat.float32)
        #expect(format.sampleRate == 16_000)
        #expect(format.channelCount == 1)
    }
}

@Suite("The recording state machine")
@MainActor
struct RecordingControllerTests {

    private func controller(_ capture: FakeCapture, grace: TimeInterval = 5)
        -> RecordingController
    {
        RecordingController(
            makeCapture: { _, _ in capture }, silenceGrace: grace, log: { _ in })
    }

    private var directory: URL {
        URL(filePath: NSTemporaryDirectory()).appending(path: "wt-rec-\(UUID().uuidString)")
    }

    /// Finishing used to wait inline for the worker to transcribe the last uncommitted
    /// window, which kept the sheet on screen for seconds (ADR-022). The wait moved to
    /// `waitForFinalText()`, which must be harmless when there was no live session at all —
    /// the tests use a fake capture and never start one — and must not mind being called
    /// twice.
    @Test("Waiting for the final text is safe with no live session")
    func waitForFinalTextWithoutSession() async throws {
        let capture = FakeCapture(duration: 5)
        let state = controller(capture)

        await state.start(in: directory)
        _ = await state.finish()

        #expect(!state.isFinalizing)
        await state.waitForFinalText()
        await state.waitForFinalText()
        #expect(!state.isFinalizing)
    }

    @Test("Start, pause, resume, finish")
    func happyPath() async throws {
        let capture = FakeCapture(duration: 12)
        let state = controller(capture)

        await state.start(in: directory)
        #expect(state.state == .recording)
        #expect(state.fileURL != nil)

        state.pause()
        #expect(state.state == .paused)
        #expect(capture.isPaused)

        state.resume()
        #expect(state.state == .recording)
        #expect(!capture.isPaused)

        let result = try #require(await state.finish())
        #expect(result.duration == 12)
        #expect(state.state == .idle)
    }

    /// Without permission, no file should be created and the user should be offered an action.
    @Test("When permission is denied it errors and opens no file")
    func deniedAccessFails() async {
        let capture = FakeCapture(access: .denied)
        let state = controller(capture)

        await state.start(in: directory)

        #expect(state.state == .failed(reason: CaptureError.accessDenied.errorDescription ?? ""))
        #expect(state.fileURL == nil)
        #expect(capture.startCount == 0)
        #expect(state.failure?.suggestion?.contains("System Settings") == true)
    }

    @Test("An undetermined permission is requested, and recording starts once granted")
    func undeterminedAccessIsRequested() async {
        let capture = FakeCapture(access: .undetermined, accessAfterRequest: .granted)
        let state = controller(capture)

        await state.start(in: directory)

        #expect(capture.requestCount == 1)
        #expect(state.state == .recording)
    }

    /// A button pressed by accident mustn't put an empty file in the queue.
    @Test("A too-short recording deletes the file and returns nil")
    func tooShortRecordingIsDiscarded() async throws {
        let capture = FakeCapture(duration: 0.1)
        let state = controller(capture)
        let folder = directory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        await state.start(in: folder)
        let url = try #require(state.fileURL)
        try Data().write(to: url)

        #expect(await state.finish() == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Cancelling deletes the file")
    func cancelRemovesFile() async throws {
        let capture = FakeCapture(duration: 30)
        let state = controller(capture)
        let folder = directory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        await state.start(in: folder)
        let url = try #require(state.fileURL)
        try Data().write(to: url)

        state.cancel()

        #expect(state.state == .idle)
        #expect(state.fileURL == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// The capturer is chosen by source; the microphone and system audio use different
    /// implementations.
    @Test("The source is passed to the capture factory")
    func sourceReachesFactory() async {
        let capture = FakeCapture(duration: 3)
        let seen = LockedValue<(AudioSource, SystemAudioScope)?>(nil)
        let state = RecordingController(
            makeCapture: { source, scope in
                seen.set((source, scope))
                return capture
            },
            log: { _ in }
        )

        let app = AudioApplication(pids: [42], bundleID: "us.zoom.xos", name: "Zoom")
        await state.start(source: .both, scope: .apps([app]), in: directory)

        let value = seen.get()
        #expect(value?.0 == .both)
        #expect(value?.1 == .apps([app]))
    }

    // MARK: - The system-audio silence watch (ADR-026)

    /// The case this exists for: the microphone is loud, the tap is dead, and a single meter
    /// fed by the sum looks perfectly healthy.
    @Test("System audio staying silent is reported, without failing the recording")
    func noticesASilentTap() async {
        let capture = FakeCapture(duration: 3)
        let state = controller(capture)
        let start = Date()

        await state.start(source: .both, in: directory, now: start)
        let loudMicrophoneOnly = CaptureLevels(combined: 0.6, microphone: 0.6, system: 0)

        state.apply(loudMicrophoneOnly, now: start.addingTimeInterval(1))
        #expect(!state.systemAudioSilent, "a second's silence is not evidence of anything")

        state.apply(
            loudMicrophoneOnly,
            now: start.addingTimeInterval(state.silenceGrace + 1))
        #expect(state.systemAudioSilent)
        #expect(state.state == .recording, "the recording carries on; the microphone is real")
        #expect(state.failure == nil)
    }

    @Test("System audio arriving clears the warning")
    func systemAudioClearsTheWarning() async {
        let capture = FakeCapture(duration: 3)
        let state = controller(capture)
        let start = Date()

        await state.start(source: .both, in: directory, now: start)
        let late = start.addingTimeInterval(state.silenceGrace + 1)
        state.apply(CaptureLevels(combined: 0.6, microphone: 0.6, system: 0), now: late)
        #expect(state.systemAudioSilent)

        state.apply(CaptureLevels(combined: 0.6, microphone: 0.5, system: 0.3), now: late)
        #expect(!state.systemAudioSilent)
    }

    /// With the microphone alone there is no tap to be silent about.
    @Test("The warning never appears when system audio was not asked for")
    func staysQuietForMicrophoneOnly() async {
        let capture = FakeCapture(duration: 3)
        let state = controller(capture)
        let start = Date()

        await state.start(source: .microphone, in: directory, now: start)
        state.apply(
            CaptureLevels.microphoneOnly(0.6),
            now: start.addingTimeInterval(state.silenceGrace + 10))

        #expect(!state.systemAudioSilent)
    }

    /// An unattributable layout must not produce an accusation.
    @Test("An unknown breakdown does not trigger the warning")
    func unknownBreakdownStaysQuiet() async {
        let capture = FakeCapture(duration: 3)
        let state = controller(capture)
        let start = Date()

        await state.start(source: .both, in: directory, now: start)
        state.apply(
            CaptureLevels(combined: 0.6, microphone: nil, system: nil),
            now: start.addingTimeInterval(state.silenceGrace + 10))

        #expect(!state.systemAudioSilent)
    }

    @Test("Pausing and resuming restarts the silence clock")
    func resumeResetsTheClock() async {
        let capture = FakeCapture(duration: 3)
        let state = controller(capture)
        let start = Date()

        await state.start(source: .both, in: directory, now: start)
        state.apply(
            CaptureLevels(combined: 0.6, microphone: 0.6, system: 0),
            now: start.addingTimeInterval(state.silenceGrace + 1))
        #expect(state.systemAudioSilent)

        state.pause()
        state.resume()
        #expect(!state.systemAudioSilent)
    }

    /// The level the meter reads has to keep coming from the capture layer, breakdown or not.
    @Test("The combined level reaches the meter")
    func combinedLevelReachesTheMeter() async {
        let capture = FakeCapture(duration: 3)
        let state = controller(capture)

        await state.start(in: directory)
        capture.report(CaptureLevels.microphoneOnly(0.75))
        await Task.yield()

        #expect(state.level == 0.75)
        #expect(state.levels.microphone == 0.75)
    }

    /// The failure with no error attached: the tap has no channels, the aggregate produces no
    /// input stream, the IOProc is never called, and the file comes out zero seconds long.
    @Test("A recording that receives nothing at all says so")
    func noticesADeadAggregate() async throws {
        let capture = FakeCapture(duration: 0)
        let state = controller(capture, grace: 0.6)

        await state.start(source: .both, in: directory)
        #expect(!state.receivedNoAudio, "nothing is wrong in the first moment")

        // The ticker is the only thing still running; the level handler is the thing that
        // isn't being called, so it cannot be what reports this.
        try await waitUntil { state.receivedNoAudio }
        #expect(state.receivedNoAudio)
    }

    @Test("Audio arriving clears the no-audio warning")
    func audioClearsTheDeadAggregateWarning() async throws {
        let capture = FakeCapture(duration: 1)
        let state = controller(capture, grace: 0.6)

        await state.start(source: .both, in: directory)
        try await waitUntil { state.receivedNoAudio }

        state.apply(CaptureLevels(combined: 0.5, microphone: 0.5, system: 0.5))
        #expect(!state.receivedNoAudio)
    }

    @Test("A second start while recording is ignored")
    func doubleStartIsIgnored() async {
        let capture = FakeCapture(duration: 5)
        let state = controller(capture)

        await state.start(in: directory)
        await state.start(in: directory)

        #expect(capture.startCount == 1)
    }
}

/// A fake capturer that never touches the microphone.
private final class FakeCapture: AudioCapturing, @unchecked Sendable {

    private let lock = NSLock()
    private let duration: TimeInterval
    private var currentAccess: CaptureAccess
    private let accessAfterRequest: CaptureAccess?
    private var started = 0
    private var requested = 0
    private var pausedFlag = false
    private var levels: LevelHandler?

    init(
        access: CaptureAccess = .granted,
        accessAfterRequest: CaptureAccess? = nil,
        duration: TimeInterval = 1
    ) {
        self.currentAccess = access
        self.accessAfterRequest = accessAfterRequest
        self.duration = duration
    }

    var access: CaptureAccess { lock.withLock { currentAccess } }
    var startCount: Int { lock.withLock { started } }
    var requestCount: Int { lock.withLock { requested } }
    var isPaused: Bool { lock.withLock { pausedFlag } }

    func requestAccess() async -> CaptureAccess {
        lock.withLock {
            requested += 1
            if let accessAfterRequest { currentAccess = accessAfterRequest }
            return currentAccess
        }
    }

    func start(
        writingTo url: URL,
        onLevels: @escaping LevelHandler,
        onSamples: SampleHandler?
    ) throws {
        lock.withLock {
            started += 1
            levels = onLevels
        }
    }

    /// Reports a level the way the real capturers do, so the controller's silence watch can be
    /// exercised without any audio.
    func report(_ value: CaptureLevels) {
        lock.withLock { levels }?(value)
    }

    func pause() { lock.withLock { pausedFlag = true } }
    func resume() { lock.withLock { pausedFlag = false } }

    @discardableResult
    func stop() -> TimeInterval {
        lock.withLock { pausedFlag = false }
        return duration
    }
}



/// Waits for a condition the controller's ticker will eventually make true.
///
/// The ticker runs on a 500 ms period and the grace period is counted in seconds, so the
/// waits here are deliberately generous; a fixed sleep would either be flaky or slow.
@MainActor
private func waitUntil(
    timeout: TimeInterval = 5,
    _ condition: () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(100))
    }
    Issue.record("the condition never became true within \(timeout) s")
}

/// For capturing a value from a `@Sendable` closure in the tests.
private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
    func get() -> Value { lock.withLock { value } }
}

@Suite("Audio sources")
struct AudioSourceTests {

    @Test("A source knows which channels it captures")
    func capabilities() {
        #expect(AudioSource.microphone.capturesMicrophone)
        #expect(!AudioSource.microphone.capturesSystemAudio)

        #expect(!AudioSource.systemAudio.capturesMicrophone)
        #expect(AudioSource.systemAudio.capturesSystemAudio)

        #expect(AudioSource.both.capturesMicrophone)
        #expect(AudioSource.both.capturesSystemAudio)
    }

    @Test("The scope gives the selected processes")
    func scopeSelection() {
        let app = AudioApplication(pids: [2], bundleID: "com.google.Chrome", name: "Chrome")
        #expect(SystemAudioScope.everything.selected.isEmpty)
        #expect(SystemAudioScope.apps([app]).selected == [app])
    }

    @Test("The source preference survives the coding round trip")
    func sourceSurvivesRoundTrip() throws {
        var preferences = AppPreferences()
        preferences.recordingSource = .both
        let data = try JSONEncoder().encode(preferences)
        #expect(try JSONDecoder().decode(AppPreferences.self, from: data).recordingSource == .both)
    }

    @Test("An older preference block falls back to the default source")
    func legacyPreferencesDefaultToMicrophone() throws {
        let data = try #require(#"{"autoStartOnAdd":true}"#.data(using: .utf8))
        let preferences = try JSONDecoder().decode(AppPreferences.self, from: data)
        #expect(preferences.recordingSource == .microphone)
    }
}

@Suite("The live transcript")
struct LiveTranscriptTests {

    private func transcript(_ parts: [(String, Double, Double)]) -> LiveTranscript {
        var transcript = LiveTranscript()
        for (text, start, end) in parts {
            transcript.append(.init(text: text, start: start, end: end))
        }
        return transcript
    }

    @Test("Empty and whitespace-only segments are skipped")
    func skipsBlankSegments() {
        var live = LiveTranscript()
        live.append(.init(text: "   ", start: 0, end: 1))
        live.append(.init(text: " Hello. ", start: 1, end: 2))

        #expect(live.segments.count == 1)
        #expect(live.segments[0].text == "Hello.")
    }

    @Test("The txt format writes every segment on its own line")
    func plainTextMatchesWhisperLayout() {
        let live = transcript([("One.", 0, 2), ("Two.", 2, 4)])
        #expect(live.plainText == "One.\nTwo.\n")
    }

    /// It has to be the same layout as the worker's `write_notes` output; the second pass
    /// will overwrite the same file.
    @Test("The notes format imitates the worker layout")
    func notesMatchesWorkerLayout() {
        let live = transcript([("One.", 0, 2), ("Two.", 125.4, 130)])
        #expect(live.notesText == "- [00:00] One.\n- [02:05] Two.\n")
    }

    /// We don't imitate whisper's formats (CLAUDE.md, architecture rule 5).
    @Test("Only txt and notes can be produced")
    func onlyTextFormatsAreWritable() {
        let live = transcript([("Bir.", 0, 2)])
        #expect(live.text(for: .txt) != nil)
        #expect(live.text(for: .notes) != nil)
        for format in [OutputFormat.srt, .vtt, .json, .tsv] {
            #expect(live.text(for: format) == nil, "\(format.rawValue)")
        }
    }

    /// The bug this fixes: with only `srt` and `vtt` ticked — a perfectly ordinary choice —
    /// the live text could produce neither, so nothing was written and the only record of
    /// what was heard while recording was thrown away (ADR-025).
    @Test("The live text is written even when txt is not among the chosen formats")
    func liveTextIsAlwaysWritten() throws {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "wt-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var settings = WhisperSettings()
        settings.outputLocation = .customFolder
        settings.customOutputDirectory = directory
        settings.outputFormats = [.srt, .vtt]

        let audio = directory.appending(path: "Meeting.m4a")
        let written = LiveTranscriptWriter.write(
            transcript([("Hello.", 0, 2)]), for: audio, settings: settings, suffixed: false)

        #expect(written.map(\.lastPathComponent) == ["Meeting.txt"])
    }

    @Test("notes is written alongside txt when it is selected")
    func liveTextAddsNotesWhenChosen() {
        var settings = WhisperSettings()
        settings.outputFormats = [.notes, .srt]

        #expect(LiveTranscriptWriter.formats(for: settings) == [.txt, .notes])
    }

    /// The live text can only ever be those two; the rest need fields it does not have.
    @Test("Only txt and notes are ever written live")
    func liveFormatsAreBounded() {
        var settings = WhisperSettings()
        settings.outputFormats = Set(OutputFormat.allCases)

        let formats = Set(LiveTranscriptWriter.formats(for: settings))
        #expect(formats == LiveTranscript.writableFormats)
    }

    /// `txt` is always written (ADR-025); what this pins is the other half — a selected
    /// format the live text *cannot* produce is skipped rather than written empty or faked.
    @Test("A selected format the live text cannot produce is skipped")
    func writerSkipsFormatsItCannotProduce() throws {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "wt-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var settings = WhisperSettings()
        settings.outputLocation = .customFolder
        settings.customOutputDirectory = directory
        settings.outputFormats = [.txt, .notes, .srt]

        let audio = directory.appending(path: "Recording.m4a")
        let written = LiveTranscriptWriter.write(
            transcript([("Hello.", 0, 2)]), for: audio, settings: settings, suffixed: false)

        #expect(written.map(\.lastPathComponent).sorted() == ["Recording.md", "Recording.txt"])
        #expect(try String(contentsOf: directory.appending(path: "Recording.txt"), encoding: .utf8)
            == "Hello.\n")
    }

    /// If the accurate pass is coming too, the live text goes to its own file; otherwise the
    /// second pass would overwrite it and the live text would be lost.
    @Test("With the accurate pass coming, the live transcript goes to its own file")
    func suffixedWriteKeepsLiveTextSeparate() throws {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "wt-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var settings = WhisperSettings()
        settings.outputLocation = .customFolder
        settings.customOutputDirectory = directory
        settings.outputFormats = [.txt]

        let audio = directory.appending(path: "Meeting.m4a")
        let written = LiveTranscriptWriter.write(
            transcript([("Hello.", 0, 2)]), for: audio, settings: settings, suffixed: true)

        let name = try #require(written.first?.lastPathComponent)
        #expect(name.hasSuffix(".txt"))
        #expect(name.contains("Meeting"))
        // It mustn't collide with the name the accurate pass will write.
        #expect(name != "Meeting.txt")
    }

    @Test("No file is written for an empty transcript")
    func emptyTranscriptWritesNothing() {
        var settings = WhisperSettings()
        settings.outputFormats = [.txt]
        let written = LiveTranscriptWriter.write(
            LiveTranscript(), for: URL(filePath: "/tmp/a.m4a"), settings: settings, suffixed: true)
        #expect(written.isEmpty)
    }
}

@Suite("The live protocol events")
struct LiveEventTests {

    @Test("the committed event is decoded")
    func decodesCommitted() {
        let event = EngineEvent.decode(
            line: #"{"v":2,"type":"committed","text":"Hello.","start":0.0,"end":2.3}"#)
        guard case .committed(let value) = event else {
            Issue.record("expected committed: \(event)")
            return
        }
        #expect(value.text == "Hello.")
        #expect(value.start == 0.0)
        #expect(value.end == 2.3)
    }

    @Test("the partial event is decoded")
    func decodesPartial() {
        let event = EngineEvent.decode(line: #"{"v":2,"type":"partial","text":"Three separate"}"#)
        guard case .partial(let text) = event else {
            Issue.record("expected partial: \(event)")
            return
        }
        #expect(text == "Three separate")
    }

    /// Live events mustn't fill the LOG tab; the text is already on screen.
    @Test("The live events produce no log line")
    func liveEventsAreNotLogged() {
        #expect(EngineEvent.partial(text: "x").logLine == nil)
        #expect(EngineEvent.committed(.init(text: "x", start: 0, end: 1)).logLine == nil)
    }

    @Test("The live configuration writes the keys the worker expects")
    func configEncodesSnakeCase() throws {
        let config = LiveConfig(
            jobID: "abc", model: "small", modelDir: "/m", language: "tr",
            task: .transcribe, device: .cpu)
        let line = try config.jsonLine()

        #expect(line.contains("\"job_id\":\"abc\""))
        #expect(line.contains("\"model_dir\":\"\\/m\"") || line.contains("\"model_dir\":\"/m\""))
        #expect(line.contains("\"v\":2"))
    }
}
