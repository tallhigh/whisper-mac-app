import Foundation
import Testing

@testable import WhisperTranscriber

@Suite("Job definition generation")
struct JobPayloadTests {

    let audio = URL(filePath: "/Users/t/Desktop/recordings/mehmet.m4a")

    private func payloadJSON(_ settings: WhisperSettings) throws -> [String: Any] {
        let job = settings.jobPayload(for: audio, jobID: "job-1")
        let data = Data(try job.jsonLine().utf8)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("The default settings match the user CLI command")
    func defaultsMatchUsersCommand() throws {
        // whisper mehmet.m4a --language Turkish --task transcribe --model small --output_format txt
        let json = try payloadJSON(WhisperSettings())

        #expect(json["v"] as? Int == 1)
        #expect(json["model"] as? String == "small")
        #expect(json["language"] as? String == "tr")
        #expect(json["task"] as? String == "transcribe")
        #expect(json["output_formats"] as? [String] == ["txt"])
        #expect(json["input_path"] as? String == audio.path)
        #expect(json["output_dir"] as? String == "/Users/t/Desktop/recordings")
        #expect(json["overwrite"] as? Bool == false)
        #expect(json["emit_segments"] as? Bool == true)
    }

    @Test("The model directory defaults to the user cache")
    func modelDirectoryDefault() throws {
        // ADR-005: the user's existing 4.8 GB of models are here.
        let json = try payloadJSON(WhisperSettings())
        #expect((json["model_dir"] as? String)?.hasSuffix("/.cache/whisper") == true)
    }

    @Test("With automatic language detection the language field is null")
    func automaticLanguage() throws {
        var settings = WhisperSettings()
        settings.language = nil
        let json = try payloadJSON(settings)

        // A nil language means "detect automatically"; don't confuse it with an absent key.
        #expect(json["language"] == nil || json["language"] is NSNull)
    }

    @Test("The output formats are always in a fixed order")
    func formatsAreStablyOrdered() throws {
        var settings = WhisperSettings()
        settings.outputFormats = [.vtt, .txt, .srt]
        let json = try payloadJSON(settings)

        // A Set is unordered; a deterministic array has to reach the protocol.
        #expect(json["output_formats"] as? [String] == ["txt", "srt", "vtt"])
    }

    @Test("The 'all' format is not sent, an explicit list is")
    func noAllFormat() throws {
        var settings = WhisperSettings()
        settings.outputFormats = Set(OutputFormat.allCases)
        let formats = try #require(try payloadJSON(settings)["output_formats"] as? [String])

        #expect(!formats.contains("all"))
        #expect(Set(formats) == ["txt", "srt", "vtt", "json", "tsv", "notes"])
    }

    /// A Phase 1 finding: the CLI does beam search with `beam_size`/`best_of` = 5 while the
    /// library does greedy decoding. The **worker** applies those now; the job definition
    /// carries no decoding key at all (ADR-015).
    @Test("The decoding keys are not sent, the worker applies the default")
    func decodingOptionsOmitted() throws {
        let options = try #require(try payloadJSON(WhisperSettings())["options"] as? [String: Any])

        for key in ["beam_size", "best_of", "temperature", "initial_prompt", "threads"] {
            #expect(options[key] == nil, "\(key)")
        }
    }

    @Test("On the CPU fp16 is explicitly disabled")
    func fp16DisabledOnCPU() throws {
        // On CPU, whisper warns and drops to fp32 when it sees fp16; we cut the noise.
        let options = try #require(try payloadJSON(WhisperSettings())["options"] as? [String: Any])
        #expect(options["fp16"] as? Bool == false)
    }

    @Test("The writer options are sent empty")
    func writerOptionsEmpty() throws {
        let writer = try #require(try payloadJSON(WhisperSettings())["writer_options"] as? [String: Any])
        #expect(writer.isEmpty)
    }

    @Test("The same input produces the same JSON")
    func deterministic() throws {
        let settings = WhisperSettings()
        let first = settings.jobPayload(for: audio, jobID: "x")
        let second = settings.jobPayload(for: audio, jobID: "x")

        #expect(first == second)
        #expect(try first.jsonLine() == (try second.jsonLine()))
    }

    @Test("A path with Turkish characters and an emoji is not mangled")
    func unicodePath() throws {
        let url = URL(filePath: "/Users/t/Masaüstü/SAMPLE recording 🎙 şçğü.m4a")
        let job = WhisperSettings().jobPayload(for: url, jobID: "u")
        let decoded = try JSONDecoder().decode(
            TranscriptionJob.self,
            from: Data(try job.jsonLine().utf8)
        )

        #expect(decoded.inputPath == url.path)
    }
}

@Suite("The output folder")
struct OutputDirectoryTests {

