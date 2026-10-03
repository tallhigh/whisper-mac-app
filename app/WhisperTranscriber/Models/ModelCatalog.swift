import Foundation

/// Splits whisper's flat model list into the two axes it actually has.
///
/// `whisper.available_models()` returns one list mixing two independent things:
///
/// ```
/// tiny.en  tiny  base.en  base  small.en  small  medium.en  medium
/// large-v1  large-v2  large-v3  large  large-v3-turbo  turbo
/// ```
///
/// A **size** (`small`, `medium`, `large-v3`…) and a **language variant** (`.en` means the
/// English-only weights). Choosing `small.en` for Turkish audio is a mistake the flat list
/// invites, so the interface offers the two separately and composes the name back.
///
/// The split is mechanical — a trailing `.en`, nothing more — so a model a later whisper
/// version adds is categorised without a code change. Nothing here is hard-coded; the input
/// is always the list the worker reported.
enum ModelCatalog {

    /// Which weights a size is available in.
    enum Variant: String, Codable, CaseIterable, Identifiable, Sendable {
        /// The multilingual weights — the plain name.
        case multilingual
        /// The English-only weights — the `.en` suffix.
        case english

        var id: String { rawValue }

        var suffix: String { self == .english ? Self.englishSuffix : "" }

        static let englishSuffix = ".en"

        var title: String {
            switch self {
            case .multilingual: String(localized: "All languages")
            case .english: String(localized: "English only")
            }
        }
    }

    /// The size part of a model name: the name with any `.en` removed.
    static func size(of model: String) -> String {
        model.hasSuffix(Variant.englishSuffix)
            ? String(model.dropLast(Variant.englishSuffix.count))
            : model
    }

    static func variant(of model: String) -> Variant {
        model.hasSuffix(Variant.englishSuffix) ? .english : .multilingual
    }

    /// The model name for a size and a variant — the inverse of the two accessors above.
    static func name(size: String, variant: Variant) -> String {
        size + variant.suffix
    }

    /// The sizes in `models`, in the order the worker listed them and without duplicates.
    ///
    /// The worker's order is kept rather than sorted: it runs smallest to largest, which is
    /// the order a picker wants, and sorting alphabetically would put `large` before `small`.
    static func sizes(in models: [String]) -> [String] {
        var seen = Set<String>()
        return models.compactMap { model in
            let size = size(of: model)
            return seen.insert(size).inserted ? size : nil
        }
    }

    /// The variants a size exists in, `.multilingual` first. The large models have no `.en`
    /// counterpart, so this is often a single entry.
    static func variants(for size: String, in models: [String]) -> [Variant] {
        Variant.allCases.filter { models.contains(name(size: size, variant: $0)) }
    }

    /// Resolves a size and a desired variant to a model that actually exists.
    ///
    /// Used when the size changes and the variant in effect has no counterpart: moving from
    /// `small` + English-only to `large-v3` must land on `large-v3` rather than on the
    /// non-existent `large-v3.en`.
    static func resolve(size: String, variant: Variant, in models: [String]) -> String {
        let wanted = name(size: size, variant: variant)
        if models.contains(wanted) { return wanted }
        let fallback = name(size: size, variant: .multilingual)
        return models.contains(fallback) ? fallback : size
    }
}
