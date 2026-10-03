import Foundation
import Testing

@testable import WhisperTranscriber

@Suite("Settings persistence")
struct SettingsPersistenceTests {

    /// The advanced settings were removed from the interface; older blocks must still be
    /// read and the remaining settings preserved. Unrecognised keys are dropped silently.
    @Test("An older block holding removed advanced keys is read")
    func decodesLegacyBlobWithRemovedKeys() throws {
        let legacy = """
            {"model":"large-v3","language":"en","task":"translate",
             "outputFormats":["srt"],"outputLocation":"besideSource",
             "overwrite":true,"device":"cpu",
             "initialPrompt":"Mehmet","beamSize":3,"bestOf":2,"threads":8,
             "temperature":0.4,"wordTimestamps":true,"maxLineWidth":42}
            """
        let data = try #require(legacy.data(using: .utf8))
        let settings = try JSONDecoder().decode(WhisperSettings.self, from: data)

        #expect(settings.model == "large-v3")
        #expect(settings.language == "en")
        #expect(settings.task == .translate)
        #expect(settings.outputFormats == [.srt])
        #expect(settings.overwrite)
        // Added after this block was written, so it has to come back as the default rather
        // than resetting everything else (ADR-013). `"threads":8` above is the unrelated
        // removed advanced key, and is still ignored.
        #expect(settings.cpuBudget == .balanced)
    }

    @Test("A completely empty block gives every default")
    func decodesEmptyBlob() throws {
        let data = try #require("{}".data(using: .utf8))
        #expect(try JSONDecoder().decode(WhisperSettings.self, from: data) == WhisperSettings())
    }

    /// A `nil` language is "detect automatically"; because the encoder writes an explicit
    /// `null`, the decoder mustn't turn it into the default (`"tr"`).
    @Test("Automatic language detection survives the coding round trip")
    func automaticLanguageSurvivesRoundTrip() throws {
        var settings = WhisperSettings()
        settings.language = nil
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(WhisperSettings.self, from: data).language == nil)
    }

    @Test("With no language key at all the default stays Turkish")
    func missingLanguageKeepsDefault() throws {
        let data = try #require(#"{"model":"small"}"#.data(using: .utf8))
        #expect(try JSONDecoder().decode(WhisperSettings.self, from: data).language == "tr")
    }

    @Test("A full round trip preserves the settings exactly")
    func fullRoundTrip() throws {
        var settings = WhisperSettings()
        settings.model = "large-v3-turbo"
        settings.outputFormats = [.srt, .vtt, .notes]
        settings.device = .mps
        settings.customOutputDirectory = URL(filePath: "/tmp/output folder 🎙 şçğü")

        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(WhisperSettings.self, from: data) == settings)
    }
}

@Suite("The simplified job definition")
struct SimplifiedJobTests {

    private func payload(_ settings: WhisperSettings) throws -> String {
        try settings.jobPayload(for: URL(filePath: "/tmp/a.m4a"), jobID: "1").jsonLine()
    }

    /// The project's core correctness claim: the decoding keys are **not sent**, and the
    /// worker applies the CLI-equivalence defaults. If a key leaked through, the output
    /// could diverge from the command line's.
    ///
    /// `threads` is deliberately absent from this list. It is a resource limit rather than a
    /// decoding parameter — it changes how long a run takes, never what it produces, which
    /// was measured before it was sent (ADR-018).
    @Test("The decoding options are not written into the job definition")
    func decodingOptionsAreOmitted() throws {
        let json = try payload(WhisperSettings())

        for key in [
            "beam_size", "best_of", "temperature", "initial_prompt",
            "word_timestamps", "no_speech_threshold", "logprob_threshold",
            "compression_ratio_threshold", "condition_on_previous_text",
        ] {
            #expect(!json.contains(key), "\(key) must not be sent")
        }
    }

    @Test("The writer options are sent empty")
    func writerOptionsAreEmpty() throws {
        #expect(try payload(WhisperSettings()).contains("\"writer_options\":{}"))
    }

    @Test("On the CPU fp16 is sent disabled")
    func cpuDisablesFP16() throws {
        var settings = WhisperSettings()
        settings.device = .cpu
        let job = settings.jobPayload(for: URL(filePath: "/tmp/a.m4a"), jobID: "1")
        #expect(job.options.fp16 == false)
    }

