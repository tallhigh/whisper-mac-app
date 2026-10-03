import Foundation

/// The engine contract the interface talks to.
///
/// In v1 the only implementation is `PythonWhisperEngine`. In v2 the Metal-accelerated
/// `WhisperCppEngine` will plug into the same protocol (ADR-003) — which is why no
/// assumption specific to openai-whisper is leaked into the interface layer.
protocol TranscriptionEngine: Sendable {
    var id: EngineID { get }

    /// The supported models, languages and formats. Read at runtime.
    func capabilities() async throws -> EngineCapabilities

    /// Transcribes a single file. `onEvent` is called as events arrive.
    ///
    /// Cancelling the calling `Task` stops the engine.
    @discardableResult
    func transcribe(
        _ job: TranscriptionJob,
        onEvent: @Sendable @escaping (EngineEvent) -> Void
    ) async throws -> EngineEvent.TranscriptionResult
}

enum EngineID: String, Sendable {
    case pythonWhisper
    case whisperCpp

    var title: String {
        switch self {
        case .pythonWhisper: "OpenAI Whisper (Python)"
        case .whisperCpp: "whisper.cpp (Metal)"
        }
    }
}

/// The engine layer's own errors, as distinct from the ones the worker produces.
enum EngineError: LocalizedError {
    case runtimeNotReady
    case workerMissing
    case workerCrashed(exitCode: Int32, tail: String)
    case noResult

    var errorDescription: String? {
        switch self {
        case .runtimeNotReady:
            String(localized: "The runtime is not ready.")
        case .workerMissing:
            String(localized: "whisper_worker.py is missing from the app bundle.")
        case .workerCrashed(let exitCode, _):
            String(localized: "The transcription ended unexpectedly (exit code \(exitCode)).")
        case .noResult:
            String(localized: "The transcription finished but no result arrived.")
        }
    }

    var detail: String {
        switch self {
        case .workerCrashed(_, let tail): tail
        default: ""
        }
    }
}
