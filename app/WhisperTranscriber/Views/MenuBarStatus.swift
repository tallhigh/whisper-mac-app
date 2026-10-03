import SwiftUI

/// The menu bar item's label — `docs/DECISIONS.md` → ADR-023.
///
/// Symbol plus a short piece of text: the elapsed time while recording, the percentage while
/// transcribing. The text is what makes the item answer the question from across the room,
/// and it is kept short because it sits beside the clock and the system's own icons.
struct MenuBarStatusLabel: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let activity = state.activity
        HStack(spacing: 3) {
            Image(systemName: activity.symbol)
            if let text = activity.menuBarText {
                // Monospaced digits, or the whole menu bar shifts every second as the clock
                // counts up.
                Text(verbatim: text).monospacedDigit()
            }
        }
        .accessibilityLabel(activity.accessibilityLabel)
    }
}

/// What drops down from the menu bar item.
///
/// Deliberately small. It says what is happening and offers the one or two things worth doing
/// without going to the window — stopping is the point, since the reason to look up there is
/// usually "is this still running, and can I stop it".
struct MenuBarStatusMenu: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let activity = state.activity

        Text(activity.title)

        Divider()

        switch activity {
        case .recording:
            Button("Finish Recording") { Task { await state.finishRecording() } }
            Button("Pause") { state.recording.pause() }
        case .paused:
            Button("Finish Recording") { Task { await state.finishRecording() } }
            Button("Resume") { state.recording.resume() }
        case .transcribing:
            Button("Stop") { state.stopQueue() }
        case .finalizing, .idle:
            EmptyView()
        }

        if state.queue.pendingCount > 0 {
            Text("\(state.queue.pendingCount) waiting")
        }

        Divider()

        Button("Open Whisper Transcriber") { activate() }
        Button("Recordings") { openWindow(id: "recordings") }
    }

    /// The main window may be closed or behind something; bringing the app forward is what
    /// "open" means here.
    private func activate() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }
}
