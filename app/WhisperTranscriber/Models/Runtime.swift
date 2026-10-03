import Foundation

/// The file layout of the isolated Python runtime.
///
/// The single source of truth: `docs/PYTHON_RUNTIME.md`. Its counterpart on the shell side
/// is `scripts/provision_runtime.sh` — both sides have to use the same paths.
struct RuntimeLayout: Sendable {
    let support: URL

    init(support: URL? = nil) {
        self.support =
            support
            ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperTranscriber", isDirectory: true)
    }

    var runtime: URL { support.appendingPathComponent("runtime", isDirectory: true) }
    var pythonInstallDir: URL { runtime.appendingPathComponent("python", isDirectory: true) }
    var venv: URL { runtime.appendingPathComponent("venv", isDirectory: true) }
    var venvPython: URL { venv.appendingPathComponent("bin/python3") }
    var binDir: URL { runtime.appendingPathComponent("bin", isDirectory: true) }
    var ffmpeg: URL { binDir.appendingPathComponent("ffmpeg") }
    var manifest: URL { runtime.appendingPathComponent("runtime.json") }
    var logs: URL { support.appendingPathComponent("logs", isDirectory: true) }
    var presets: URL { support.appendingPathComponent("presets.json") }
    /// The record of past work — ADR-024.
    var history: URL { support.appendingPathComponent("history.json") }

    /// The temporary download cache. It is cleared at the end of setup, which is why it
    /// lives under Caches rather than Application Support.
    var uvCache: URL {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperTranscriber/uv", isDirectory: true)
    }
}

/// The installed environment's manifest — `runtime.json`.
struct RuntimeInfo: Codable, Equatable, Sendable {
    var schema: Int
    var python: String
    var whisper: String
    var torch: String
    var imageioFfmpeg: String
    var requirementsSha256: String
    var installedAt: String

    enum CodingKeys: String, CodingKey {
        case schema
        case python
        case whisper
        case torch
        case imageioFfmpeg = "imageio_ffmpeg"
        case requirementsSha256 = "requirements_sha256"
        case installedAt = "installed_at"
    }

    static let currentSchema = 1
}

/// The setup steps. The order and the count match `scripts/provision_runtime.sh`.
enum ProvisionStep: Int, CaseIterable, Sendable {
    case installPython = 1
    case createVenv
    case installDependencies
    case linkFFmpeg
    case clearQuarantine
    case verify
    case writeManifest
    case cleanCache

    static var count: Int { allCases.count }

    var title: String {
        switch self {
        case .installPython: String(localized: "Downloading Python")
        case .createVenv: String(localized: "Creating the virtual environment")
        case .installDependencies: String(localized: "Installing dependencies")
        case .linkFFmpeg: String(localized: "Linking ffmpeg")
        case .clearQuarantine: String(localized: "Clearing quarantine flags")
        case .verify: String(localized: "Verifying")
        case .writeManifest: String(localized: "Recording the manifest")
        case .cleanCache: String(localized: "Cleaning temporary files")
        }
    }

    /// The steps' relative weights — so the progress bar doesn't jump in equal increments.
    /// Derived from the measured timings (docs/PYTHON_RUNTIME.md).
    var weight: Double {
        switch self {
        case .installDependencies: 46
        case .verify: 9
        case .installPython: 2
        case .linkFFmpeg, .clearQuarantine, .cleanCache: 1
        case .createVenv, .writeManifest: 0.5
        }
    }

    static let totalWeight: Double = allCases.reduce(0) { $0 + $1.weight }

    /// The total fraction (0...1) counted as complete once this step finishes.
    var cumulativeFraction: Double {
        let done = Self.allCases.prefix(rawValue).reduce(0) { $0 + $1.weight }
        return done / Self.totalWeight
    }
}

/// The state of the runtime.
enum RuntimeState: Equatable, Sendable {
    case unknown
    case checking
    case notInstalled
    case installing(step: ProvisionStep, fraction: Double)
    case ready(RuntimeInfo)
    case broken(reason: String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var isInstalling: Bool {
        if case .installing = self { return true }
        return false
    }
}

/// Setup and health-check errors.
enum RuntimeError: LocalizedError, Equatable {
    case bundledResourceMissing(String)
    case stepFailed(step: ProvisionStep, exitCode: Int32, output: String)
    case verificationFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .bundledResourceMissing(let name):
            String(localized: "\(name) is missing from the app bundle. Download the app again.")
        case .stepFailed(let step, let exitCode, _):
            String(localized: "The \(step.title) step failed (exit code \(exitCode)).")
        case .verificationFailed(let detail):
            String(localized: "Setup could not be verified: \(detail)")
        case .cancelled:
            String(localized: "Setup was cancelled.")
        }
    }

    /// The raw output to show in the diagnostics panel.
    var detail: String {
        switch self {
        case .stepFailed(_, _, let output): output
        case .verificationFailed(let detail): detail
        case .bundledResourceMissing(let name): name
        case .cancelled: ""
        }
    }
}
