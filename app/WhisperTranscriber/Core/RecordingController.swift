import Foundation
import Observation

/// The recording session's state machine — `docs/LIVE_TRANSCRIPTION.md` → Interface.
///
/// It talks to the capture layer through `AudioCapturing`; the tests run against a fake
/// implementation without touching the microphone.
///
/// With live transcription on, text flows through `LiveSession` as well; when the recording
/// ends, the file enters the existing queue as an ordinary job either way.
@MainActor
@Observable
final class RecordingController {

    private(set) var state: RecordingState = .idle
    /// 0...1 — the level meter.
    private(set) var level: Float = 0
    /// The duration of audio written; paused time doesn't count.
    private(set) var duration: TimeInterval = 0
    /// The file the recording is written to; visible while recording too.
    private(set) var fileURL: URL?
    private(set) var failure: Failure?

    // MARK: - Live text

    /// The committed text — it will never change again.
    private(set) var transcript = LiveTranscript()
    /// The uncommitted text; it can change entirely on every tick, and is faded on screen.
    private(set) var partialText = ""
    /// Why live transcription couldn't start, if it couldn't. **The recording carries on**:
    /// the real job is to record the audio, the live text is a preview.
    private(set) var liveFailure: String?
    /// True between `finish()` returning and the worker's last text arriving. The interface
    /// shows it rather than blocking (ADR-022).
    private(set) var isFinalizing = false

    struct Failure: Equatable, Sendable {
        var message: String
        var suggestion: String?
    }

    /// Produces a capturer for the given source. The tests pass a fake one, so neither the
    /// microphone nor Core Audio is ever touched.
    typealias CaptureFactory = @Sendable (AudioSource, SystemAudioScope) -> any AudioCapturing

    private let makeCapture: CaptureFactory
    private let engine: (any LiveTranscriptionEngine)?
    private let log: @Sendable (String) -> Void
    private var capture: (any AudioCapturing)?
    private var session: LiveSession?
    /// The background wait for the stopped worker, awaited by `waitForFinalText()`.
    private var finalText: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var startedAt: Date?
    private var accumulated: TimeInterval = 0

    init(
        makeCapture: @escaping CaptureFactory = RecordingController.defaultCapture,
        engine: (any LiveTranscriptionEngine)? = nil,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.makeCapture = makeCapture
        self.engine = engine
        self.log = log
    }

    /// The microphone is captured with `AVAudioEngine`, system audio with a Core Audio tap.
    /// For `.both` the two sit on a single aggregate device (a design decision without an
    /// ADR, `docs/LIVE_TRANSCRIPTION.md` → Audio sources).
    static let defaultCapture: CaptureFactory = { source, scope in
        source == .microphone
            ? MicrophoneCapture()
            : SystemAudioCapture(source: source, scope: scope)
    }

    var isRecording: Bool { state.isActive }

    // MARK: - Starting

    /// Checks the permission, asks for it if needed, and starts recording.
    ///
    /// The whole error path is logged: we want to learn **by measuring** at which point
    /// microphone access is refused under Hardened Runtime
    /// (`docs/LIVE_TRANSCRIPTION.md` → Permissions and signing).
    func start(
        source: AudioSource = .microphone,
        scope: SystemAudioScope = .everything,
        live: LiveConfig? = nil,
        named name: String? = nil,
        in directory: URL,
        now: Date = Date()
    ) async {
        guard state == .idle || isFailed else { return }
        state = .preparing
        failure = nil

        let capture = makeCapture(source, scope)
        self.capture = capture

        log("recording requested — source: \(source.rawValue), access: \(capture.access)")
        var access = capture.access
        if access == .undetermined {
            access = await capture.requestAccess()
            log("permission requested — result: \(access)")
        }

        guard access == .granted else {
            fail(CaptureError.accessDenied)
            return
        }

        transcript.removeAll()
        partialText = ""
        liveFailure = nil

        // Live transcription is **optional**: if it won't start, the recording still happens.
        if let live, let engine {
            do {
                session = try await engine.startLiveSession(live) { [weak self] event in
                    Task { @MainActor in self?.apply(event) }
                }
                log("live transcription started: \(live.model)")
            } catch {
                liveFailure = error.localizedDescription
                log("live transcription could not start: \(error.localizedDescription)")
            }
        }

        let url = RecordingFile.uniqueURL(in: directory, named: name, at: now)
        // The session is Sendable; it is captured directly from the audio thread, with no
        // need to hop back to the main actor.
        let session = self.session
        do {
            try capture.start(writingTo: url) { [weak self] level in
                Task { @MainActor in self?.level = level }
            } onSamples: { samples, _ in
                session?.send(samples: samples)
            }
        } catch let error as CaptureError {
            fail(error)
            return
        } catch {
            fail(CaptureError.engineFailed(error.localizedDescription))
            return
        }

        fileURL = url
        accumulated = 0
        startedAt = now
        duration = 0
        state = .recording
        log("recording started: \(url.lastPathComponent)")
        startTicker()
    }