    /// On MPS the key isn't sent at all: let whisper decide.
    @Test("On MPS there is no fp16 key at all")
    func mpsOmitsFP16() throws {
        var settings = WhisperSettings()
        settings.device = .mps
        #expect(settings.jobPayload(for: URL(filePath: "/tmp/a.m4a"), jobID: "1").options.fp16 == nil)
        #expect(try !payload(settings).contains("fp16"))
    }
}

@Suite("The notes format")
struct NotesFormatTests {

    /// The format is named "notes" but the file is written as `.md`.
    @Test("The notes format extension is md")
    func extensionIsMarkdown() {
        #expect(OutputFormat.notes.fileExtension == "md")
        #expect(OutputFormat.notes.rawValue == "notes")
        for format in OutputFormat.allCases where format != .notes {
            #expect(format.fileExtension == format.rawValue)
        }
    }

    @Test("The expected output path takes the md extension")
    func expectedOutputUsesMarkdown() {
        var settings = WhisperSettings()
        settings.outputFormats = [.txt, .notes]
        let outputs = settings.expectedOutputs(for: URL(filePath: "/tmp/meeting.m4a"))

        #expect(outputs.map(\.lastPathComponent) == ["meeting.txt", "meeting.md"])
    }

    @Test("The job definition carries the format as 'notes'")
    func jobCarriesFormatName() throws {
        var settings = WhisperSettings()
        settings.outputFormats = [.notes]
        let job = settings.jobPayload(for: URL(filePath: "/tmp/a.m4a"), jobID: "1")

        #expect(job.outputFormats == [.notes])
        #expect(try job.jsonLine().contains("\"output_formats\":[\"notes\"]"))
    }
}

@Suite("App preferences")
struct AppPreferencesTests {

    @Test("The defaults are on the safe side")
    func safeDefaults() {
        let preferences = AppPreferences()
        #expect(preferences.autoStartOnAdd == false, "no job starts without the user agreeing")
        #expect(preferences.confirmOnQuit == true)
        #expect(preferences.keepSystemAwake == true)
        #expect(preferences.notifyOnFinish == true)
        #expect(preferences.revealOnFinish == false)
    }

    @Test("A missing key does not drop the other preferences")
    func decodesPartialBlob() throws {
        let data = try #require(#"{"autoStartOnAdd":true}"#.data(using: .utf8))
        let preferences = try JSONDecoder().decode(AppPreferences.self, from: data)
        #expect(preferences.autoStartOnAdd == true)
        #expect(preferences.confirmOnQuit == true)
    }

    @Test("A full coding round trip")
    func roundTrip() throws {
        var preferences = AppPreferences()
        preferences.autoStartOnAdd = true
        preferences.keepSystemAwake = false
        let data = try JSONEncoder().encode(preferences)
        #expect(try JSONDecoder().decode(AppPreferences.self, from: data) == preferences)
    }
}

@Suite("Model sizes")
struct ModelSizeTests {

    private func capabilities(_ json: String) throws -> EngineCapabilities {
        let data = try #require(json.data(using: .utf8))
        return try JSONDecoder().decode(EngineCapabilities.self, from: data)
    }

    @Test("A downloaded model size is read")
    func readsCachedSizes() throws {
        let capabilities = try capabilities(
            """
            {"models":["small","medium"],"models_cached":["small"],
             "models_bytes":{"small":483617219},
             "languages":[{"code":"tr","name":"turkish"}],
             "output_formats":["txt"],"tasks":["transcribe"],"devices":["cpu"]}
            """
        )
        #expect(capabilities.sizeLabel(for: "small") != nil)
        #expect(capabilities.sizeLabel(for: "medium") == nil, "the size of a model that is not downloaded is unknown")
        #expect(capabilities.cachedBytes == 483_617_219)
    }

    /// The field is backward compatible: an older worker doesn't send it.
    @Test("Decoding does not break without models_bytes")
    func toleratesMissingField() throws {
        let capabilities = try capabilities(
            """
            {"models":["small"],"models_cached":["small"],
             "languages":[{"code":"tr","name":"turkish"}],
             "output_formats":["txt"],"tasks":["transcribe"],"devices":["cpu"]}
            """
        )
        #expect(capabilities.isCached("small"))
        #expect(capabilities.sizeLabel(for: "small") == nil)
        #expect(capabilities.cachedBytes == 0)
    }
}

