import Foundation
import Testing

@testable import WhisperTranscriber

@Suite("The child-process runner")
struct ProcessRunnerTests {

    @Test("The output and the exit code are collected")
    func capturesOutput() async throws {
        let result = try await ProcessRunner.run(
            executable: URL(filePath: "/bin/echo"),
            arguments: ["hello", "world"],
            environment: ProcessRunner.baseEnvironment()
        )

        #expect(result.succeeded)
        #expect(result.exitCode == 0)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello world")
    }

    @Test("A non-zero exit code counts as a failure")
    func nonZeroExit() async throws {
        let result = try await ProcessRunner.run(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", "exit 3"],
            environment: ProcessRunner.baseEnvironment()
        )

        #expect(!result.succeeded)
        #expect(result.exitCode == 3)
    }

    @Test("stdout and stderr are collected separately")
    func separatesStreams() async throws {
        let result = try await ProcessRunner.run(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", "echo out; echo err >&2"],
            environment: ProcessRunner.baseEnvironment()
        )

        #expect(result.stdout.contains("out"))
        #expect(!result.stdout.contains("err"))
        #expect(result.stderr.contains("err"))
    }

    @Test("The line callback runs for every complete line")
    func streamsLines() async throws {
        let collector = LineCollector()
        _ = try await ProcessRunner.run(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", "echo one; echo two; echo three"],
            environment: ProcessRunner.baseEnvironment(),
            onStandardOutputLine: { line in collector.append(line) }
        )

        #expect(collector.lines == ["one", "two", "three"])
    }

    @Test("The last line is emitted even without a trailing newline")
    func emitsTrailingLineWithoutNewline() async throws {
        let collector = LineCollector()
        _ = try await ProcessRunner.run(
            executable: URL(filePath: "/usr/bin/printf"),
            arguments: ["last line"],
            environment: ProcessRunner.baseEnvironment(),
            onStandardOutputLine: { line in collector.append(line) }
        )

        #expect(collector.lines == ["last line"])
    }

    @Test("stdin is written and closed")
    func writesStandardInput() async throws {
        // The worker waits for stdin to close; without that the process hangs.
        let result = try await ProcessRunner.run(
            executable: URL(filePath: "/bin/cat"),
            arguments: [],
            environment: ProcessRunner.baseEnvironment(),
            standardInput: "{\"v\":1}\n"
        )

        #expect(result.succeeded)
        #expect(result.stdout.contains("{\"v\":1}"))
    }

    @Test("A large output does not deadlock")
    func handlesLargeOutput() async throws {
        // Waiting without reading one of the pipes would deadlock once it filled.
        let result = try await ProcessRunner.run(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", "for i in $(seq 1 20000); do echo line-$i; done; echo done >&2"],
            environment: ProcessRunner.baseEnvironment()
        )

        #expect(result.succeeded)
        #expect(result.stdout.contains("line-20000"))
        #expect(result.stderr.contains("done"))
    }

    @Test("A missing executable gives an understandable error")
    func missingExecutable() async {
        await #expect(throws: ProcessRunner.Failure.self) {
            _ = try await ProcessRunner.run(
                executable: URL(filePath: "/tmp/definitely-missing-12345"),
                arguments: [],
                environment: ProcessRunner.baseEnvironment()
            )
        }
    }

    @Test("The base environment does not carry the user Python variables")
    func baseEnvironmentIsClean() {
        let environment = ProcessRunner.baseEnvironment()

        // A dirty shell profile can break the isolated environment; these must never pass.
        #expect(environment["PYTHONPATH"] == nil)
        #expect(environment["PYTHONHOME"] == nil)
        #expect(environment["VIRTUAL_ENV"] == nil)
        #expect(environment.keys.allSatisfy { !$0.hasPrefix("PIP_") })

        #expect(environment["HOME"] == NSHomeDirectory())
        #expect(environment["PATH"] != nil)
    }

    @Test("Extra variables are added to the base environment")
    func baseEnvironmentMerges() {
        let environment = ProcessRunner.baseEnvironment(extra: [
            "UV_NO_CONFIG": "1",
            "PATH": "/custom/path",
        ])

        #expect(environment["UV_NO_CONFIG"] == "1")
        #expect(environment["PATH"] == "/custom/path", "an extra variable must override the base")
        #expect(environment["HOME"] == NSHomeDirectory())
    }

    @Test("The environment given really reaches the child process")
    func environmentReachesChild() async throws {
        let result = try await ProcessRunner.run(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", "echo $WT_TEST_VARIABLE"],
            environment: ProcessRunner.baseEnvironment(extra: ["WT_TEST_VARIABLE": "passed"])
        )

        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "passed")
    }
}

/// The line callbacks can arrive from different threads.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.withLock { storage.append(line) }
    }

    var lines: [String] {
        lock.withLock { storage }
    }
}
