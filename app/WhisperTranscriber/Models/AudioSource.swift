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

/// An app playing audio.
///
/// The unit is the **app**, not the process, and that distinction is the whole point.
/// Chrome plays through a renderer helper, not through the process the user thinks of as
/// Chrome: the helper's `NSRunningApplication` is `nil`, so a per-process list offers
/// "com.google.Chrome.helper" and never "Google Chrome" — and a tap installed on Chrome's
/// main process delivers nothing at all (measured: the IOProc is never called once).
/// Grouping by the owning app is what makes the picker mean what it says.
///
/// The pids are the ones found when the list was built. They are **not** what the tap is
/// created from: helpers come and go, so `AudioProcessList.objectIDs(for:)` resolves the
/// app's processes again at the moment recording starts.
struct AudioApplication: Identifiable, Equatable, Sendable {
    /// Every process of this app that was producing output when the list was built.
    var pids: [pid_t]
    var bundleID: String?
    var name: String

    /// Stable across refreshes, so the picker keeps its selection even though the helper
    /// processes behind it change.
    var id: String { bundleID ?? "pid:\(pids.first ?? 0)" }
}

/// Whose audio to take.
enum SystemAudioScope: Equatable, Sendable {
    /// Everything except the app's own audio.
    case everything
    /// Only the selected apps.
    case apps([AudioApplication])

    var selected: [AudioApplication] {
        if case .apps(let list) = self { return list }
        return []
    }
}
