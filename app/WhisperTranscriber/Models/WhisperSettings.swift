import Foundation

/// The user's transcription settings.
///
/// `jobPayload(for:)` is this type's only exit: pure, deterministic and independent of the
/// interface — the main target of the unit tests.
///
/// Only the settings that are **visible in the interface** live here. The decoding
/// parameters (beam_size, temperature, the thresholds…) are never written into the job
/// definition; with no key, the worker applies the whisper command line's defaults.
/// Rationale: `docs/DECISIONS.md` → ADR-015.
struct WhisperSettings: Codable, Equatable, Sendable {

    var model: String = "small"
    /// `nil` = detect automatically.
    var language: String? = "tr"
    var task: TranscriptionTask = .transcribe
    var outputFormats: Set<OutputFormat> = [.txt]
    var outputLocation: OutputLocation = .besideSource
    var customOutputDirectory: URL?
    var modelDirectory: URL?
    var device: Device = .cpu
    var overwrite: Bool = false
    /// How much of the machine a run may take — ADR-018. Defaults to leaving a core free:
    /// the cost is about 5% and it is what keeps the Mac usable while transcribing.
    var cpuBudget: CPUBudget = .balanced

    enum OutputLocation: String, Codable, CaseIterable, Identifiable, Sendable {
        case besideSource
        case customFolder

        var id: String { rawValue }

        var title: String {
            switch self {
            case .besideSource: String(localized: "Beside the source file")
            case .customFolder: String(localized: "A specific folder")
            }
        }
    }

    /// whisper's default model cache. The user's existing models are here; the app reads
    /// from this directory and never deletes from it (ADR-005).
    static var defaultModelDirectory: URL {
        URL(filePath: NSHomeDirectory()).appending(path: ".cache/whisper")
    }

    /// Builds the worker job definition for the given audio file.
    ///
    /// A pure function: the same input always gives the same JSON.
    func jobPayload(for url: URL, jobID: String) -> TranscriptionJob {
        TranscriptionJob(
            jobID: jobID,
            inputPath: url.path,
            outputDir: resolvedOutputDirectory(for: url).path,
            outputFormats: OutputFormat.allCases.filter(outputFormats.contains),
            model: model,
            modelDir: (modelDirectory ?? Self.defaultModelDirectory).path,
            language: language,
            task: task,
            device: device,
            options: whisperOptions,
            writerOptions: WriterOptions(),
            overwrite: overwrite,
            emitSegments: true,
            cpuBudget: cpuBudget
        )
    }

    /// The folder the output is written to. If "a specific folder" is selected but no folder
    /// was chosen, we fall back to beside the source — the job doesn't vanish silently.
    func resolvedOutputDirectory(for url: URL) -> URL {
        switch outputLocation {
        case .besideSource:
            url.deletingLastPathComponent()
        case .customFolder:
            customOutputDirectory ?? url.deletingLastPathComponent()
        }
    }

    /// The output paths a file would produce with these settings.
    func expectedOutputs(for url: URL) -> [URL] {
        let directory = resolvedOutputDirectory(for: url)
        let stem = url.deletingPathExtension().lastPathComponent
        return OutputFormat.allCases
            .filter(outputFormats.contains)
            .map { directory.appending(path: "\(stem).\($0.fileExtension)") }
    }

    /// The only decoding option passed to the worker.
    ///
    /// The CPU doesn't support fp16; sending an explicit `false` heads off the "FP16 is not
    /// supported on CPU" warning whisper prints on every job. The other keys are
    /// **deliberately absent**: their absence means "apply the CLI default"
    /// (`docs/WHISPER_OPTIONS.md` → `null` semantics).
    private var whisperOptions: WhisperOptions {
        // `threads` is the one resource limit in the options; 0 means "leave torch alone", so
        // it stays absent from the JSON rather than being sent as a zero.
        let threads = cpuBudget.threads
        return WhisperOptions(fp16: device == .cpu ? false : nil, threads: threads > 0 ? threads : nil)
    }
}

// MARK: - Validation

extension WhisperSettings {

    /// The warnings to show in the interface — `docs/WHISPER_OPTIONS.md` → Validation rules.
    func warnings(capabilities: EngineCapabilities?) -> [Warning] {
        var warnings: [Warning] = []

        if let capabilities, !capabilities.isCached(model) {
            warnings.append(
                .init(
                    symbol: "arrow.down.circle",
                    text: String(localized: "\(model) will be downloaded. The first run may be slow.")
                )
            )
        }

        // Memory, not CPU, is what makes a big model painful on a small Mac: medium peaks at
        // about 4.4 GB, which on an 8 GB machine means swapping while macOS wants its own
        // 3 GB. The threshold is half the installed memory — generous enough that a 16 GB
        // Mac is never nagged about medium, strict enough that an 8 GB one is (ADR-018).
        if let capabilities, let peak = capabilities.estimatedPeakBytes(for: model),
            peak > MachineCapacity.physicalMemory / 2
        {
            let peakLabel = ByteCountFormatter.string(fromByteCount: peak, countStyle: .memory)
            let ramLabel = ByteCountFormatter.string(
                fromByteCount: MachineCapacity.physicalMemory, countStyle: .memory)
            warnings.append(
                .init(
                    symbol: "memorychip",
                    text: String(
                        localized:
                            "\(model) needs around \(peakLabel) of memory and this Mac has \(ramLabel). A smaller model will be far quicker here."
                    )
                )
            )
        }

        if model.hasSuffix(".en"), let language, language != "en" {
            warnings.append(
                .init(
                    symbol: "exclamationmark.triangle",
                    text: String(localized: "\(model) is English-only; it doesn't match the language.")
                )
            )
        }

        if task == .translate {
            warnings.append(
                .init(
                    symbol: "info.circle",
                    text: String(localized: "The translate task produces English output.")
                )
            )
        }

        if outputFormats.isEmpty {
            warnings.append(
                .init(
                    symbol: "exclamationmark.triangle",
                    text: String(localized: "Select at least one output format.")
                )
            )
        }

        return warnings
    }

