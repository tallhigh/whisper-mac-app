import Foundation

/// The capabilities the worker reports — read at runtime, never hard-coded.
///
/// When the whisper version is upgraded, new models and languages appear in the interface
/// by themselves; no code change is needed.
struct EngineCapabilities: Decodable, Equatable, Sendable {
    var models: [String]
    var modelsCached: [String]
    /// The on-disk size of the downloaded models. Models not downloaded are absent here —
    /// whisper doesn't report the size before downloading (see `docs/PROTOCOL.md`).
    var modelsBytes: [String: Int]?
    var modelDir: String?
    var languages: [Language]
    var outputFormats: [String]
    var tasks: [String]
    var devices: [String]

    struct Language: Decodable, Equatable, Sendable, Identifiable, Hashable {
        /// The ISO code — this is what goes to the worker ("tr").
        var code: String
        /// whisper's English name ("turkish").
        var name: String

        var id: String { code }
    }

    enum CodingKeys: String, CodingKey {
        case models
        case modelsCached = "models_cached"
        case modelsBytes = "models_bytes"
        case modelDir = "model_dir"
        case languages
        case outputFormats = "output_formats"
        case tasks
        case devices
    }

    func isCached(_ model: String) -> Bool {
        modelsCached.contains(model)
    }

    /// `"483,6 MB"` — `nil` if the model hasn't been downloaded.
    func sizeLabel(for model: String) -> String? {
        guard let bytes = modelsBytes?[model] else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// The total space every cached model occupies.
    var cachedBytes: Int {
        modelsBytes?.values.reduce(0, +) ?? 0
    }

    var supportsMPS: Bool { devices.contains("mps") }

    /// The language list to show in the interface: "detect automatically" first, then the
    /// languages alphabetically, under their display names.
    var sortedLanguages: [Language] {
        languages.sorted {
            LanguageNames.display(for: $0).localizedCaseInsensitiveCompare(
                LanguageNames.display(for: $1)
            ) == .orderedAscending
        }
    }
}

/// The language names shown in the interface.
///
/// whisper gives lowercase English names ("turkish"). The name is asked of `Locale` in the
/// app's own UI language, so it follows the interface rather than the system region; if
/// `Locale` doesn't know the code, whisper's own name is capitalised.
enum LanguageNames {
    private static let uiLocale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")

    static func display(for language: EngineCapabilities.Language) -> String {
        if let localized = uiLocale.localizedString(forLanguageCode: language.code) {
            return localized.prefix(1).localizedUppercase + localized.dropFirst()
        }
        return language.name.prefix(1).localizedUppercase + language.name.dropFirst()
    }
}
