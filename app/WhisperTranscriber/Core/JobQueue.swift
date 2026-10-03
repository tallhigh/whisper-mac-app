import Foundation
import Observation

/// Processes files **sequentially**.
///
/// We don't run them in parallel: a single whisper model already saturates the CPU cores
/// and, with the large models, several GB of RAM (ADR-008).
///
/// The queue is `@MainActor` because the `TranscriptionItem` objects it owns are read
/// directly by the views. The heavy work is already in the `PythonWhisperEngine` actor and
/// in a separate process; all that happens here is coordination.
@MainActor
@Observable
final class JobQueue {

    private(set) var items: [TranscriptionItem] = []
    private(set) var isRunning = false
    private(set) var activeItemID: TranscriptionItem.ID?

    /// What to tell the user when an unsupported file is dropped.
    var lastRejection: Rejection?

    /// Called when the queue empties (to release the sleep assertion, to notify).
    var onFinish: (@MainActor () -> Void)?
    /// Called for each job that completes, so the history can record it — ADR-024.
    var onItemCompleted: (@MainActor (TranscriptionItem) -> Void)?

    private let engine: any TranscriptionEngine
    private var runTask: Task<Void, Never>?

    struct Rejection: Identifiable, Equatable {
        let id = UUID()
        var count: Int
        var firstName: String
    }

    init(engine: any TranscriptionEngine) {
        self.engine = engine
    }

    // MARK: - Queue management

    /// Adds files to the queue. A file already waiting is not added again.
    @discardableResult
    func enqueue(_ urls: [URL], settings: WhisperSettings) -> Int {
        let (accepted, rejected) = SupportedMedia.collect(from: urls)

        if let first = rejected.first {
            lastRejection = Rejection(count: rejected.count, firstName: first.lastPathComponent)
        }

        let pending = Set(
            items.filter { !$0.state.isFinished }.map(\.url.standardizedFileURL)
        )
        let fresh = accepted.filter { !pending.contains($0.standardizedFileURL) }

        items.append(contentsOf: fresh.map { TranscriptionItem(url: $0, settings: settings) })
        return fresh.count
    }

    func remove(_ item: TranscriptionItem) {
        guard item.id != activeItemID else { return }
        items.removeAll { $0.id == item.id }
    }

    func clearFinished() {
        items.removeAll { $0.state.isFinished }
    }

    func retry(_ item: TranscriptionItem, settings: WhisperSettings) {
        item.requeue(with: settings)
        if !isRunning { start() }
    }

    /// Only waiting jobs can be moved; a running or finished job stays put.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
    }

    var pendingCount: Int { items.count { $0.state == .queued } }
    var hasPending: Bool { pendingCount > 0 }

    // MARK: - Running

    func start() {
        guard runTask == nil, hasPending else { return }
        isRunning = true

        runTask = Task { [weak self] in
            await self?.drain()
            guard let self else { return }
            isRunning = false
            activeItemID = nil
            runTask = nil
            onFinish?()
        }
    }

    /// Cancels the running job and stops the queue. Waiting jobs stay in it.
    func stop() {
        runTask?.cancel()
        runTask = nil
        isRunning = false

        // Immediate feedback for the user: we don't wait for the process to die.
        if let active = items.first(where: { $0.id == activeItemID }) {
            active.markCancelled()
        }
        activeItemID = nil
    }

    private func drain() async {
        while let next = items.first(where: { $0.state == .queued }) {
            if Task.isCancelled { return }

            activeItemID = next.id
            next.markRunning()
            await process(next)

            if Task.isCancelled { return }
        }
    }

    private func process(_ item: TranscriptionItem) async {
        await attempt(item)

        // MPS is experimental (ADR-012): on failure, rather than losing the job we drop
        // to CPU and try once more. On the second attempt the device is already `cpu`,
        // so this condition can't be met again — no infinite loop.
        guard item.state == .failed, item.settings.device == .mps, !Task.isCancelled else { return }
        item.fallBackToCPU()
        await attempt(item)
    }

    private func attempt(_ item: TranscriptionItem) async {
        let job = item.settings.jobPayload(for: item.url, jobID: item.id.uuidString)

        do {
            try await engine.transcribe(job) { [weak item] event in
                Task { @MainActor in item?.apply(event) }
            }
            // Events are applied in separate Tasks, so wait for the last ones to land.
            await Task.yield()
            item.markCompleted()
            onItemCompleted?(item)
        } catch is CancellationError {
            item.markCancelled()
        } catch let failure as EngineEvent.EngineFailure {
            if failure.code == .cancelled {
                item.markCancelled()
            } else {
                item.markFailed(
                    message: failure.message,
                    detail: failure.detail ?? "",
                    suggestion: failure.code.suggestion
                )
            }
        } catch let error as EngineError {
            item.markFailed(
                message: error.errorDescription ?? String(localized: "The transcription failed."),
                detail: error.detail
            )
        } catch {
            item.markFailed(
                message: String(localized: "The transcription failed."), detail: error.localizedDescription)
        }
    }
}
