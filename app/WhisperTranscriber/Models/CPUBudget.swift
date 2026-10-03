import Foundation

/// How much of the machine a transcription is allowed to take — `docs/DECISIONS.md` → ADR-018.
///
/// Two levers, applied together:
///
/// - **Threads.** Sent as `options.threads`, which the worker hands to
///   `torch.set_num_threads()` and to ffmpeg. Thread count does **not** change the
///   transcript: the same fixture produced a byte-identical `.txt` at 2, 3, 4 and unlimited
///   threads, so CLI equivalence is unaffected (`ADR-018`).
/// - **Quality of service.** Set on the child process. `.utility` and `.background` tell the
///   macOS scheduler the work can wait, which on Apple Silicon also biases it towards the
///   efficiency cores — this, not the thread count, is what keeps the interface smooth.
enum CPUBudget: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Whatever torch picks, at the app's own priority.
    case full
    /// One performance core left free, at utility priority. The default.
    case balanced
    /// Half the performance cores, at background priority.
    case light

    var id: String { rawValue }

    /// The thread count to send, or `0` to leave torch's own default alone.
    ///
    /// Derived from the performance cores rather than from all of them: torch already
    /// defaults to the performance-core count on Apple Silicon, so counting the efficiency
    /// cores in would oversubscribe.
    var threads: Int {
        let cores = MachineCapacity.performanceCores
        switch self {
        case .full: return 0
        case .balanced: return max(1, cores - 1)
        case .light: return max(1, cores / 2)
        }
    }

    /// The thread limit as environment variables, for the pools that size themselves when
    /// torch is imported — before the worker has read the job. Empty for `.full`.
    var threadEnvironment: [String: String] {
        let count = threads
        guard count > 0 else { return [:] }
        let value = String(count)
        return [
            "OMP_NUM_THREADS": value,
            "MKL_NUM_THREADS": value,
            "VECLIB_MAXIMUM_THREADS": value,
            "NUMEXPR_NUM_THREADS": value,
        ]
    }

    var qualityOfService: QualityOfService {
        switch self {
        case .full: .userInitiated
        case .balanced: .utility
        case .light: .background
        }
    }

    var title: String {
        switch self {
        case .full: String(localized: "Full speed")
        case .balanced: String(localized: "Leave the Mac usable")
        case .light: String(localized: "Background")
        }
    }

    /// The one-line explanation under the picker. The measured cost is in ADR-018.
    var detail: String {
        switch self {
        case .full:
            String(localized: "Every core, same priority as the app. Fastest, and you will feel it.")
        case .balanced:
            String(
                localized:
                    "\(threads) of \(MachineCapacity.performanceCores) fast cores, at a lower priority. About 5% slower."
            )
        case .light:
            String(
                localized:
                    "\(threads) threads on the efficiency cores. Clearly slower, and barely noticeable while it runs."
            )
        }
    }
}

/// What the machine actually has, read from `sysctl` rather than assumed.
enum MachineCapacity {

    /// The performance ("P") cores. Falls back to half the active cores when the key is
    /// missing, which is the case on Intel and would be the case on an unfamiliar layout.
    static var performanceCores: Int {
        if let value = sysctlInt("hw.perflevel0.physicalcpu"), value > 0 {
            return value
        }
        return max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
    }

    static var physicalMemory: Int64 {
        Int64(ProcessInfo.processInfo.physicalMemory)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}
