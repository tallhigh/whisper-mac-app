import Foundation

/// The NDJSON events coming from the worker — `docs/PROTOCOL.md`.
///
/// Decoding is **forward compatible**: an unrecognised event type or a malformed line is
/// not an error, it is surfaced as `.unknown` and shows up to the user as a log line. That
/// way a new protocol version doesn't break an older app.
enum EngineEvent: Equatable, Sendable {
    case hello(Hello)
    case capabilities(EngineCapabilities)
    case status(Status)
    case progress(Progress)
    case segment(Segment)
    case log(level: LogLevel, message: String)
    case result(TranscriptionResult)
    case failure(EngineFailure)
    /// Live mode (v2): text that will never change again.
    case committed(Committed)
    /// Live mode (v2): **everything** uncommitted, which can change on every tick.
    case partial(text: String)
    case unknown(raw: String)

    struct Hello: Decodable, Equatable, Sendable {
        var worker: String
        var python: String?
        var whisper: String?
        var torch: String?
        var ffmpeg: String?
        var device: String?
        var mpsAvailable: Bool?

        enum CodingKeys: String, CodingKey {
            case worker, python, whisper, torch, ffmpeg, device
            case mpsAvailable = "mps_available"
        }
    }

    struct Status: Decodable, Equatable, Sendable {
        var phase: Phase
        var model: String?
        var duration: Double?

        enum Phase: String, Decodable, Sendable {
            case resolvingModel = "resolving_model"
            case downloadingModel = "downloading_model"
            case loadingModel = "loading_model"
            case decodingAudio = "decoding_audio"
            case audioReady = "audio_ready"
            case detectingLanguage = "detecting_language"
            case transcribing
            case writingOutput = "writing_output"

            /// The subtitle of the queue row.
            var title: String {
                switch self {
                case .resolvingModel: String(localized: "preparing the model")
                case .downloadingModel: String(localized: "downloading the model")
                case .loadingModel: String(localized: "loading the model")
                case .decodingAudio: String(localized: "decoding the audio")
                case .audioReady: String(localized: "audio ready")
                case .detectingLanguage: String(localized: "detecting the language")
                case .transcribing: String(localized: "transcribing")
                case .writingOutput: String(localized: "writing the file")
                }
            }
        }
    }

    /// A committed piece in live mode. Timestamps are absolute from the start of the recording.
    struct Committed: Decodable, Equatable, Sendable {
        var text: String
        var start: Double
        var end: Double
    }

    struct Progress: Decodable, Equatable, Sendable {
        var phase: String?
        var processed: Double?
        var total: Double?
        var pct: Double?

        /// A ratio in 0...1. Because whisper only updates at 30 s window boundaries, we
        /// don't invent intermediate values.
        var fraction: Double? {
            guard let pct else { return nil }
            return min(max(pct / 100, 0), 1)
        }
    }

    struct Segment: Decodable, Equatable, Sendable, Identifiable {
        var id: Int
        var start: Double
        var end: Double
        var text: String
    }

    struct TranscriptionResult: Decodable, Equatable, Sendable {
        var jobID: String?
        var language: String?
        var duration: Double?
        var elapsed: Double?
        var rtf: Double?
        var outputs: [Output]
        var segmentCount: Int?
        var textChars: Int?

        struct Output: Decodable, Equatable, Sendable {
            var format: String
            var path: String
            var bytes: Int?

            var url: URL { URL(filePath: path) }
        }

        enum CodingKeys: String, CodingKey {
            case jobID = "job_id"
            case language, duration, elapsed, rtf, outputs
            case segmentCount = "segment_count"
            case textChars = "text_chars"
        }

        /// A display like "2.1x". Since `rtf` is elapsed / audio duration, the user
        /// is shown its inverse.
        var speedMultiplier: Double? {
            guard let rtf, rtf > 0 else { return nil }
            return 1 / rtf
        }
    }

    struct EngineFailure: Decodable, Equatable, Sendable, Error {
        var code: Code
        var message: String
        var detail: String?
        var recoverable: Bool?