    // MARK: - Pause / resume

    func pause() {
        guard state == .recording, let capture else { return }
        capture.pause()
        accumulated += elapsedSinceStart()
        startedAt = nil
        state = .paused
        level = 0
        log("paused (\(Int(accumulated)) s)")
    }

    func resume() {
        guard state == .paused, let capture else { return }
        capture.resume()
        startedAt = Date()
        state = .recording
        log("resumed")
    }

    // MARK: - Finishing

    /// Finishes the recording and returns the file. If no audio was written at all, it
    /// deletes the file and returns `nil` — putting an empty file in the queue would come
    /// back to the user as an error.
    @discardableResult
    func finish() async -> RecordingResult? {
        guard state.isActive, let capture else { return nil }

        let written = capture.stop()
        self.capture = nil

        // The worker is told to stop, but **not waited for here**. Answering `stop` means
        // transcribing whatever is still uncommitted, which during uninterrupted speech can
        // be most of a 30-second buffer and take seconds — and this call keeps the recording
        // sheet on screen. The wait moved to `waitForFinalText()`, which the caller does once
        // the sheet is gone; committed text arriving after this point still reaches
        // `transcript`, because `apply(_:)` does not check the state (ADR-022).
        if let session {
            session.requestStop()
            isFinalizing = true
            finalText = Task { [session] in
                await session.awaitExit()
            }
            self.session = nil
        }
        partialText = ""
        stopTicker()
        let url = fileURL
        state = .idle
        level = 0
        duration = written
        startedAt = nil
        accumulated = 0

        guard let url else { return nil }
        guard written > 0.3 else {
            log("recording too short (\(written) s), deleting the file")
            try? FileManager.default.removeItem(at: url)
            fileURL = nil
            return nil
        }

        log("recording finished: \(url.lastPathComponent) — \(String(format: "%.1f", written)) s")
        return RecordingResult(url: url, duration: written)
    }

    /// Waits for the worker's last text, after `finish()` has already returned.
    ///
    /// Safe to call when there was no live session, or twice: it clears itself.
    func waitForFinalText() async {
        await finalText?.value
        finalText = nil
        isFinalizing = false
    }

    /// Cancels the recording and deletes the file.
    func cancel() {
        guard state.isActive, let capture else { return }
        capture.stop()
        self.capture = nil
        session?.cancel()
        session = nil
        transcript.removeAll()
        partialText = ""
        stopTicker()
        if let url = fileURL {
            try? FileManager.default.removeItem(at: url)
            log("recording cancelled, file deleted")
        }
        fileURL = nil
        state = .idle
        level = 0
        duration = 0
        startedAt = nil
        accumulated = 0
    }

    // MARK: - Internals

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    /// Applies live events to the state.
    private func apply(_ event: EngineEvent) {
        switch event {
        case .committed(let segment):
            transcript.append(segment)
            // Committed text drops out of the provisional part; showing both would put the
            // same sentence on screen twice.
            partialText = ""
        case .partial(let text):
            partialText = text
        case .failure(let value):
            liveFailure = value.message
            log("live transcription error: \(value.code.rawValue) \(value.message)")
        default:
            break
        }
    }

    private func fail(_ error: CaptureError) {
        capture = nil
        session?.cancel()
        session = nil
        let message = error.errorDescription ?? String(localized: "The recording could not be started.")
        log("recording failed: \(message)")
        failure = Failure(message: message, suggestion: error.suggestion)
        state = .failed(reason: message)
        fileURL = nil
    }

    private func elapsedSinceStart() -> TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    /// Refreshes the duration twice a second. The number of frames written accumulates on
    /// the audio thread; the UI doesn't need to read it for every buffer.
    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                if state == .recording {
                    duration = accumulated + elapsedSinceStart()
                }
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }
}
