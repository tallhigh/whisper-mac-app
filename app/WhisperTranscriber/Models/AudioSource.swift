import CoreAudio
import Foundation

/// Where the recording comes from — `docs/LIVE_TRANSCRIPTION.md` → Audio sources.
enum AudioSource: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Only the person speaking.
    case microphone
    /// Only the other side: the audio Zoom/Meet sends to the speakers.
    case systemAudio
    /// Both sides of the call.
    case both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: String(localized: "Microphone")
        case .systemAudio: String(localized: "System audio")
        case .both: String(localized: "Microphone + system audio")
        }
    }

    var detail: String {
        switch self {
        case .microphone: String(localized: "Only your own voice")
        case .systemAudio: String(localized: "Only the other side")
        case .both: String(localized: "Both sides of the call")
        }
    }

    /// Is system audio being captured? (app selection only makes sense then)
    var capturesSystemAudio: Bool { self != .microphone }

    var capturesMicrophone: Bool { self != .systemAudio }
}

/// A process playing audio.
///
/// Identified by its `AudioObjectID`: `CATapDescription.bundleIDs` only exists on macOS 26,
/// and our target is 14.4.
struct AudioProcess: Identifiable, Equatable, Sendable {
    var objectID: AudioObjectID
    var pid: pid_t
    var bundleID: String?
    var name: String

    var id: AudioObjectID { objectID }
}

/// Whose audio to take.
enum SystemAudioScope: Equatable, Sendable {
    /// Everything except the app's own audio.
    case everything
    /// Only the selected processes.
    case processes([AudioProcess])

    var selected: [AudioProcess] {
        if case .processes(let list) = self { return list }
        return []
    }
}