    struct Warning: Identifiable, Equatable, Sendable {
        var id: String { text }
        var symbol: String
        var text: String
    }

    var isRunnable: Bool { !outputFormats.isEmpty }
}

// MARK: - Presets

extension WhisperSettings {

    struct Preset: Identifiable, Equatable, Sendable {
        var id: String { name }
        var name: String
        var detail: String
        var settings: WhisperSettings
    }

    /// All four use a model already in the user's cache — no waiting for a download.
    static let builtInPresets: [Preset] = [
        Preset(
            name: "Quick note",
            detail: "small · Turkish · txt",
            settings: WhisperSettings()
        ),
        Preset(
            name: "Meeting notes",
            detail: "small · timestamped notes",
            settings: {
                var settings = WhisperSettings()
                settings.outputFormats = [.notes]
                return settings
            }()
        ),
        Preset(
            name: "High quality",
            detail: "large-v3 · txt + srt",
            settings: {
                var settings = WhisperSettings()
                settings.model = "large-v3"
                settings.outputFormats = [.txt, .srt]
                return settings
            }()
        ),
        Preset(
            name: "Subtitles",
            detail: "large-v3-turbo · srt + vtt",
            settings: {
                var settings = WhisperSettings()
                settings.model = "large-v3-turbo"
                settings.outputFormats = [.srt, .vtt]
                return settings
            }()
        ),
    ]
}

// MARK: - Persistence

extension WhisperSettings {

    /// The keys in the stored JSON. Written out explicitly: because the settings block goes
    /// to disk, renaming a field silently drops the user's setting.
    enum CodingKeys: String, CodingKey {
        case model, language, task, outputFormats, outputLocation, customOutputDirectory
        case modelDirectory, device, overwrite, cpuBudget
    }

    /// Decodes, filling missing keys with their defaults.
    ///
    /// Swift's synthesised decoder **throws on a missing key**, which would mean that every
    /// time we add a new settings field, all of the user's settings are silently reset.
    /// Unrecognised keys (such as the advanced settings that have since been removed) are
    /// ignored silently.
    ///
    /// `language`'s default is **not** `nil`, which is why `encode(to:)` writes it as an
    /// explicit `null` when empty: so "no key" (an older block → the default) can be told
    /// apart from "the user chose automatic detection" (ADR-013).
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = WhisperSettings()
        self.init()

        model = container.value(.model, fallback.model)
        language = container.nullable(String.self, .language, fallback.language)
        task = container.value(.task, fallback.task)
        outputFormats = container.value(.outputFormats, fallback.outputFormats)
        outputLocation = container.value(.outputLocation, fallback.outputLocation)
        customOutputDirectory = container.optional(URL.self, .customOutputDirectory)
        modelDirectory = container.optional(URL.self, .modelDirectory)
        device = container.value(.device, fallback.device)
        overwrite = container.value(.overwrite, fallback.overwrite)
        cpuBudget = container.value(.cpuBudget, fallback.cpuBudget)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(language, forKey: .language)
        try container.encode(task, forKey: .task)
        try container.encode(outputFormats, forKey: .outputFormats)
        try container.encode(outputLocation, forKey: .outputLocation)
        try container.encodeIfPresent(customOutputDirectory, forKey: .customOutputDirectory)
        try container.encodeIfPresent(modelDirectory, forKey: .modelDirectory)
        try container.encode(device, forKey: .device)
        try container.encode(overwrite, forKey: .overwrite)
        try container.encode(cpuBudget, forKey: .cpuBudget)
    }
}

extension KeyedDecodingContainer where Key == WhisperSettings.CodingKeys {

    /// Returns the default if the key is absent or won't decode.
    fileprivate func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }

    /// `nil` if the key is absent — for fields whose default is `nil`.
    fileprivate func optional<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }

    /// Optionals whose default isn't `nil`: **no key** means the default, a present key
    /// (including `null`) means the stored value.
    fileprivate func nullable<T: Decodable>(_ type: T.Type, _ key: Key, _ fallback: T?) -> T? {
        guard contains(key) else { return fallback }
        return (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}
