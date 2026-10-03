import Foundation
import Testing

@testable import WhisperTranscriber

/// Tests that run the real Python worker.
///
/// They need an installed runtime and the audio files produced by `make fixtures`; with
/// either missing, the tests are skipped. They download no model and use no network.
///
///     make test-swift-slow
@Suite("Engine integration", .enabled(if: EngineIntegration.isAvailable))
struct EngineIntegrationTests {

    let engine = PythonWhisperEngine()

    @Test("The capabilities are read from the real worker")
    func capabilities() async throws {
        let capabilities = try await engine.capabilities()

        #expect(capabilities.models.contains("small"))
        #expect(capabilities.languages.contains { $0.code == "tr" })
        #expect(capabilities.outputFormats.contains("txt"))
        #expect(capabilities.devices.contains("cpu"))
        // The list isn't hard-coded; whatever whisper says.
        #expect(capabilities.languages.count > 50)
        // The size comes from the real worker; `small` is in the user's cache.
        #expect(capabilities.sizeLabel(for: "small") != nil)
        #expect(capabilities.cachedBytes > 0)
    }

    @Test("A real file is transcribed and the event stream honours the contract")
    func transcribesRealFile() async throws {
        let audio = try EngineIntegration.fixture("speech.m4a")
        let output = EngineIntegration.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: output) }

        var settings = WhisperSettings()
        settings.outputLocation = .customFolder
        settings.customOutputDirectory = output

        let collected = EventCollector()
        let result = try await engine.transcribe(
            settings.jobPayload(for: audio, jobID: "test")
        ) { event in
            collected.append(event)
        }

        #expect(result.language == "tr")
        #expect(result.outputs.count == 1)
        #expect(result.outputs[0].format == "txt")

        let written = try String(contentsOf: result.outputs[0].url, encoding: .utf8)
        #expect(written.contains("Merhaba"))

        // The protocol's order: hello first, result last.
        let types = collected.typeNames
        #expect(types.first == "hello")
        #expect(types.last == "result")
        #expect(types.contains("segment"))
        #expect(types.contains("progress"))
    }

    @Test("The notes format produces a timestamped bullet list")
    func writesTimestampedNotes() async throws {
        let audio = try EngineIntegration.fixture("speech.m4a")
        let output = EngineIntegration.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: output) }

        var settings = WhisperSettings()
        settings.outputLocation = .customFolder
        settings.customOutputDirectory = output
        settings.outputFormats = [.notes]

        let result = try await engine.transcribe(
            settings.jobPayload(for: audio, jobID: "notes")
        ) { _ in }

        let note = try #require(result.outputs.first)
        #expect(note.format == "notes")
        // The format is named "notes", the file extension is "md".
        #expect(note.path.hasSuffix("speech.md"))

        let written = try String(contentsOf: note.url, encoding: .utf8)
        let lines = written.split(separator: "\n")
        #expect(!lines.isEmpty)
        #expect(lines.allSatisfy { $0.hasPrefix("- [") })
        #expect(written.contains("Merhaba"))
    }

    @Test("A corrupt file gives a classified error and writes no file")
    func corruptFileFails() async throws {
        let audio = try EngineIntegration.fixture("corrupt.m4a")
        let output = EngineIntegration.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: output) }

        var settings = WhisperSettings()
        settings.outputLocation = .customFolder
        settings.customOutputDirectory = output

        await #expect(throws: EngineEvent.EngineFailure.self) {
            try await engine.transcribe(settings.jobPayload(for: audio, jobID: "corrupt")) { _ in }
        }

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: output.path)
        #expect(leftovers.isEmpty, "no file must be left behind on an error")
    }

    @Test("A file name with Turkish characters and an emoji is preserved")
    func unicodeFileName() async throws {
        let audio = try EngineIntegration.fixture("SAMPLE recording 🎙 şçğü.m4a")
        let output = EngineIntegration.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: output) }

        var settings = WhisperSettings()
        settings.outputLocation = .customFolder
        settings.customOutputDirectory = output

        let result = try await engine.transcribe(
            settings.jobPayload(for: audio, jobID: "unicode")
        ) { _ in }

        let path = try #require(result.outputs.first?.path)
        #expect(path.contains("🎙"))
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("An existing output is not overwritten")
    func refusesToOverwrite() async throws {
        let audio = try EngineIntegration.fixture("speech.m4a")
        let output = EngineIntegration.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: output) }

        let existing = output.appending(path: "speech.txt")
        try "do not touch".write(to: existing, atomically: true, encoding: .utf8)

        var settings = WhisperSettings()
        settings.outputLocation = .customFolder
        settings.customOutputDirectory = output
        settings.overwrite = false

        await #expect(throws: EngineEvent.EngineFailure.self) {
            try await engine.transcribe(settings.jobPayload(for: audio, jobID: "ow")) { _ in }
        }
        #expect(try String(contentsOf: existing, encoding: .utf8) == "do not touch")
    }

    @Test("A cancelled job leaves no half-written file")
    func cancellationLeavesNoOutput() async throws {
        let audio = try EngineIntegration.fixture("long.m4a")
        let output = EngineIntegration.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: output) }

        var settings = WhisperSettings()
        settings.outputLocation = .customFolder
        settings.customOutputDirectory = output

        let task = Task {
            try await engine.transcribe(settings.jobPayload(for: audio, jobID: "cancel")) { _ in }
        }

        // Let transcription start, then cancel it.
        try await Task.sleep(for: .seconds(12))
        task.cancel()

        let result = await task.result
        #expect(throws: (any Error).self) { try result.get() }

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: output.path)
        #expect(leftovers.isEmpty, "no file must be left behind on cancellation")
    }
}

enum EngineIntegration {

    static var runtimeReady: Bool {
        FileManager.default.isExecutableFile(atPath: RuntimeLayout().venvPython.path)
    }

    /// Finds the repository root by walking up from the test bundle's location.
    ///
    /// We don't use an environment variable: `xcodebuild test` doesn't pass the shell's
    /// environment into the test process, and that silently leads to "0 tests ran".
    static let fixturesDirectory: URL? = {
        var directory = Bundle(for: BundleAnchor.self).bundleURL
        for _ in 0..<10 {
            directory = directory.deletingLastPathComponent()
            let candidate = directory.appending(path: "python/tests/fixtures")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }()

    /// Runs when the runtime is installed and the fixtures have been produced.
    /// `make test-swift` skips this suite; `make test-swift-slow` runs only it.
    static var isAvailable: Bool {
        runtimeReady && fixturesDirectory != nil
    }

    static func fixture(_ name: String) throws -> URL {
        let directory = try #require(fixturesDirectory, "the fixtures directory was not found")
        let url = directory.appending(path: name)
        try #require(FileManager.default.fileExists(atPath: url.path), "fixture missing: \(name) — 'make fixtures'")
        return url
    }

    static func makeTemporaryDirectory() -> URL {
        let url = URL(filePath: NSTemporaryDirectory()).appending(path: "wt-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// An anchor for finding the test bundle's location with `Bundle(for:)`.
private final class BundleAnchor {}

/// The events arrive from different threads.
private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [EngineEvent] = []

    func append(_ event: EngineEvent) {
        lock.withLock { events.append(event) }
    }

    var typeNames: [String] {
        lock.withLock {
            events.map { event in
                switch event {
                case .hello: "hello"
                case .capabilities: "capabilities"
                case .status: "status"
                case .progress: "progress"
                case .segment: "segment"
                case .log: "log"
                case .result: "result"
                case .failure: "error"
                case .committed: "committed"
                case .partial: "partial"
                case .unknown: "unknown"
                }
            }
        }
    }
}
