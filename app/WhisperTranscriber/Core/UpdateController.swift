import Foundation
import Observation
import Sparkle

/// The app's only contact with Sparkle — `docs/DECISIONS.md` → ADR-020.
///
/// Sparkle is wrapped rather than used directly from the views for the same reason the
/// engine is behind a protocol: the rest of the app asks "is there an update?" and should
/// not know which framework answers. It is also the one place that knows an update can be
/// unavailable, which is the normal case for a Debug build.
///
/// What Sparkle does that this deliberately does not reimplement: verifying the EdDSA
/// signature against `SUPublicEDKey`, checking the new bundle is signed by the same team,
/// and replacing a *running* application — which an app cannot do to itself, and which is
/// why Sparkle ships a helper to do it from outside.
@MainActor
@Observable
final class UpdateController {

    /// `false` when the bundle carries no feed URL, which is the case for a Debug build run
    /// straight out of Xcode. Everything below is then inert rather than failing.
    let isConfigured: Bool

    /// Mirrors Sparkle's own flag so the menu item can be disabled while a check is running.
    private(set) var canCheckForUpdates = false

    /// Whether to look in the background on a schedule. Changing it takes effect at once;
    /// Sparkle stores the answer in the defaults itself.
    var automaticallyChecks: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    var lastCheckDate: Date? { updater?.lastUpdateCheckDate }

    private let controller: SPUStandardUpdaterController?
    private var observation: NSKeyValueObservation?

    private var updater: SPUUpdater? { controller?.updater }

    /// - Parameter enabled: pass `false` to build an inert controller. The default refuses to
    ///   start under the test runner: Sparkle would otherwise ask the user for permission to
    ///   check for updates and schedule a network request in the middle of a test run.
    init(bundle: Bundle = .main, enabled: Bool = !AppEnvironment.isRunningTests) {
        let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String
        isConfigured = enabled && !(feed ?? "").isEmpty

        guard isConfigured else {
            controller = nil
            return
        }

        // `startingUpdater: true` lets Sparkle do its own first-launch permission prompt
        // rather than us inventing one. No delegate: the standard user interface is the
        // behaviour we want, and a delegate would only be a place for bugs to live.
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        canCheckForUpdates = controller?.updater.canCheckForUpdates ?? false

        // Sparkle publishes this as KVO rather than as a callback.
        observation = controller?.updater.observe(\.canCheckForUpdates, options: [.new]) {
            [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
    }

    /// Checks now and shows Sparkle's own window if something is found.
    ///
    /// Used by the menu item, so it reports "you are up to date" as well — unlike the
    /// scheduled check, which stays quiet when there is nothing to say.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