    let audio = URL(filePath: "/Users/t/Desktop/recordings/mehmet.m4a")

    @Test("Beside the source")
    func besideSource() {
        let settings = WhisperSettings()
        #expect(settings.resolvedOutputDirectory(for: audio).path == "/Users/t/Desktop/recordings")
    }

    @Test("Into the chosen folder")
    func customFolder() {
        var settings = WhisperSettings()
        settings.outputLocation = .customFolder
        settings.customOutputDirectory = URL(filePath: "/Users/t/Output")

        #expect(settings.resolvedOutputDirectory(for: audio).path == "/Users/t/Output")
    }

    @Test("With no folder chosen it falls back to beside the source")
    func customFolderWithoutSelection() {
        var settings = WhisperSettings()
        settings.outputLocation = .customFolder
        settings.customOutputDirectory = nil

        // The job mustn't vanish silently.
        #expect(settings.resolvedOutputDirectory(for: audio).path == "/Users/t/Desktop/recordings")
    }

    @Test("The expected output paths swap the extension")
    func expectedOutputs() {
        var settings = WhisperSettings()
        settings.outputFormats = [.txt, .srt]

        let paths = settings.expectedOutputs(for: audio).map(\.path)
        #expect(paths == ["/Users/t/Desktop/recordings/mehmet.txt", "/Users/t/Desktop/recordings/mehmet.srt"])
    }
}

@Suite("Settings warnings")
struct SettingsWarningTests {

    private func capabilities(cached: [String] = ["small"]) -> EngineCapabilities {
        EngineCapabilities(
            models: ["tiny", "small", "small.en", "large-v3"],
            modelsCached: cached,
            modelDir: nil,
            languages: [.init(code: "tr", name: "turkish"), .init(code: "en", name: "english")],
            outputFormats: ["txt"],
            tasks: ["transcribe", "translate"],
            devices: ["cpu"]
        )
    }

    @Test("A model that is not downloaded warns")
    func uncachedModelWarns() {
        var settings = WhisperSettings()
        settings.model = "large-v3"

        let warnings = settings.warnings(capabilities: capabilities())
        #expect(warnings.contains { $0.text.contains("will be downloaded") })
    }

    @Test("A model in the cache does not warn")
    func cachedModelIsQuiet() {
        let warnings = WhisperSettings().warnings(capabilities: capabilities())
        #expect(!warnings.contains { $0.text.contains("will be downloaded") })
    }

    @Test("An .en model warns that it does not match Turkish")
    func englishOnlyModelWarns() {
        var settings = WhisperSettings()
        settings.model = "small.en"

        let warnings = settings.warnings(capabilities: capabilities(cached: ["small.en"]))
        #expect(warnings.contains { $0.text.contains("English-only") })
    }

    @Test("The translate task says the output will be in English")
    func translateWarns() {
        var settings = WhisperSettings()
        settings.task = .translate

        // A frequent misunderstanding: translate does not mean translating into Turkish.
        let warnings = settings.warnings(capabilities: capabilities())
        #expect(warnings.contains { $0.text.contains("English output") })
    }

    @Test("With no format chosen it cannot be run")
    func noFormatBlocksRun() {
        var settings = WhisperSettings()
        settings.outputFormats = []

        #expect(!settings.isRunnable)
        #expect(settings.warnings(capabilities: nil).contains { $0.text.contains("at least one") })
    }
}

@Suite("The built-in presets")
struct PresetTests {

    @Test("There are four built-in presets")
    func count() {
        #expect(WhisperSettings.builtInPresets.count == 4)
    }

    @Test("The quick note preset matches the user existing command")
    func quickNoteMatchesCurrentCommand() {
        let settings = WhisperSettings.builtInPresets[0].settings

        #expect(settings.model == "small")
        #expect(settings.language == "tr")
        #expect(settings.outputFormats == [.txt])
    }

    @Test("The preset models are the ones in the user cache")
    func presetsUseCachedModels() {
        // They were chosen so there's no download to wait for on first use.
        let cached: Set<String> = ["small", "large-v3", "large-v3-turbo"]
        for preset in WhisperSettings.builtInPresets {
            #expect(cached.contains(preset.settings.model), "\(preset.name)")
        }
    }

    @Test("The meeting notes preset produces only the notes format")
    func meetingNotePreset() {
        let notes = WhisperSettings.builtInPresets[1].settings

        #expect(notes.model == "small")
        #expect(notes.outputFormats == [.notes])
    }

    @Test("The subtitles preset produces the subtitle formats")
    func subtitlePreset() {
        let subtitle = WhisperSettings.builtInPresets[3].settings

        #expect(subtitle.model == "large-v3-turbo")
        #expect(subtitle.outputFormats == [.srt, .vtt])
    }
}