        /// `docs/ARCHITECTURE.md` → "Error classification". An unrecognised code becomes
        /// `.unknown`; the app can still show the message.
        enum Code: String, Decodable, Sendable {
            case badUsage = "BAD_USAGE"
            case badJob = "BAD_JOB"
            case runtimeNotReady = "RUNTIME_NOT_READY"
            case modelDownloadFailed = "MODEL_DOWNLOAD_FAILED"
            case modelLoadFailed = "MODEL_LOAD_FAILED"
            case audioDecodeFailed = "AUDIO_DECODE_FAILED"
            case outputExists = "OUTPUT_EXISTS"
            case outOfMemory = "OUT_OF_MEMORY"
            case cancelled = "CANCELLED"
            case internalError = "INTERNAL_ERROR"
            case workerCrashed = "WORKER_CRASHED"
            case unknown

            init(from decoder: any Decoder) throws {
                let raw = try decoder.singleValueContainer().decode(String.self)
                self = Code(rawValue: raw) ?? .unknown
            }

            /// The suggestion that tells the user what to do.
            var suggestion: String? {
                switch self {
                case .modelDownloadFailed:
                    String(localized: "Check your internet connection and try again.")
                case .modelLoadFailed:
                    String(localized: "The model file may be corrupt; delete it from the model folder.")
                case .audioDecodeFailed:
                    String(localized: "The file may be corrupt or in an unsupported format.")
                case .outOfMemory:
                    String(localized: "Try choosing a smaller model.")
                case .outputExists:
                    String(localized: "Turn on overwriting, or choose another output folder.")
                case .runtimeNotReady:
                    String(localized: "Reinstall the runtime from Settings.")
                case .badUsage, .badJob, .cancelled, .internalError, .workerCrashed, .unknown:
                    nil
                }
            }
        }
    }

    enum LogLevel: String, Decodable, Sendable {
        case debug, info, warning, error
    }
}

// MARK: - Decoding

extension EngineEvent {

    private struct Envelope: Decodable {
        var type: String
    }

    private struct LogPayload: Decodable {
        var level: LogLevel?
        var message: String
    }

    private struct PartialPayload: Decodable {
        var text: String
    }

    /// Turns a single NDJSON line into an event. It never throws, under any circumstances —
    /// a line that won't decode becomes `.unknown` (forward compatibility).
    static func decode(line: String) -> EngineEvent {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            return .unknown(raw: line)
        }

        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else {
            return .unknown(raw: trimmed)
        }

        do {
            switch envelope.type {
            case "hello":
                return .hello(try decoder.decode(Hello.self, from: data))
            case "capabilities":
                return .capabilities(try decoder.decode(EngineCapabilities.self, from: data))
            case "status":
                return .status(try decoder.decode(Status.self, from: data))
            case "progress":
                return .progress(try decoder.decode(Progress.self, from: data))
            case "segment":
                return .segment(try decoder.decode(Segment.self, from: data))
            case "log":
                let payload = try decoder.decode(LogPayload.self, from: data)
                return .log(level: payload.level ?? .info, message: payload.message)
            case "committed":
                return .committed(try decoder.decode(Committed.self, from: data))
            case "partial":
                return .partial(text: try decoder.decode(PartialPayload.self, from: data).text)
            case "result":
                return .result(try decoder.decode(TranscriptionResult.self, from: data))
            case "error":
                return .failure(try decoder.decode(EngineFailure.self, from: data))
            default:
                return .unknown(raw: trimmed)
            }
        } catch {
            return .unknown(raw: trimmed)
        }
    }

    /// The text to show in the log panel; `nil` for events that aren't shown.
    var logLine: String? {
        switch self {
        case .log(let level, let message):
            level == .info ? message : "[\(level.rawValue)] \(message)"
        case .unknown(let raw):
            "[undecodable] \(raw)"
        case .status(let status):
            status.phase.title
        case .hello(let hello):
            "worker \(hello.worker) · whisper \(hello.whisper ?? "?") · \(hello.device ?? "?")"
        case .failure(let failure):
            "[error] \(failure.code.rawValue): \(failure.message)"
        case .capabilities, .progress, .segment, .result, .committed, .partial:
            nil
        }
    }
}
