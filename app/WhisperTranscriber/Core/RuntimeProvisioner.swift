import CryptoKit
import Foundation

/// Installs the isolated Python runtime and checks its health.
///
/// `scripts/provision_runtime.sh` is this class's reference implementation; the step order,
/// the environment variables and the verifications have to stay identical on both sides.
/// Details and the measured timings: `docs/PYTHON_RUNTIME.md`.
actor RuntimeProvisioner {

    private let layout: RuntimeLayout
    private let bundle: Bundle
    private let fileManager = FileManager.default
    private var logHandle: FileHandle?

    init(layout: RuntimeLayout = RuntimeLayout(), bundle: Bundle = .main) {
        self.layout = layout
        self.bundle = bundle
    }

    // MARK: - Embedded resources

    /// `.app/Contents/MacOS/uv`
    private var bundledUV: URL? {
        bundle.url(forAuxiliaryExecutable: "uv")
    }

    /// `.app/Contents/Resources/python/requirements.txt`
    private var bundledRequirements: URL? {
        bundle.url(forResource: "requirements", withExtension: "txt", subdirectory: "python")
    }

    /// `.app/Contents/Resources/python/whisper_worker.py`
    nonisolated var bundledWorker: URL? {
        bundle.url(forResource: "whisper_worker", withExtension: "py", subdirectory: "python")
    }

    // MARK: - Health check

    /// Checks the installed environment from three angles: are the files in place, are the
    /// dependencies at the version the app expects, does the worker actually talk back.
    func currentState() async -> RuntimeState {
        guard fileManager.fileExists(atPath: layout.manifest.path) else {
            return .notInstalled
        }
        guard fileManager.isExecutableFile(atPath: layout.venvPython.path) else {
            return .broken(reason: String(localized: "The Python interpreter is missing."))
        }

        let info: RuntimeInfo
        do {
            info = try JSONDecoder().decode(RuntimeInfo.self, from: Data(contentsOf: layout.manifest))
        } catch {
            return .broken(reason: String(localized: "The setup manifest could not be read."))
        }
        guard info.schema == RuntimeInfo.currentSchema else {
            return .broken(reason: String(localized: "The manifest doesn't match this app version."))
        }

        // If the app was updated, the dependency list may have changed.
        guard let expected = try? requirementsHash(), expected == info.requirementsSha256 else {
            return .broken(reason: String(localized: "The dependency list changed; reinstall."))
        }

        // One failed probe doesn't make the environment broken: launching a child process
        // can fail transiently, and dropping the user onto the "environment is broken"
        // screen is an invitation to a needless 890 MB reinstall. We try once more; if it
        // still fails, the reason goes into the message.
        do {
            try await probeWorker()
        } catch {
            let detail = (error as? RuntimeError)?.detail ?? error.localizedDescription
            appendStandaloneLog("health probe attempt 1 failed: \(detail)")

            do {
                try await probeWorker()
            } catch {
                let detail = (error as? RuntimeError)?.detail ?? error.localizedDescription
                appendStandaloneLog("health probe attempt 2 failed: \(detail)")
                return .broken(
                    reason: String(localized: "The runtime is not responding.") + " " + detail)
            }
        }
        return .ready(info)
    }

    /// Probes the worker. Given a timeout, so a hung child process can't make the app wait
    /// forever at launch.
    private func probeWorker() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.verify() }
            group.addTask {
                try await Task.sleep(for: Self.probeTimeout)
                throw RuntimeError.verificationFailed("the probe timed out")
            }
            defer { group.cancelAll() }
            // First to finish wins: either the worker answered or the timeout threw.
            try await group.next()
        }
    }

    /// The measured `capabilities` time is ~9 s (importing torch dominates).
    /// We leave a wide margin for a slow disk and a cold cache.
    private static let probeTimeout: Duration = .seconds(60)

    // MARK: - Setup

    /// Installs the environment from scratch. A half-finished install is deleted first.
    ///
    /// `onProgress` is called at every step; to cancel, cancelling the calling `Task` is enough.
    func provision(onProgress: @Sendable @escaping (RuntimeState) -> Void) async throws -> RuntimeInfo {
        guard let uv = bundledUV else { throw RuntimeError.bundledResourceMissing("uv") }
        guard let requirements = bundledRequirements else {
            throw RuntimeError.bundledResourceMissing("requirements.txt")
        }

        // With no runtime.json the directory is half-finished; start clean.
        try? fileManager.removeItem(at: layout.runtime)
        try fileManager.createDirectory(at: layout.runtime, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: layout.logs, withIntermediateDirectories: true)
        openLog()
        defer { closeLog() }

        let environment = provisionEnvironment()

        try await step(.installPython, onProgress) {
            try await self.execute(uv, ["python", "install", Versions.python], environment, .installPython)
        }

        try await step(.createVenv, onProgress) {
            try await self.execute(
                uv,
                ["venv", "--python", Versions.python, self.layout.venv.path],
                environment,
                .createVenv
            )
        }

        try await step(.installDependencies, onProgress) {
            try await self.execute(
                uv,
                [
                    "pip", "install",
                    "--python", self.layout.venvPython.path,
                    "-r", requirements.path,
                ],
                environment,
                .installDependencies
            )
        }

        try await step(.linkFFmpeg, onProgress) { try await self.linkFFmpeg() }
        try await step(.clearQuarantine, onProgress) { try await self.clearQuarantine() }
        try await step(.verify, onProgress) { try await self.verify() }

        var info = try await step(.writeManifest, onProgress) {
            try await self.writeManifest(requirements: requirements)
        }

        try await step(.cleanCache, onProgress) {
            // Deleting the cache doesn't affect the venv (verified, ~810 MB comes back).
            // Its failing doesn't invalidate the installation.
            _ = try? await self.execute(uv, ["cache", "clean"], environment, .cleanCache)
        }

        info.installedAt = ISO8601DateFormatter().string(from: Date())
        return info
    }

    /// Deletes the runtime. It does not touch the user's `~/.cache/whisper` directory.
    func removeRuntime() throws {
        try? fileManager.removeItem(at: layout.uvCache)
        guard fileManager.fileExists(atPath: layout.runtime.path) else { return }
        try fileManager.removeItem(at: layout.runtime)
    }

    /// How much disk the installed environment occupies.
    ///
    /// Walking the tree isn't free (there are ~25k files in the environment), so it is never
    /// called on its own — only when the Settings window asks for it. Because it runs inside
    /// the actor, it doesn't block the main thread.
    func installedSize() -> Int64 {
        guard
            let enumerator = fileManager.enumerator(
                at: layout.runtime,
                includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
                options: [],
                errorHandler: nil
            )
        else {
            return 0
        }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            let bytes = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0
            total += Int64(bytes)
        }
        return total
    }

    // MARK: - Steps

    /// Some of the steps return a `ProcessRunner.Result` but the caller only cares whether
    /// they succeeded; the return value is discardable.
    @discardableResult
    private func step<T>(
        _ step: ProvisionStep,
        _ onProgress: @Sendable @escaping (RuntimeState) -> Void,
        _ body: () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        onProgress(.installing(step: step, fraction: previousFraction(of: step)))
        appendLog("=== \(step.rawValue)/\(ProvisionStep.count) \(step.title) ===")

        let started = Date()
        let result = try await body()
        appendLog(String(format: "    (%.1f sn)", Date().timeIntervalSince(started)))

        onProgress(.installing(step: step, fraction: step.cumulativeFraction))
        return result
    }

    private func previousFraction(of step: ProvisionStep) -> Double {
        guard let previous = ProvisionStep(rawValue: step.rawValue - 1) else { return 0 }
        return previous.cumulativeFraction
    }

    private func linkFFmpeg() async throws {
        let probe = try await runPython(
            ["-c", "import imageio_ffmpeg; print(imageio_ffmpeg.get_ffmpeg_exe())"]
        )
        let source = probe.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, fileManager.fileExists(atPath: source) else {
            throw RuntimeError.verificationFailed("the imageio-ffmpeg binary was not found.")
        }

        try fileManager.createDirectory(at: layout.binDir, withIntermediateDirectories: true)
        try? fileManager.removeItem(at: layout.ffmpeg)
        try fileManager.createSymbolicLink(at: layout.ffmpeg, withDestinationURL: URL(filePath: source))
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source)
    }

    /// If the quarantine flag is inherited by the files the app downloads, Gatekeeper won't
    /// launch Python. It is cleared once, at the end of setup.
    private func clearQuarantine() async throws {
        _ = try? await ProcessRunner.run(
            executable: URL(filePath: "/usr/bin/xattr"),
            arguments: ["-dr", "com.apple.quarantine", layout.runtime.path],
            environment: ProcessRunner.baseEnvironment()
        )
    }

    private func verify() async throws {
        let events = try await runWorker(mode: "capabilities")
        guard events.contains(where: { $0["type"] as? String == "hello" }) else {
            throw RuntimeError.verificationFailed("The worker produced no 'hello' event.")
        }
        guard events.contains(where: { $0["type"] as? String == "capabilities" }) else {
            throw RuntimeError.verificationFailed("The worker produced no capability list.")
        }
    }

    private func writeManifest(requirements: URL) async throws -> RuntimeInfo {
        let probe = try await runPython([
            "-c",
            """
            import json, platform, whisper, torch, imageio_ffmpeg
            print(json.dumps({
                "python": platform.python_version(),
                "whisper": getattr(whisper.version, "__version__", "?"),
                "torch": torch.__version__,
                "imageio_ffmpeg": imageio_ffmpeg.__version__,
            }))
            """,
        ])

        guard
            let data = probe.stdout.data(using: .utf8),
            let versions = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else {
            throw RuntimeError.verificationFailed("Version information could not be read: \(probe.stdout)")
        }

        let info = RuntimeInfo(
            schema: RuntimeInfo.currentSchema,
            python: versions["python"] ?? "?",
            whisper: versions["whisper"] ?? "?",
            torch: versions["torch"] ?? "?",
            imageioFfmpeg: versions["imageio_ffmpeg"] ?? "?",
            requirementsSha256: try requirementsHash(),
            installedAt: ISO8601DateFormatter().string(from: Date())
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(info).write(to: layout.manifest)
        return info
    }

    // MARK: - Child-process helpers

    private func provisionEnvironment() -> [String: String] {
        ProcessRunner.baseEnvironment(extra: [
            "UV_PYTHON_INSTALL_DIR": layout.pythonInstallDir.path,
            "UV_CACHE_DIR": layout.uvCache.path,
            // Never fall back to the system Python; ignore the user's uv.toml.
            "UV_PYTHON_PREFERENCE": "only-managed",
            "UV_NO_CONFIG": "1",
        ])
    }

    @discardableResult
    private func execute(
        _ executable: URL,
        _ arguments: [String],
        _ environment: [String: String],
        _ step: ProvisionStep
    ) async throws -> ProcessRunner.Result {
        let result = try await ProcessRunner.run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            onStandardOutputLine: { [weak self] line in Task { await self?.appendLog("    \(line)") } },
            onStandardErrorLine: { [weak self] line in Task { await self?.appendLog("    \(line)") } }
        )
        guard result.succeeded else {
            let output = [result.stderr, result.stdout]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            throw RuntimeError.stepFailed(step: step, exitCode: result.exitCode, output: output)
        }
        return result
    }

    private func runPython(_ arguments: [String]) async throws -> ProcessRunner.Result {
        let result = try await ProcessRunner.run(
            executable: layout.venvPython,
            arguments: arguments,
            environment: ProcessRunner.baseEnvironment()
        )
        guard result.succeeded else {
            throw RuntimeError.verificationFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return result
    }

    /// Runs the worker and returns the NDJSON events it produces.
    private func runWorker(mode: String, standardInput: String? = nil) async throws -> [[String: Any]] {
        guard let worker = bundledWorker else {
            throw RuntimeError.bundledResourceMissing("whisper_worker.py")
        }
        let result = try await ProcessRunner.run(
            executable: layout.venvPython,
            arguments: [worker.path, mode],
            environment: ProcessRunner.baseEnvironment(),
            standardInput: standardInput
        )
        let events = result.stdout
            .split(separator: "\n")
            .compactMap { line -> [String: Any]? in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
        guard !events.isEmpty else {
            let reason = result.stderr.isEmpty ? "produced no output" : result.stderr
            throw RuntimeError.verificationFailed(
                "worker exit code \(result.exitCode): \(reason)"
            )
        }
        return events
    }

    private func requirementsHash() throws -> String {
        guard let requirements = bundledRequirements else {
            throw RuntimeError.bundledResourceMissing("requirements.txt")
        }
        let digest = SHA256.hash(data: try Data(contentsOf: requirements))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Log

    /// Writes events that happen outside setup (a health check, say) to the log.
    private func appendStandaloneLog(_ line: String) {
        try? fileManager.createDirectory(at: layout.logs, withIntermediateDirectories: true)
        let url = layout.logs.appendingPathComponent("health.log")
        let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(stamped.utf8))
            try? handle.close()
        } else {
            try? Data(stamped.utf8).write(to: url)
        }
    }

    private func openLog() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = layout.logs.appendingPathComponent("provision-\(formatter.string(from: Date())).log")
        fileManager.createFile(atPath: url.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: url)
    }

    private func appendLog(_ line: String) {
        try? logHandle?.write(contentsOf: Data((line + "\n").utf8))
    }

    private func closeLog() {
        try? logHandle?.close()
        logHandle = nil
    }
}

/// The pinned versions. Their counterpart on the shell side is `scripts/versions.env`.
enum Versions {
    static let python = "3.13"
}
