import Foundation

/// Runs the openai-whisper engine in a separate Python process.
///
/// The process lifecycle, decoding the NDJSON stream and cancellation all gather here.
/// The protocol: `docs/PROTOCOL.md`.
actor PythonWhisperEngine: TranscriptionEngine, LiveTranscriptionEngine {

    nonisolated let id = EngineID.pythonWhisper

    private let layout: RuntimeLayout
    private let bundle: Bundle

    /// How long we wait for a clean exit after SIGTERM.
    ///
    /// Cancellation is only noticed at 30-second window boundaries; the latency measured
    /// with the `small` model is 7 seconds. SIGKILL is safe — writing the output is atomic
    /// and happens at the very end of the job, so an early death leaves no file behind.
    private static let terminationGrace: Duration = .seconds(10)

    init(layout: RuntimeLayout = RuntimeLayout(), bundle: Bundle = .main) {
        self.layout = layout
        self.bundle = bundle
    }

    // MARK: - Capabilities

    func capabilities() async throws -> EngineCapabilities {
        let found = LockedBox<EngineCapabilities>()
        try await run(mode: "capabilities", standardInput: nil) { event in
            if case .capabilities(let capabilities) = event {
                found.set(capabilities)
            }
        }
        guard let value = found.value else { throw EngineError.noResult }
        return value
    }

    // MARK: - Downloading a model

    /// The stdin payload for `download` mode. Deliberately tiny: a download needs a name and
    /// a folder, and nothing else from the job definition applies.
    private struct DownloadRequest: Encodable {
        var v = ProtocolVersion.current
        var model: String
        var modelDir: String

        enum CodingKeys: String, CodingKey {
            case v, model
            case modelDir = "model_dir"
        }
    }

    /// Fetches one model, reporting progress, without transcribing anything.
    ///
    /// Not part of `TranscriptionEngine`. A `.pt` file in a model folder is this engine's own
    /// concept — whisper.cpp would want a ggml file from somewhere else entirely — so this
    /// follows the precedent `LiveTranscriptionEngine` set and stays off the shared contract
    /// (ADR-019).
    ///
    /// - Parameter onProgress: the fraction downloaded, or `nil` when the size is unknown.
    func downloadModel(
        _ model: String,
        modelDir: String,
        onProgress: @Sendable @escaping (Double?) -> Void
    ) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(DownloadRequest(model: model, modelDir: modelDir))
        let payload = String(decoding: data, as: UTF8.self)

        let failure = LockedBox<EngineEvent.EngineFailure>()
        // A download is not urgent; utility priority keeps it out of the interface's way.
        try await run(mode: "download", standardInput: payload, budget: .balanced) { event in
            switch event {
            case .failure(let value): failure.set(value)
            case .progress(let progress): onProgress(progress.fraction)
            default: break
            }
        }
        if let failure = failure.value { throw failure }
    }

    // MARK: - Transcription

    @discardableResult
    func transcribe(
        _ job: TranscriptionJob,
        onEvent: @Sendable @escaping (EngineEvent) -> Void
    ) async throws -> EngineEvent.TranscriptionResult {
        let payload = try job.jsonLine()

        let result = LockedBox<EngineEvent.TranscriptionResult>()
        let failure = LockedBox<EngineEvent.EngineFailure>()

        try await run(mode: "transcribe", standardInput: payload, budget: job.cpuBudget) { event in
            switch event {
            case .result(let value): result.set(value)
            case .failure(let value): failure.set(value)
            default: break
            }
            onEvent(event)
        }

        if let failure = failure.value { throw failure }
        guard let value = result.value else { throw EngineError.noResult }
        return value
    }

    // MARK: - Live session

    /// Starts a long-lived `stream` process and leaves stdin **open**.
    ///
    /// `run(mode:standardInput:)` closes stdin immediately; because audio keeps flowing in
    /// live mode, a separate path is needed.
    func startLiveSession(
        _ config: LiveConfig,
        onEvent: @Sendable @escaping (EngineEvent) -> Void
    ) async throws -> LiveSession {
        guard
            let worker = bundle.url(
                forResource: "whisper_worker", withExtension: "py", subdirectory: "python")
        else {
            throw EngineError.workerMissing
        }
        guard FileManager.default.isExecutableFile(atPath: layout.venvPython.path) else {
            throw EngineError.runtimeNotReady
        }

        let process = Process()
        process.executableURL = layout.venvPython
        process.arguments = [worker.path, "stream"]
        process.environment = ProcessRunner.baseEnvironment()

        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe

        try process.run()

        let input = inPipe.fileHandleForWriting
        try input.write(contentsOf: Data((try config.jsonLine() + "\n").utf8))

        Task.detached {
            await Self.readLines(from: outPipe.fileHandleForReading) { line in
                onEvent(EngineEvent.decode(line: line))
            }
        }
        // stderr has to be read in live mode too: once an unread pipe fills, the worker
        // deadlocks trying to write to it.
        Task.detached {
            await Self.readLines(from: errPipe.fileHandleForReading) { line in
                onEvent(.log(level: .debug, message: line))
            }
        }

        return LiveSession(process: process, input: input)
    }

    // MARK: - Process

    private func run(
        mode: String,
        standardInput: String?,
        budget: CPUBudget = .full,
        onEvent: @Sendable @escaping (EngineEvent) -> Void
    ) async throws {
        guard
            let worker = bundle.url(
                forResource: "whisper_worker", withExtension: "py", subdirectory: "python")
        else {
            throw EngineError.workerMissing
        }
        guard FileManager.default.isExecutableFile(atPath: layout.venvPython.path) else {
            throw EngineError.runtimeNotReady
        }

        let process = Process()
        process.executableURL = layout.venvPython
        process.arguments = [worker.path, mode]
        // The thread limit is also set in the environment, not only through
        // `torch.set_num_threads()`: the OpenMP and BLAS pools size themselves when torch is
        // imported, which happens before the worker reads the job (ADR-018).
        process.environment = ProcessRunner.baseEnvironment(extra: budget.threadEnvironment)
        // What actually keeps the interface smooth. `.utility` and `.background` tell the
        // scheduler the work can wait, and on Apple Silicon steer it to the efficiency cores.
        process.qualityOfService = budget.qualityOfService

        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe

        let diagnostics = DiagnosticsBuffer()

        try process.run()

        // The worker waits for stdin to close; without closing it the process hangs.
        if let standardInput {
            try? inPipe.fileHandleForWriting.write(contentsOf: Data(standardInput.utf8))
        }
        try? inPipe.fileHandleForWriting.close()

        let reader = Task.detached {
            await Self.readLines(from: outPipe.fileHandleForReading) { line in
                onEvent(EngineEvent.decode(line: line))
            }
        }
        let errorReader = Task.detached {
            await Self.readLines(from: errPipe.fileHandleForReading) { line in
                diagnostics.append(line)
            }
        }

        do {
            try await withTaskCancellationHandler {
                _ = await reader.value
                _ = await errorReader.value
                await ProcessRunner.waitForExit(process)
                try Task.checkCancellation()
            } onCancel: {
                Self.terminate(process)
            }
        } catch {
            Self.terminate(process)
            throw error
        }

        let exitCode = process.terminationStatus
        // 1 = a handled error; an `error` event has already arrived before this.
        guard exitCode == 0 || exitCode == 1 else {
            throw EngineError.workerCrashed(exitCode: exitCode, tail: diagnostics.tail())
        }
    }

    /// Gently first, then by force. SIGKILL follows once the grace period is up.
    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()

        Task.detached {
            try? await Task.sleep(for: terminationGrace)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    /// Reads line by line until the pipe closes.
    ///
    /// Because NDJSON lines can be long, we read in chunks and join the lines ourselves.
    private static func readLines(
        from handle: FileHandle,
        onLine: @Sendable @escaping (String) -> Void
    ) async {
        await withCheckedContinuation { continuation in
            let pending = LineAccumulator()
            handle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    if let tail = pending.flush() { onLine(tail) }
                    continuation.resume()
                    return
                }
                for line in pending.append(data) {
                    onLine(line)
                }
            }
        }
    }
}

/// A single value written from event callbacks that run concurrently.
private final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value?

    func set(_ value: Value) {
        lock.withLock { storage = value }
    }

    var value: Value? {
        lock.withLock { storage }
    }
}

/// Produces complete lines out of incoming bytes.
private final class LineAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    func append(_ data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return lock.withLock {
            buffer += text
            var lines: [String] = []
            while let newline = buffer.firstIndex(of: "\n") {
                let line = String(buffer[buffer.startIndex..<newline])
                buffer = String(buffer[buffer.index(after: newline)...])
                if !line.isEmpty { lines.append(line) }
            }
            return lines
        }
    }

    func flush() -> String? {
        lock.withLock {
            let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = ""
            return tail.isEmpty ? nil : tail
        }
    }
}

/// The last lines from the worker's stderr — for diagnosing a crash.
private final class DiagnosticsBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private let limit = 50

    func append(_ line: String) {
        lock.withLock {
            lines.append(line)
            if lines.count > limit { lines.removeFirst(lines.count - limit) }
        }
    }

    func tail() -> String {
        lock.withLock { lines.joined(separator: "\n") }
    }
}
