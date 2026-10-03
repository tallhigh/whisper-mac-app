import Foundation

/// What the app is doing right now, for the menu bar — `docs/DECISIONS.md` → ADR-023.
///
/// A type of its own rather than three booleans read separately by the view: the states are
/// mutually exclusive and have an order of precedence (a recording in progress matters more
/// than a queue draining behind it), and putting that precedence in one place keeps the menu
/// bar, the toolbar and anything added later from disagreeing about it.
enum Activity: Equatable, Sendable {
    case idle
    /// Recording, with the audio written so far.
    case recording(elapsed: TimeInterval)
    case paused(elapsed: TimeInterval)
    /// The recording stopped and the worker is transcribing its last window (ADR-022).
    case finalizing
    /// A queue job is running. `fraction` is `nil` until the first progress event.
    case transcribing(name: String, fraction: Double?)

    /// Whether anything is happening. The menu bar item exists only while this is true.
    var isBusy: Bool { self != .idle }

    /// The menu bar symbol. Filled while recording so the item reads as "live" at a glance,
    /// outlined while merely working.
    var symbol: String {
        switch self {
        case .idle: "waveform"
        case .recording: "record.circle.fill"
        case .paused: "pause.circle.fill"
        case .finalizing: "ellipsis.circle"
        case .transcribing: "waveform.circle"
        }
    }

    /// The text beside the symbol in the menu bar. Short on purpose — it sits next to the
    /// clock and the system's own icons, and a long string pushes them around.
    ///
    /// `nil` means symbol only.
    var menuBarText: String? {
        switch self {
        case .idle, .finalizing:
            nil
        case .recording(let elapsed), .paused(let elapsed):
            TranscriptionItem.clock(elapsed)
        case .transcribing(_, let fraction):
            fraction.map { "\(Int(($0 * 100).rounded()))%" }
        }
    }

    /// The first line of the menu, spelling out what the symbol means.
    var title: String {
        switch self {
        case .idle:
            String(localized: "Idle")
        case .recording(let elapsed):
            String(localized: "Recording — \(TranscriptionItem.clock(elapsed))")
        case .paused(let elapsed):
            String(localized: "Paused — \(TranscriptionItem.clock(elapsed))")
        case .finalizing:
            String(localized: "Finishing the live text…")
        case .transcribing(let name, let fraction):
            if let fraction {
                String(localized: "Transcribing \(name) — \(Int((fraction * 100).rounded()))%")
            } else {
                String(localized: "Transcribing \(name)")
            }
        }
    }

    /// For VoiceOver on the menu bar item, where the symbol alone says nothing.
    var accessibilityLabel: String {
        switch self {
        case .idle: String(localized: "Whisper Transcriber, idle")
        default: title
        }
    }
}