@Suite("User presets")
struct PresetStoreTests {

    private func temporaryFile() -> URL {
        URL(filePath: NSTemporaryDirectory()).appending(path: "presets-\(UUID().uuidString).json")
    }

    @Test("A saved preset is read back")
    func roundTrip() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }

        var settings = WhisperSettings()
        settings.model = "large-v3"
        settings.outputFormats = [.srt, .vtt]
        let preset = StoredPreset(name: "Interview", settings: settings)

        #expect(PresetStore.save([preset], to: url))
        #expect(PresetStore.load(from: url) == [preset])
    }

    @Test("A missing file gives an empty list")
    func missingFileIsEmpty() {
        #expect(PresetStore.load(from: temporaryFile()).isEmpty)
    }

    /// A corrupt, hand-edited file mustn't take the app down at launch.
    @Test("A corrupt file gives an empty list")
    func corruptFileIsEmpty() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try "{not json".write(to: url, atomically: true, encoding: .utf8)
        #expect(PresetStore.load(from: url).isEmpty)
    }

    @Test("The same name overwrites, and the list stays sorted by name")
    func upsertReplacesAndSorts() {
        var settings = WhisperSettings()
        settings.model = "small"
        let list = PresetStore.upsert(StoredPreset(name: "Zoom", settings: settings), into: [])

        var updated = settings
        updated.model = "large-v3"

        let after = PresetStore.upsert(StoredPreset(name: "Zoom", settings: updated), into: list)
        #expect(after.count == 1)
        #expect(after[0].settings.model == "large-v3")

        let withSecond = PresetStore.upsert(StoredPreset(name: "Archive", settings: settings), into: after)
        #expect(withSecond.map(\.name) == ["Archive", "Zoom"])
    }

    @Test("The summary line shows the model, the language and the formats")
    func detailSummary() {
        var settings = WhisperSettings()
        settings.model = "large-v3-turbo"
        settings.language = "tr"
        settings.outputFormats = [.srt, .vtt]
        let detail = StoredPreset(name: "Subtitles", settings: settings).detail
        #expect(detail.contains("large-v3-turbo"))
        #expect(detail.contains("srt"))
        #expect(detail.contains("vtt"))
    }

    @Test("An automatic language is stated in the summary line")
    func detailMarksAutomaticLanguage() {
        var settings = WhisperSettings()
        settings.language = nil
        #expect(StoredPreset(name: "Mixed", settings: settings).detail.contains("automatic"))
    }
}

@Suite("Live transcription preferences")
struct LivePreferenceTests {

    @Test("Live transcription and the accurate pass are on by default")
    func defaultsAreOn() {
        let preferences = AppPreferences()
        #expect(preferences.liveTranscription)
        #expect(preferences.runSecondPass)
        #expect(preferences.liveModel == "small")
    }

    @Test("The live transcription preferences survive the coding round trip")
    func roundTrip() throws {
        var preferences = AppPreferences()
        preferences.liveTranscription = false
        preferences.liveModel = "large-v3-turbo"
        let data = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: data)

        #expect(!decoded.liveTranscription)
        #expect(decoded.liveModel == "large-v3-turbo")
    }

    @Test("An older preference block takes live transcription as on")
    func legacyBlobDefaultsOn() throws {
        let data = try #require(#"{"autoStartOnAdd":false}"#.data(using: .utf8))
        let preferences = try JSONDecoder().decode(AppPreferences.self, from: data)
        #expect(preferences.liveTranscription)
        #expect(preferences.liveModel == "small")
    }
}

@Suite("Turning live transcription on and off")
@MainActor
struct LiveToggleTests {

    /// With both off, no text would come out of a recording at all.
    @Test("Turning live transcription off makes the accurate pass mandatory")
    func disablingLiveForcesSecondPass() {
        let state = AppState()
        state.preferences.runSecondPass = false
        state.preferences.liveTranscription = false

        #expect(state.preferences.runSecondPass, "both cannot stay off at once")
    }

    @Test("With live transcription on the accurate pass can be turned off")
    func secondPassCanBeDisabledWhenLiveIsOn() {
        let state = AppState()
        state.preferences.liveTranscription = true
        state.preferences.runSecondPass = false

        #expect(!state.preferences.runSecondPass)
    }
}
