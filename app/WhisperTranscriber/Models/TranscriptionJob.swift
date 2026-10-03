import Foundation

/// The job definition sent to the worker over stdin — `docs/PROTOCOL.md`.
///
/// `nil` fields are **never written** to the JSON: in the protocol, "no key" and `null`
/// mean different things. With no key the worker applies its own default (CLI equivalence
/// included); with `null`, whisper's library default is used. Because Swift's synthesised
/// encoder uses `encodeIfPresent`, this behaviour comes for free — keeping the fields
/// `Optional` is enough.
struct TranscriptionJob: Codable, Equatable, Sendable {
    var v: Int = ProtocolVersion.current
    var jobID: String
    var inputPath: String
    var outputDir: String
    var outputFormats: [OutputFormat]
    var model: String
    var modelDir: String
    var language: String?
    var task: TranscriptionTask
    var device: Device
    var options: WhisperOptions
    var writerOptions: WriterOptions
    var overwrite: Bool
    var emitSegments: Bool

    enum CodingKeys: String, CodingKey {
        case v
        case jobID = "job_id"
        case inputPath = "input_path"
        case outputDir = "output_dir"
        case outputFormats = "output_formats"
        case model
        case modelDir = "model_dir"
        case language
        case task
        case device
        case options
        case writerOptions = "writer_options"
        case overwrite
        case emitSegments = "emit_segments"
    }

    func jsonLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}

enum ProtocolVersion {
    /// The batch job definition and its events.
    static let current = 1
    /// Live mode — `docs/PROTOCOL.md` → Live mode. The whole channel carries this version;
    /// the version is a property of the channel, not of the event.
    static let stream = 2
}

enum TranscriptionTask: String, Codable, CaseIterable, Identifiable, Sendable {
    case transcribe
    case translate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transcribe: String(localized: "Transcribe")
        case .translate: String(localized: "Translate to English")
        }
    }
}

enum Device: String, Codable, CaseIterable, Identifiable, Sendable {
    case cpu
    case mps

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .mps: String(localized: "MPS (experimental)")
        }
    }
}

enum OutputFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case txt, srt, vtt, json, tsv
    /// A timestamped note list. The one format with no counterpart in whisper; the worker
    /// uses its own writer (ADR-014).
    case notes

    var id: String { rawValue }

    /// The format name and the file extension diverge for `notes` only.
    var fileExtension: String { self == .notes ? "md" : rawValue }

    /// The short label above the checkbox.
    var label: String {
        self == .notes ? String(localized: "notes") : rawValue
    }

    var title: String {
        switch self {
        case .txt: String(localized: "Plain text")
        case .srt: String(localized: "SubRip subtitles")
        case .vtt: String(localized: "WebVTT subtitles")
        case .json: "JSON"
        case .tsv: "TSV"
        case .notes: String(localized: "Timestamped note list (.md)")
        }
    }
}

/// The options passed to `whisper.transcribe()`.
///
/// The protocol (`docs/PROTOCOL.md`) can carry more and the worker accepts all of it; since
/// nothing in the interface corresponds to them any more, v1 sends only `fp16`. Every key
/// not sent means "apply the worker's CLI-equivalence default" (ADR-015).
struct WhisperOptions: Codable, Equatable, Sendable {
    var fp16: Bool?
}

/// The options passed to whisper's output writers.
///
/// Because the subtitle-wrapping settings were removed from the interface, this is currently
/// sent empty; its place in the protocol is kept.
struct WriterOptions: Codable, Equatable, Sendable {}
