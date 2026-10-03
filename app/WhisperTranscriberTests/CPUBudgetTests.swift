import Foundation
import Testing

@testable import WhisperTranscriber

@Suite("CPU budget")
struct CPUBudgetTests {

    @Test("Full speed sends no thread limit at all")
    func fullIsUnlimited() {
        #expect(CPUBudget.full.threads == 0)
        #expect(CPUBudget.full.threadEnvironment.isEmpty)
        #expect(CPUBudget.full.qualityOfService == .userInitiated)
    }

    /// The point of the setting: fewer threads than the machine has fast cores.
    @Test("The limited budgets stay under the performance-core count")
    func limitedBudgetsLeaveHeadroom() {
        let cores = MachineCapacity.performanceCores
        #expect(cores >= 1)
        #expect(CPUBudget.balanced.threads < cores || cores == 1)
        #expect(CPUBudget.light.threads <= CPUBudget.balanced.threads)
        for budget in [CPUBudget.balanced, .light] {
            #expect(budget.threads >= 1, "\(budget.rawValue) must still run")
        }
    }

    @Test("A lower budget asks the scheduler for a lower priority")
    func qualityOfServiceDescends() {
        #expect(CPUBudget.balanced.qualityOfService == .utility)
        #expect(CPUBudget.light.qualityOfService == .background)
    }

    /// The pools size themselves when torch is imported, which is before the worker reads
    /// the job, so the limit has to be in the environment as well.
    @Test("A limited budget exports the thread count to the environment")
    func exportsThreadEnvironment() {
        let environment = CPUBudget.light.threadEnvironment
        let expected = String(CPUBudget.light.threads)
        #expect(environment["OMP_NUM_THREADS"] == expected)
        #expect(environment["MKL_NUM_THREADS"] == expected)
        #expect(environment["VECLIB_MAXIMUM_THREADS"] == expected)
        #expect(ProcessRunner.baseEnvironment(extra: environment)["OMP_NUM_THREADS"] == expected)
    }

    @Test("Every budget has a title and an explanation")
    func descriptions() {
        for budget in CPUBudget.allCases {
            #expect(!budget.title.isEmpty)
            #expect(!budget.detail.isEmpty)
        }
    }

    @Test("The machine reports at least one core and some memory")
    func machineCapacity() {
        #expect(MachineCapacity.performanceCores >= 1)
        #expect(MachineCapacity.physicalMemory > 0)
    }
}

@Suite("The budget in the job definition")
struct CPUBudgetJobTests {

    private let audio = URL(filePath: "/Users/t/Desktop/recordings/mehmet.m4a")

    @Test("A limited budget travels as options.threads")
    func sendsThreads() throws {
        var settings = WhisperSettings()
        settings.cpuBudget = .light
        let json = try settings.jobPayload(for: audio, jobID: "t").jsonLine()

        #expect(json.contains("\"threads\":\(CPUBudget.light.threads)"))
    }

    /// 0 would be a value, and the protocol distinguishes "no key" from a value: with no key
    /// the worker leaves torch's own default alone.
    @Test("Full speed omits the key rather than sending a zero")
    func omitsThreadsAtFullSpeed() throws {
        var settings = WhisperSettings()
        settings.cpuBudget = .full
        let json = try settings.jobPayload(for: audio, jobID: "t").jsonLine()

        #expect(!json.contains("threads"))
    }

    /// The quality of service is a local spawning concern; the worker has no say in it, so
    /// it must not appear in the protocol.
    @Test("The budget itself is not part of the JSON")
    func budgetIsNotEncoded() throws {
        for budget in CPUBudget.allCases {
            var settings = WhisperSettings()
            settings.cpuBudget = budget
            let json = try settings.jobPayload(for: audio, jobID: "t").jsonLine()
            #expect(!json.contains("cpu_budget"))
            #expect(!json.contains("cpuBudget"))
            #expect(!json.contains(budget.rawValue))
        }
    }

    @Test("The job carries the budget to the engine")
    func jobCarriesBudget() {
        var settings = WhisperSettings()
        settings.cpuBudget = .light
        #expect(settings.jobPayload(for: audio, jobID: "t").cpuBudget == .light)
    }

    @Test("The budget survives the settings coding round trip")
    func survivesRoundTrip() throws {
        var settings = WhisperSettings()
        settings.cpuBudget = .light
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(WhisperSettings.self, from: data).cpuBudget == .light)
    }
}

@Suite("Memory estimate for a model")
struct ModelMemoryTests {

    private func capabilities(bytes: [String: Int]) -> EngineCapabilities {
        EngineCapabilities(
            models: Array(bytes.keys),
            modelsCached: Array(bytes.keys),
            modelsBytes: bytes,
            modelDir: "/tmp/models",
            languages: [],
            outputFormats: ["txt"],
            tasks: ["transcribe"],
            devices: ["cpu"]
        )
    }

    /// The estimate is fitted to measurements taken with the real models (ADR-018); these
    /// are the three it was fitted to, so it has to land near them.
    @Test("The estimate matches what the real models measured")
    func matchesMeasurements() throws {
        let measured: [(model: String, fileBytes: Int, peakGB: Double)] = [
            ("small", 461 * 1_000_000, 2.10),
            ("medium", 1_400 * 1_000_000, 4.38),
            ("large-v3-turbo", 1_500 * 1_000_000, 4.64),
        ]
        let capabilities = capabilities(
            bytes: Dictionary(uniqueKeysWithValues: measured.map { ($0.model, $0.fileBytes) }))

        for case let (model, _, expectedGB) in measured {
            let estimate = try #require(capabilities.estimatedPeakBytes(for: model))
            let estimateGB = Double(estimate) / 1_000_000_000
            #expect(
                abs(estimateGB - expectedGB) < 0.35,
                "\(model): estimated \(estimateGB) GB against \(expectedGB) GB measured")
        }
    }

    @Test("A model that is not downloaded has no estimate")
    func noEstimateWithoutSize() {
        let capabilities = capabilities(bytes: [:])
        #expect(capabilities.estimatedPeakBytes(for: "medium") == nil)
    }

    @Test("A heavy model warns, a light one does not")
    func warnsWhenHeavy() {
        // Anchored to the machine running the test: half its memory is the threshold, so the
        // test says the same thing on an 8 GB Mac and on a 64 GB one.
        let half = MachineCapacity.physicalMemory / 2
        let heavyFile = Int(Double(half)) // 2.5x this lands well over the threshold
        let lightFile = 1_000
        let capabilities = capabilities(bytes: ["heavy": heavyFile, "light": lightFile])

        var settings = WhisperSettings()
        settings.model = "heavy"
        #expect(settings.warnings(capabilities: capabilities).contains { $0.symbol == "memorychip" })

        settings.model = "light"
        #expect(!settings.warnings(capabilities: capabilities).contains { $0.symbol == "memorychip" })
    }
}
