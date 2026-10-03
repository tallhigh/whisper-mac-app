import Foundation
import Testing

@testable import WhisperTranscriber

@Suite("The runtime layout")
struct RuntimeLayoutTests {

    let layout = RuntimeLayout(support: URL(filePath: "/tmp/wt-test"))

    @Test("The paths match the shell script")
    func paths() {
        // Must match scripts/provision_runtime.sh exactly.
        #expect(layout.runtime.path == "/tmp/wt-test/runtime")
        #expect(layout.venv.path == "/tmp/wt-test/runtime/venv")
        #expect(layout.venvPython.path == "/tmp/wt-test/runtime/venv/bin/python3")
        #expect(layout.ffmpeg.path == "/tmp/wt-test/runtime/bin/ffmpeg")
        #expect(layout.manifest.path == "/tmp/wt-test/runtime/runtime.json")
        #expect(layout.logs.path == "/tmp/wt-test/logs")
    }

    @Test("The cache is not under Application Support")
    func cacheLivesInCaches() {
        // Temporary data deleted at the end of setup; it mustn't sit in a backed-up directory.
        #expect(layout.uvCache.path.contains("/Caches/"))
        #expect(!layout.uvCache.path.contains("Application Support"))
    }

    @Test("The default layout is under Application Support")
    func defaultLayout() {
        let standard = RuntimeLayout()
        #expect(standard.support.path.hasSuffix("Application Support/WhisperTranscriber"))
    }
}

@Suite("The setup steps")
struct ProvisionStepTests {

    @Test("There are eight steps and they are in order")
    func stepCount() {
        #expect(ProvisionStep.count == 8)
        #expect(ProvisionStep.allCases.map(\.rawValue) == Array(1...8))
    }

    @Test("The progress fractions increase and end at 1.0")
    func fractionsAreMonotonic() {
        let fractions = ProvisionStep.allCases.map(\.cumulativeFraction)
        for (previous, next) in zip(fractions, fractions.dropFirst()) {
            #expect(next > previous)
        }
        #expect(fractions.last == 1.0)
        #expect(fractions.first! > 0)
    }

    @Test("The longest step is installing the dependencies")
    func heaviestStep() {
        // Measured: 46 of the 61 s is this step (docs/PYTHON_RUNTIME.md).
        let heaviest = ProvisionStep.allCases.max { $0.weight < $1.weight }
        #expect(heaviest == .installDependencies)
    }

    @Test("Every step has a title")
    func titles() {
        for step in ProvisionStep.allCases {
            #expect(!step.title.isEmpty)
        }
    }
}

@Suite("The setup manifest")
struct RuntimeInfoTests {

    @Test("The JSON the Python side writes can be read")
    func decodesSnakeCaseKeys() throws {
        // scripts/provision_runtime.sh produces this format; the two sides must agree.
        let json = """
            {
              "schema": 1,
              "python": "3.13.15",
              "whisper": "20250625",
              "torch": "2.14.1",
              "imageio_ffmpeg": "0.6.0",
              "requirements_sha256": "abc123",
              "installed_at": "2026-10-01T12:37:53.601042+00:00"
            }
            """
        let info = try JSONDecoder().decode(RuntimeInfo.self, from: Data(json.utf8))

        #expect(info.schema == RuntimeInfo.currentSchema)
        #expect(info.python == "3.13.15")
        #expect(info.imageioFfmpeg == "0.6.0")
        #expect(info.requirementsSha256 == "abc123")
    }

    @Test("The round trip is lossless")
    func roundTrip() throws {
        let original = RuntimeInfo(
            schema: 1,
            python: "3.13.15",
            whisper: "20250625",
            torch: "2.14.1",
            imageioFfmpeg: "0.6.0",
            requirementsSha256: "deadbeef",
            installedAt: "2026-10-01T12:00:00Z"
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(RuntimeInfo.self, from: data) == original)
    }

    @Test("A missing field errors")
    func rejectsIncomplete() {
        let json = #"{"schema": 1, "python": "3.13.15"}"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(RuntimeInfo.self, from: Data(json.utf8))
        }
    }
}

@Suite("The runtime state")
struct RuntimeStateTests {

    @Test("isReady is true only for ready")
    func isReady() {
        let info = RuntimeInfo(
            schema: 1, python: "3.13", whisper: "1", torch: "2",
            imageioFfmpeg: "3", requirementsSha256: "x", installedAt: "y"
        )
        #expect(RuntimeState.ready(info).isReady)
        #expect(!RuntimeState.notInstalled.isReady)
        #expect(!RuntimeState.broken(reason: "x").isReady)
        #expect(!RuntimeState.installing(step: .verify, fraction: 0.9).isReady)
    }

    @Test("isInstalling is true during the setup")
    func isInstalling() {
        #expect(RuntimeState.installing(step: .createVenv, fraction: 0.1).isInstalling)
        #expect(!RuntimeState.checking.isInstalling)
    }
}
