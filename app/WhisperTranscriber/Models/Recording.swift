import Foundation

/// The state of a recording session — `docs/LIVE_TRANSCRIPTION.md`.
enum RecordingState: Equatable, Sendable {
    case idle
    case preparing
    case recording
    case paused
    case failed(reason: String)

    var isActive: Bool {
        switch self {
        case .recording, .paused: true
        case .idle, .preparing, .failed: false
        }
    }
}

/// The outcome of asking for audio-capture access.
///
/// A type of its own: the action to show the user differs in every case, and we don't want
/// to leak `AVAuthorizationStatus` into the view layer.
enum CaptureAccess: Equatable, Sendable {
    case granted
    /// The user hasn't been asked yet; the system dialog will be shown.
    case undetermined
    /// The user refused, or the system blocks it; they are sent to System Settings.
    case denied
}

/// Decides a recording file's name and place.
///
/// Pure: the same input always gives the same name. Because the recording itself is
/// unrecoverable data, it **never** overwrites an existing file, under any circumstances.
enum RecordingFile {

    static let fileExtension = "m4a"

    /// `Recording 2026-10-02 14-30.m4a`
    static func name(at date: Date) -> String {
        "\(defaultName(at: date)).\(fileExtension)"
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        // A fixed format: the file name mustn't depend on the locale.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        return formatter.string(from: date)
    }

    /// Makes the name the user gave safe to use as a file name.
    ///
    /// `/` is the path separator on macOS and `:` was Finder's old one — neither can appear
    /// in a file name. A leading dot hides the file. If the name empties out entirely, `nil`
    /// is returned and the caller falls back to the default.
    static func sanitize(_ name: String) -> String? {
        var cleaned =
            name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") {
            cleaned.removeFirst()
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        // The file-system limit is 255 bytes; Turkish characters take several bytes each.
        if cleaned.count > 120 {
            cleaned = String(cleaned.prefix(120)).trimmingCharacters(in: .whitespaces)
        }
        return cleaned.isEmpty ? nil : cleaned
    }

    /// The default name derived from the date — used when the user types nothing.
    static func defaultName(at date: Date) -> String {
        "\(String(localized: "Recording")) \(stamp(date))"
    }

    /// Produces a non-colliding path in the folder: `… (2).m4a`, `… (3).m4a`.
    static func uniqueURL(
        in directory: URL,
        named name: String? = nil,
        at date: Date,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let base = name.flatMap(sanitize) ?? defaultName(at: date)
        var candidate = directory.appending(path: "\(base).\(fileExtension)")
        var counter = 2
        while exists(candidate) {
            candidate = directory.appending(path: "\(base) (\(counter)).\(fileExtension)")
            counter += 1
        }
        return candidate
    }
}

/// What a recording returns when it finishes.
struct RecordingResult: Equatable, Sendable {
    var url: URL
    /// The duration of audio written (paused time not included).
    var duration: TimeInterval
}
