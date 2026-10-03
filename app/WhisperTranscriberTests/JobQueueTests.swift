import Foundation
import Testing

@testable import WhisperTranscriber

@Suite("Queue behaviour")
@MainActor
struct JobQueueTests {

    /// ADR-012: MPS is experimental; on failure the job isn't dropped but retried on CPU.
    @Test("When MPS fails the job is retried on the CPU")
    func mpsFallsBackToCPU() async throws {
        let engine = FakeEngine(failingDevices: [.mps])
        let queue = JobQueue(engine: engine)
        let file = try TemporaryAudio.make()
        defer { TemporaryAudio.remove(file) }

        var settings = WhisperSettings()
        settings.device = .mps
        queue.enqueue([file], settings: settings)
        await queue.runToCompletion()

        #expect(engine.attemptedDevices == [.mps, .cpu], "MPS must be tried first, then the CPU")

        let item = try #require(queue.items.first)
        #expect(item.state == .completed)
        #expect(item.didFallBackToCPU)
        // The fallback isn't hidden from the user: the failed attempt's log is still there.
        #expect(item.logLines.contains { $0.contains("MPS") })
    }

    @Test("A CPU failure is not retried")
    func cpuFailureIsNotRetried() async throws {
        let engine = FakeEngine(failingDevices: [.cpu, .mps])
        let queue = JobQueue(engine: engine)
        let file = try TemporaryAudio.make()
        defer { TemporaryAudio.remove(file) }

        var settings = WhisperSettings()
        settings.device = .cpu
        queue.enqueue([file], settings: settings)
        await queue.runToCompletion()

        #expect(engine.attemptedDevices == [.cpu])
        #expect(queue.items.first?.state == .failed)
    }

    /// If **both** MPS and CPU fail, the job ends failed; it doesn't spin in a loop.
    @Test("If both devices fail the job falls back once and then fails")
    func bothDevicesFail() async throws {
        let engine = FakeEngine(failingDevices: [.cpu, .mps])
        let queue = JobQueue(engine: engine)
        let file = try TemporaryAudio.make()
        defer { TemporaryAudio.remove(file) }

        var settings = WhisperSettings()
        settings.device = .mps
        queue.enqueue([file], settings: settings)
        await queue.runToCompletion()

        #expect(engine.attemptedDevices == [.mps, .cpu])
        #expect(queue.items.first?.state == .failed)
    }

    @Test("The queue processes the files in order")
    func processesSequentially() async throws {
        let engine = FakeEngine(failingDevices: [])
        let queue = JobQueue(engine: engine)
        let files = try (0..<3).map { _ in try TemporaryAudio.make() }
        defer { files.forEach(TemporaryAudio.remove) }

        queue.enqueue(files, settings: WhisperSettings())
        await queue.runToCompletion()

        #expect(queue.items.count == 3)
        #expect(queue.items.allSatisfy { $0.state == .completed })
        #expect(engine.attemptedDevices.count == 3)
        #expect(queue.isRunning == false)
    }

    @Test("A file already waiting is not enqueued twice")
    func doesNotEnqueueDuplicates() throws {
        let engine = FakeEngine(failingDevices: [])
        let queue = JobQueue(engine: engine)
        let file = try TemporaryAudio.make()
        defer { TemporaryAudio.remove(file) }

        #expect(queue.enqueue([file], settings: WhisperSettings()) == 1)
        #expect(queue.enqueue([file], settings: WhisperSettings()) == 0)
        #expect(queue.items.count == 1)
    }
}

extension JobQueue {
    /// Starts the queue and waits for it to empty.
    fileprivate func runToCompletion() async {
        await withCheckedContinuation { continuation in
            onFinish = { continuation.resume() }
            start()
        }
        onFinish = nil
    }
}

/// A fake engine that fails on the given devices and uses neither the network nor Python.
private final class FakeEngine: TranscriptionEngine, @unchecked Sendable {

    let id = EngineID.pythonWhisper

    private let lock = NSLock()
    private let failingDevices: Set<Device>
    private var devices: [Device] = []

    init(failingDevices: Set<Device>) {
        self.failingDevices = failingDevices
    }

    /// The devices of the `transcribe` calls, in call order.
    var attemptedDevices: [Device] {
        lock.withLock { devices }
    }

    func capabilities() async throws -> EngineCapabilities {
        EngineCapabilities(
            models: ["small"],
            modelsCached: ["small"],
            modelsBytes: nil,
            modelDir: nil,
            languages: [.init(code: "tr", name: "turkish")],
            outputFormats: ["txt"],
            tasks: ["transcribe"],
            devices: ["cpu", "mps"]
        )
    }

    @discardableResult
    func transcribe(
        _ job: TranscriptionJob,
        onEvent: @Sendable @escaping (EngineEvent) -> Void
    ) async throws -> EngineEvent.TranscriptionResult {
        lock.withLock { devices.append(job.device) }

        if failingDevices.contains(job.device) {
            throw EngineEvent.EngineFailure(
                code: .internalError,
                message: "did not run on \(job.device.rawValue)",
                detail: "a fake error",
                recoverable: true
            )
        }

        let result = EngineEvent.TranscriptionResult(
            jobID: job.jobID,
            language: "tr",
            duration: 1,
            elapsed: 1,
            rtf: 1,
            outputs: [],
            segmentCount: 0,
            textChars: 0
        )
        onEvent(.result(result))
        return result
    }
}

/// The queue checks that the file really exists; an empty audio file for the tests.
private enum TemporaryAudio {

    static func make() throws -> URL {
        let url = URL(filePath: NSTemporaryDirectory())
            .appending(path: "wt-queue-\(UUID().uuidString).m4a")
        try Data().write(to: url)
        return url
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
