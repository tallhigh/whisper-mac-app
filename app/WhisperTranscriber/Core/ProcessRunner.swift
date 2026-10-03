import Foundation

/// The only way to run a child process.
///
/// Every contact the app has with Python or uv goes through here. The rules:
/// - Environment variables are passed **explicitly**; the user's shell profile isn't inherited.
/// - stdout and stderr are read concurrently (reading one side deadlocks when the pipe fills).
/// - Cancellation sends SIGTERM; SIGKILL follows once `terminationGrace` is up.
enum ProcessRunner {

    struct Result: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String

        var succeeded: Bool { exitCode == 0 }
    }

    enum Failure: LocalizedError {
        case launchFailed(executable: String, underlying: String)

        var errorDescription: String? {
            switch self {
            case .launchFailed(let executable, let underlying):
                String(localized: "\(executable) could not be run: \(underlying)")
            }
        }
    }

    /// A known base environment, stripped of the user's shell environment.
    ///
    /// Variables such as `PYTHONPATH`, `PYTHONHOME`, `VIRTUAL_ENV` and `PIP_*` are
    /// deliberately not carried over — a dirty profile breaks the isolated environment.
    static func baseEnvironment(extra: [String: String] = [:]) -> [String: String] {
        var environment: [String: String] = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": NSTemporaryDirectory(),
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
        ]
        environment.merge(extra) { _, new in new }
        return environment
    }

    /// Runs the process, waits for it to finish and collects all of its output.
    ///
    /// - Parameter onStandardOutputLine: called for every complete line from stdout.
    ///   For live progress; the lines also accumulate in `Result.stdout`.
    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        standardInput: String? = nil,
        onStandardOutputLine: (@Sendable (String) -> Void)? = nil,
        onStandardErrorLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let inPipe: Pipe? = standardInput == nil ? nil : Pipe()
        if let inPipe {
            process.standardInput = inPipe
        }

        do {
            try process.run()
        } catch {
            throw Failure.launchFailed(
                executable: executable.lastPathComponent,
                underlying: error.localizedDescription
            )
        }

        if let inPipe, let standardInput {
            // We write and close immediately: the worker waits for stdin to close.
            try? inPipe.fileHandleForWriting.write(contentsOf: Data(standardInput.utf8))
            try? inPipe.fileHandleForWriting.close()
        }

        // Both pipes must be read concurrently; reading in turn deadlocks when one fills.
        async let stdout = collect(outPipe.fileHandleForReading, onLine: onStandardOutputLine)
        async let stderr = collect(errPipe.fileHandleForReading, onLine: onStandardErrorLine)
        let (collectedOut, collectedErr) = await (stdout, stderr)

        await waitForExit(process)

        return Result(
            exitCode: process.terminationStatus,
            stdout: collectedOut,
            stderr: collectedErr
        )
    }

    /// Waits for the process to finish **without blocking**.
    ///
    /// `Process.waitUntilExit()` blocks the calling thread. Under Swift concurrency that
    /// holds a thread from the cooperative pool; with a few processes running at once the
    /// pool is exhausted, the reader tasks can't be scheduled and everything deadlocks.
    /// This really did happen in the tests, with a few `run()` calls going in parallel.
    static func waitForExit(_ process: Process) async {
        await withCheckedContinuation { continuation in
            let resumer = OnceResumer(continuation)
            process.terminationHandler = { _ in resumer.resume() }
            // It may have finished before terminationHandler was assigned.
            if !process.isRunning {
                resumer.resume()
            }
        }
    }

    private static func collect(
        _ handle: FileHandle,
        onLine: (@Sendable (String) -> Void)?
    ) async -> String {
        var collected = ""
        var pending = ""

        for await chunk in handle.chunks {
            guard let text = String(data: chunk, encoding: .utf8) else { continue }
            collected += text
            pending += text

            while let newline = pending.firstIndex(of: "\n") {
                let line = String(pending[pending.startIndex..<newline])
                pending = String(pending[pending.index(after: newline)...])
                if !line.isEmpty {
                    onLine?(line)
                }
            }
        }

        let tail = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            onLine?(tail)
        }
        return collected
    }
}

/// Resumes a continuation at most once.
///
/// The "has it already finished" check can race with `terminationHandler`; resuming twice
/// is a runtime error under `withCheckedContinuation`.
private final class OnceResumer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        let pending: CheckedContinuation<Void, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume()
    }
}

extension FileHandle {
    /// The raw chunks arriving until the pipe closes.
    ///
    /// We read in chunks rather than using `bytes.lines`: NDJSON lines can be long, and
    /// joining lines on the calling side keeps the back-pressure visible.
    fileprivate var chunks: AsyncStream<Data> {
        AsyncStream { continuation in
            readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
            continuation.onTermination = { @Sendable _ in
                self.readabilityHandler = nil
            }
        }
    }
}
