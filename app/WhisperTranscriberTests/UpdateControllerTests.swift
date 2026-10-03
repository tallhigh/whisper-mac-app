import Foundation
import Testing

@testable import WhisperTranscriber

@Suite("Update checking")
@MainActor
struct UpdateControllerTests {

    /// A bundle stand-in: `Bundle` reads Info.plist, so the only way to test the decision is
    /// to feed it the dictionary.
    private final class StubBundle: Bundle {
        let values: [String: Any]
        init(values: [String: Any]) {
            self.values = values
            super.init()
        }
        override func object(forInfoDictionaryKey key: String) -> Any? { values[key] }
    }

    /// A Debug build carries no feed URL. Everything has to stay inert rather than crash or
    /// start a network request.
    @Test("Without a feed URL the controller is inert")
    func unconfiguredWithoutFeed() {
        let controller = UpdateController(bundle: StubBundle(values: [:]), enabled: true)

        #expect(!controller.isConfigured)
        #expect(!controller.canCheckForUpdates)
        #expect(controller.lastCheckDate == nil)
        #expect(!controller.automaticallyChecks)
        // Must not throw or trap; there is simply nothing to check.
        controller.checkForUpdates()
    }

    @Test("An empty feed URL counts as no feed URL")
    func emptyFeedIsUnconfigured() {
        let controller = UpdateController(bundle: StubBundle(values: ["SUFeedURL": ""]), enabled: true)
        #expect(!controller.isConfigured)
    }

    /// Sparkle asks the user for permission and schedules a request as soon as it starts, so
    /// a test run must never bring it up.
    @Test("Disabled explicitly, a real feed URL still starts nothing")
    func disabledIgnoresFeed() {
        let bundle = StubBundle(values: ["SUFeedURL": "https://example.invalid/appcast.xml"])
        let controller = UpdateController(bundle: bundle, enabled: false)

        #expect(!controller.isConfigured)
        #expect(!controller.canCheckForUpdates)
    }

    /// The guard that keeps the suite above honest: the default initialiser is the one the app
    /// uses, and under the test runner it has to come back inert.
    @Test("The default initialiser is inert under the test runner")
    func defaultIsInertInTests() {
        #expect(AppEnvironment.isRunningTests)
        #expect(!UpdateController().isConfigured)
    }

    /// The shipped bundle must carry both keys, or updates silently never happen. Reads the
    /// values the build produced rather than the source of project.yml.
    @Test("The app bundle carries a feed URL and a public key")
    func bundleIsConfiguredForRelease() throws {
        let bundle = Bundle(for: AppState.self)
        let feed = try #require(bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String)
        let key = try #require(bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)

        #expect(feed.hasPrefix("https://"))
        #expect(feed.hasSuffix("appcast.xml"))
        // An EdDSA public key is 32 bytes, base64 — 44 characters with its padding.
        #expect(key.count == 44, "SUPublicEDKey does not look like a base64 Ed25519 key")
        #expect(Data(base64Encoded: key)?.count == 32)
    }
}
