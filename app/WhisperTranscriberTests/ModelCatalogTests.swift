import Foundation
import Testing

@testable import WhisperTranscriber

@Suite("Splitting the model list into size and language")
struct ModelCatalogTests {

    /// The real list, in the order `whisper.available_models()` returns it.
    private let models = [
        "tiny.en", "tiny", "base.en", "base", "small.en", "small", "medium.en", "medium",
        "large-v1", "large-v2", "large-v3", "large", "large-v3-turbo", "turbo",
    ]

    @Test("A name splits into a size and a variant")
    func splitsNames() {
        #expect(ModelCatalog.size(of: "small.en") == "small")
        #expect(ModelCatalog.variant(of: "small.en") == .english)
        #expect(ModelCatalog.size(of: "small") == "small")
        #expect(ModelCatalog.variant(of: "small") == .multilingual)
        #expect(ModelCatalog.size(of: "large-v3-turbo") == "large-v3-turbo")
        #expect(ModelCatalog.variant(of: "large-v3-turbo") == .multilingual)
    }

    @Test("Composing is the inverse of splitting")
    func composeRoundTrips() {
        for model in models {
            let size = ModelCatalog.size(of: model)
            let variant = ModelCatalog.variant(of: model)
            #expect(ModelCatalog.name(size: size, variant: variant) == model)
        }
    }

    /// Sorting would put `large` before `small`; the worker already lists them smallest
    /// first, so that order is kept.
    @Test("The sizes are deduplicated and keep the worker's order")
    func sizesKeepOrder() {
        #expect(
            ModelCatalog.sizes(in: models) == [
                "tiny", "base", "small", "medium",
                "large-v1", "large-v2", "large-v3", "large", "large-v3-turbo", "turbo",
            ])
    }

    @Test("Only the sizes that have English weights offer the choice")
    func variantsPerSize() {
        for size in ["tiny", "base", "small", "medium"] {
            #expect(
                ModelCatalog.variants(for: size, in: models) == [.multilingual, .english],
                "\(size) has an .en build")
        }
        for size in ["large-v3", "large-v3-turbo", "turbo", "large"] {
            #expect(
                ModelCatalog.variants(for: size, in: models) == [.multilingual],
                "\(size) has no .en build")
        }
    }

    /// The trap the split exists to avoid: `large-v3.en` is not a model, so moving to a large
    /// size while English-only is selected must not compose a name that cannot be loaded.
    @Test("Changing size falls back when the variant does not exist")
    func resolveFallsBack() {
        #expect(
            ModelCatalog.resolve(size: "large-v3", variant: .english, in: models) == "large-v3")
        #expect(ModelCatalog.resolve(size: "small", variant: .english, in: models) == "small.en")
        #expect(ModelCatalog.resolve(size: "small", variant: .multilingual, in: models) == "small")
    }

    @Test("Every resolved name is one the worker actually reported")
    func resolveAlwaysProducesARealModel() {
        for size in ModelCatalog.sizes(in: models) {
            for variant in ModelCatalog.Variant.allCases {
                let resolved = ModelCatalog.resolve(size: size, variant: variant, in: models)
                #expect(models.contains(resolved), "\(size) + \(variant.rawValue) → \(resolved)")
            }
        }
    }

    /// A model a later whisper version adds has to be categorised without a code change.
    @Test("An unknown future model is categorised by its shape alone")
    func handlesUnknownModels() {
        let future = ["huge-v9.en", "huge-v9"]
        #expect(ModelCatalog.sizes(in: future) == ["huge-v9"])
        #expect(ModelCatalog.variants(for: "huge-v9", in: future) == [.multilingual, .english])
        #expect(ModelCatalog.resolve(size: "huge-v9", variant: .english, in: future) == "huge-v9.en")
    }

    @Test("An empty list degrades without crashing")
    func handlesEmptyList() {
        #expect(ModelCatalog.sizes(in: []).isEmpty)
        #expect(ModelCatalog.variants(for: "small", in: []).isEmpty)
        // Nothing to resolve against: the size itself is the least surprising answer.
        #expect(ModelCatalog.resolve(size: "small", variant: .english, in: []) == "small")
    }

    @Test("Both variants have a title")
    func variantTitles() {
        for variant in ModelCatalog.Variant.allCases {
            #expect(!variant.title.isEmpty)
        }
    }
}
