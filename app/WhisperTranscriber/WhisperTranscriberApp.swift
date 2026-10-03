import AppKit
import SwiftUI

@main
struct WhisperTranscriberApp: App {
    @State private var state = AppState()
    @State private var updates = UpdateController()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(state)
                .environment(updates)
                .task {
                    delegate.state = state
                    // In the unit tests the app is launched as a "test host". Probing the
                    // Python environment there would slow the tests down and tie them to
                    // the installation on the user's machine.
                    guard !AppEnvironment.isRunningTests else { return }
                    await state.refreshRuntimeState()
                    delegate.drainPendingOpens()
                }
        }
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            // Where macOS users look for it: the app menu, under About.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updates.checkForUpdates() }
                    .disabled(!updates.canCheckForUpdates)
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Files…") { state.openFilePanel() }
                    .keyboardShortcut("o")
            }
            CommandMenu("Transcription") {
                Button("Record Audio…") { state.presentRecording() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(state.recording.isRecording)
                Divider()
                Button("Start") { state.startQueue() }
                    .keyboardShortcut("r")
                    .disabled(state.queue.isRunning || !state.queue.hasPending)
                Button("Stop") { state.stopQueue() }
                    .keyboardShortcut(".")
                    .disabled(!state.queue.isRunning)
                Divider()
                Button("Clear Completed") { state.queue.clearFinished() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .disabled(!state.queue.items.contains { $0.state.isFinished })
                Divider()
                RecordingsMenuItem()
            }
        }

        // The recordings already on disk — ADR-021. A window rather than a pane: the queue
        // is what is running now, this is what happened before.
        Window("Recordings", id: "recordings") {
            RecordingsView()
                .environment(state)
        }
        .defaultSize(width: 560, height: 420)

        // ⌘, — the app's behaviour, the model cache and the runtime.
        Settings {
            PreferencesWindow()
                .environment(state)
                .environment(updates)
        }
    }
}

/// The menu entry for the recordings window.
///
/// A `View` rather than a bare `Button` in the menu, because `openWindow` comes from the
/// environment and the environment is only reachable from inside a view.
private struct RecordingsMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Recordings") { openWindow(id: "recordings") }
            .keyboardShortcut("l", modifiers: [.command, .shift])
    }
}

enum AppEnvironment {
    /// Are we running under XCTest / Swift Testing?
    static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

/// Receives the files that arrive via "Open With" in Finder and dragging onto the Dock.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    var state: AppState?

    /// Files arriving while the app isn't ready yet wait here.
    private var pending: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let state else {
            pending.append(contentsOf: urls)
            return
        }
        state.addFiles(urls)
    }

    func drainPendingOpens() {
        guard let state, !pending.isEmpty else { return }
        state.addFiles(pending)
        pending.removeAll()
    }

    /// Ask the user for confirmation when they try to quit while the queue is running.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state, state.queue.isRunning else { return .terminateNow }
        guard state.preferences.confirmOnQuit else {
            state.stopQueue()
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = String(localized: "A transcription is running")
        alert.informativeText = String(localized: "If you quit, the running job will be cancelled.")
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.alertStyle = .warning

        if alert.runModal() == .alertFirstButtonReturn {
            state.stopQueue()
            return .terminateNow
        }
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Let a running job carry on even if the window is closed (docs/UI_SPEC.md).
        state?.queue.isRunning == false
    }
}
