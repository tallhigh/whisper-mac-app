import SwiftUI

/// Shows the setup screen when the runtime isn't ready, and the main window when it is.
struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        switch state.runtime {
        case .unknown, .checking:
            ProgressView("Checking the runtime…")
                .frame(minWidth: 560, minHeight: 440)
        case .ready:
            MainView()
        case .notInstalled, .installing, .broken:
            SetupView()
        }
    }
}
