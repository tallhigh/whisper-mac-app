import Foundation

/// A preset the user saved themselves.
///
/// The built-in presets (`WhisperSettings.builtInPresets`) are constants in the code;
/// these live on disk in `presets.json` and can be deleted.
struct StoredPreset: Codable, Identifiable, Equatable, Sendable {
    var name: String
    var settings: WhisperSettings

    var id: String { name }

    /// The summary shown under the name in the menu — like a built-in preset's `detail`.
    var detail: String {
        var parts = [name.isEmpty ? "" : settings.model]
        if let language = settings.language {
            parts.append(language)
        } else {
            parts.append(String(localized: "automatic"))
        }
        let formats = OutputFormat.allCases
            .filter(settings.outputFormats.contains)
            .map(\.rawValue)
        parts.append(formats.joined(separator: " + "))
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Reading and writing `presets.json`.
///
/// A corrupt or hand-edited file must not take the app down at launch: a file that won't
/// decode counts as an empty list and is **not overwritten** — it is written on the first
/// save, so the user doesn't lose the chance to recover it.
enum PresetStore {

    static func load(from url: URL) -> [StoredPreset] {
        guard
            let data = try? Data(contentsOf: url),
            let presets = try? JSONDecoder().decode([StoredPreset].self, from: data)
        else {
            return []
        }
        return presets
    }

    @discardableResult
    static func save(_ presets: [StoredPreset], to url: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(presets) else { return false }

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// A preset of the same name is **replaced**; the list is kept sorted by name.
    static func upsert(_ preset: StoredPreset, into presets: [StoredPreset]) -> [StoredPreset] {
        var result = presets.filter { $0.name != preset.name }
        result.append(preset)
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
