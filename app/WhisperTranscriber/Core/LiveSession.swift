import Foundation

/// The live transcription capability.
///
/// It isn't added to `TranscriptionEngine` but kept separate: per ADR-003 the
/// `WhisperCppEngine` arriving in v2 will plug into the same batch protocol but isn't
/// obliged to support live mode.
protocol LiveTranscriptionEngine: TranscriptionEngine {
    func startLiveSession(
        _ config: LiveConfig,
        onEvent: @Sendable @escaping (EngineEvent) -> Void
    ) async throws -> LiveSession
}

/// A live session's configuration — it goes to the worker as the first line.
struct LiveConfig: Codable, Equatable, Sendable {
    var v: Int = ProtocolVersion.stream
    var jobID: String
    var model: String
    var modelDir: String
    var language: String?
    var task: TranscriptionTask
    var device: Device

    enum CodingKeys: String, CodingKey {
        case v
        case jobID = "job_id"
        case model
        case modelDir = "model_dir"
        case language, task, device
    }

    func jsonLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

/// A living worker process: audio goes in, text comes back.
///
/// Audio writing happens on a queue of its own: `FileHandle.write` blocks when the pipe
/// fills, and this call arrives from the audio thread — waiting there would mean a gap in
/// the recording.
final class LiveSession: @unchecked Sendable {

    private let process: Process
    private let input: FileHandle
    private let writeQueue = DispatchQueue(label: "com.talhaturhan.WhisperTranscriber.live-stdin")
    private let lock = NSLock()
    private var closed = false

    init(process: Process, input: FileHandle) {
        self.process = process
        self.input = input
    }

    var isRunning: Bool { process.isRunning }

    /// Sends 16 kHz mono int16 samples to the worker.
    ///
    /// The byte order is the host's (little-endian on Apple Silicon); the worker reads the
    /// same order with `np.frombuffer(..., np.int16)`.
    func send(samples: [Int16]) {
        guard !samples.isEmpty else { return }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let line =
            "{\"v\":\(ProtocolVersion.stream),\"type\":\"audio\",\"pcm\":\"\(data.base64EncodedString())\"}\n"
        enqueue(line)
    }

    /// Tells the worker no more audio is coming. Returns at once.
    ///
    /// Split from waiting for the exit on purpose: the worker answers `stop` by transcribing
    /// whatever audio has not been committed yet, which can take seconds, and nothing in the
    /// interface should sit still for that (ADR-022).
    func requestStop() {
        enqueue("{\"v\":\(ProtocolVersion.stream),\"type\":\"stop\"}\n")
        writeQueue.sync {}
        closeInput()
    }

    /// Waits for the worker to write its final text and exit. Call after `requestStop()`.
    func awaitExit() async {
        await ProcessRunner.waitForExit(process)
    }

    /// Ends the stream and waits — `requestStop()` followed by `awaitExit()`.
    func finish() async {
        requestStop()
        await awaitExit()
    }

    /// Terminates the session at once; the final text is not waited for.
    func cancel() {
        closeInput()
        guard process.isRunning else { return }
        process.terminate()
    }

    private func enqueue(_ line: String) {
        let shouldWrite = lock.withLock { !closed }
        guard shouldWrite else { return }
        writeQueue.async { [weak self] in
            guard let self, self.lock.withLock({ !self.closed }) else { return }
            try? self.input.write(contentsOf: Data(line.utf8))
        }
    }

    private func closeInput() {
        let alreadyClosed = lock.withLock {
            let value = closed
            closed = true
            return value
        }
        guard !alreadyClosed else { return }
        writeQueue.sync {}
        try? input.close()
    }
}
