import Foundation

/// Deleting a downloaded whisper model from the model folder.
///
/// That folder belongs to the user rather than to the app (ADR-005), and it routinely holds
/// several gigabytes that would take a long time to download again, so the rules here are
/// deliberately narrow (ADR-017):
///
/// - one model at a time, by explicit request, never a sweep;
/// - the name has to be one the **worker** reported, so a value from anywhere else cannot
///   reach `removeItem`;
/// - only a regular file called `<model>.pt` is removed — never a directory, and never the
///   model folder itself.
enum ModelStore {

    enum DeleteError: LocalizedError, Equatable {
        /// The name is not in the list the worker reported, or could not be a file name.
        case unknownModel(String)
        case notDownloaded(String)
        /// The path exists but is not a regular file; we refuse rather than delete a tree.
        case notAFile(String)
        case removeFailed(String)

        var errorDescription: String? {
            switch self {
            case .unknownModel(let model):
                String(localized: "\(model) is not a known model.")
            case .notDownloaded(let model):
                String(localized: "\(model) is not downloaded.")
            case .notAFile(let model):
                String(localized: "The \(model) entry in the model folder is not a file.")
            case .removeFailed(let detail):
                String(localized: "The model could not be deleted: \(detail)")
            }
        }
    }

    /// whisper stores each model as `<name>.pt` directly in the model folder.
    static let fileExtension = "pt"

    /// A model name is allowed to be a file name and nothing more. whisper's own names are
    /// plain (`small`, `large-v3-turbo`), so anything with a separator, a traversal or a
    /// leading dot in it did not come from the worker and is refused.
    static func isSafeName(_ model: String) -> Bool {
        guard !model.isEmpty, !model.hasPrefix("."), model.count <= 64 else { return false }
        let forbidden = CharacterSet(charactersIn: "/:\\").union(.whitespacesAndNewlines)
        return model.rangeOfCharacter(from: forbidden) == nil
    }

    /// The file a model would occupy, or `nil` when the name could not be a file name.
    static func fileURL(for model: String, in directory: URL) -> URL? {
        guard isSafeName(model) else { return nil }
        return directory.appending(path: "\(model).\(fileExtension)")
    }

    /// Deletes one downloaded model and returns the file that went away.
    ///
    /// - Parameter known: the model list the worker reported. The check against it is what
    ///   keeps this from being a general-purpose delete.
    @discardableResult
    static func delete(
        _ model: String,
        in directory: URL,
        known: [String],
        fileManager: FileManager = .default
    ) throws -> URL {
        guard known.contains(model), let url = fileURL(for: model, in: directory) else {
            throw DeleteError.unknownModel(model)
        }

        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        guard let isRegularFile = values?.isRegularFile else {
            throw DeleteError.notDownloaded(model)
        }
        guard isRegularFile else {
            throw DeleteError.notAFile(model)
        }

        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw DeleteError.removeFailed(error.localizedDescription)
        }
        return url
    }
}
