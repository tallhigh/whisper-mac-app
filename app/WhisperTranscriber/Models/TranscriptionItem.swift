import Foundation
import Observation
import UniformTypeIdentifiers

/// A single file in the queue, with its live state.
@MainActor
@Observable
final class TranscriptionItem: Identifiable {

    let id = UUID()
    let url: URL

    private(set) var state: State = .queued
    private(set) var phase: EngineEvent.Status.Phase?
    private(set) var fraction: Double?
    private(set) var audioDuration: Double?
    private(set) var transcript: String = ""
    private(set) var logLines: [String] = []
    private(set) var result: EngineEvent.TranscriptionResult?
    private(set) var failure: Failure?
    /// Did an MPS attempt fail and fall back to CPU? (ADR-012)
    private(set) var didFallBackToCPU = false

    /// A copy of the settings that were in effect when this job was started.
    ///
    /// Changing a setting doesn't affect a running job; every job in the queue runs with its
    /// own snapshot.
    var settings: WhisperSettings

    init(url: URL, settings: WhisperSettings) {
        self.url = url
        self.settings = settings
    }

    enum State: Equatable, Sendable {
        case queued
        case running
        case completed
        case failed
        case cancelled

        var isFinished: Bool {
            switch self {
            case .completed, .failed, .cancelled: true
            case .queued, .running: false
            }
        }
    }

    struct Failure: Equatable, Sendable {
        var message: String
        var detail: String
        var suggestion: String?
    }

    var name: String { url.lastPathComponent }

    // MARK: - Applying events

    func apply(_ event: EngineEvent) {
        switch event {
        case .status(let status):
            phase = status.phase
            if let duration = status.duration { audioDuration = duration }
        case .progress(let progress):
            if let value = progress.fraction { fraction = value }
        case .segment(let segment):
            transcript += segment.text
        case .result(let value):
            result = value
            fraction = 1
        case .failure(let value):
            // Cancellation isn't an error; it isn't shown to the user in red. We make the
            // distinction by **code**: comparing the message text breaks under
            // localization.
            if value.code != .cancelled {
                setFailure(
                    message: value.message,
                    detail: value.detail ?? "",
                    suggestion: value.code.suggestion
                )
            }
        case .hello, .capabilities, .log, .committed, .partial, .unknown:
            break
        }

        if let line = event.logLine {
            appendLog(line)
        }
    }

    func markRunning() {
        state = .running
        phase = nil
        fraction = nil
        transcript = ""
        logLines = []
        result = nil
        failure = nil
        didFallBackToCPU = false
    }

    /// MPS failed; prepares to switch the device to CPU and retry.
    ///
    /// The log lines are **preserved** — the user needs to see why MPS fell back; all they
    /// see on screen shouldn't be "it ran on the CPU".
    func fallBackToCPU() {
        appendLog("[warning] MPS failed, retrying on the CPU.")
        settings.device = .cpu
        didFallBackToCPU = true
        state = .running
        phase = nil
        fraction = nil
        transcript = ""
        result = nil
        failure = nil
    }

    func markCompleted() {
        state = .completed
        phase = nil
        fraction = 1
    }

    func markCancelled() {
        state = .cancelled
        phase = nil
        fraction = nil
    }

    func markFailed(message: String, detail: String = "", suggestion: String? = nil) {
        setFailure(message: message, detail: detail, suggestion: suggestion)
        state = .failed
        phase = nil
    }

    func requeue(with settings: WhisperSettings) {
        self.settings = settings
        state = .queued
        phase = nil
        fraction = nil
        failure = nil
        result = nil
        transcript = ""
        logLines = []
        didFallBackToCPU = false
    }

    private func setFailure(message: String, detail: String, suggestion: String?) {
        failure = Failure(message: message, detail: detail, suggestion: suggestion)
    }

    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 500 {
            logLines.removeFirst(logLines.count - 500)
        }
    }

    // MARK: - Display

    /// The subtitle of the queue row.
    var statusText: String {
        switch state {
        case .queued:
            String(localized: "queued")
        case .running:
            phase?.title ?? String(localized: "preparing")
        case .completed:
            completedSummary
        case .failed:
            failure?.message ?? String(localized: "failed")
        case .cancelled:
            String(localized: "cancelled")
        }
    }

    private var completedSummary: String {
        guard let result else { return String(localized: "completed") }
        let formats = result.outputs.map(\.format).joined(separator: " · ")
        let size = result.outputs.compactMap(\.bytes).reduce(0, +)
        var parts = [formats]
        if size > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        if let speed = result.speedMultiplier {
            parts.append(String(format: "%.1fx", speed))
        }
        return parts.joined(separator: " · ")
    }

    /// Progress in the form `03:02 / 10:12`.
    var timeText: String? {
        guard state == .running, let audioDuration, let fraction else { return nil }
        return "\(Self.clock(audioDuration * fraction)) / \(Self.clock(audioDuration))"
    }

    /// Pure formatting; the live-text writer calls it from off the main actor too.
    nonisolated static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let remainder = total % 60
        if minutes >= 60 {
            return String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, remainder)
        }
        return String(format: "%02d:%02d", minutes, remainder)
    }
}

// MARK: - Supported files

enum SupportedMedia {

    /// ffmpeg can extract the audio from these. Video is accepted too — as long as there is
    /// an audio stream, it's fine.
    static let fileExtensions: Set<String> = [
        "m4a", "mp3", "wav", "aiff", "aif", "flac", "ogg", "oga", "opus", "wma", "aac", "caf",
        "mp4", "mov", "m4v", "mkv", "webm", "avi",
    ]

    static let contentTypes: [UTType] = [.audio, .movie, .mpeg4Movie, .mp3, .wav, .aiff]

    static func isSupported(_ url: URL) -> Bool {
        fileExtensions.contains(url.pathExtension.lowercased())
    }

    /// Turns the dropped URLs into files that can be opened.
    ///
    /// If a folder is dropped, the supported files **one level** deep are collected; walking
    /// the whole disk tree would be a surprise.
    static func collect(from urls: [URL]) -> (accepted: [URL], rejected: [URL]) {
        var accepted: [URL] = []
        var rejected: [URL] = []

        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                rejected.append(url)
                continue
            }

            if isDirectory.boolValue {
                let contents =
                    (try? FileManager.default.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    )) ?? []
                let supported = contents.filter(isSupported).sorted {
                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                        == .orderedAscending
                }
                if supported.isEmpty {
                    rejected.append(url)
                } else {
                    accepted.append(contentsOf: supported)
                }
            } else if isSupported(url) {
                accepted.append(url)
            } else {
                rejected.append(url)
            }
        }

        return (accepted, rejected)
    }
}
