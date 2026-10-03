import AVFoundation
import Foundation

/// Captures from the microphone with `AVAudioEngine`, converts to 16 kHz mono and writes it
/// to disk.
///
/// The audio callback runs on a **real-time** thread: all it does there is convert, write to
/// the file and compute the RMS. A lock is taken, but nothing inside it allocates or waits.
/// The level that reaches the UI is moved to the main actor ~15 times a second; moving it
/// for every buffer kept the main actor needlessly busy.
///
/// `@unchecked Sendable`: `AVAudioEngine` and `AVAudioFile` are not Sendable, so access
/// is serialised with `lock`.
final class MicrophoneCapture: AudioCapturing, @unchecked Sendable {

    private let engine = AVAudioEngine()
    private let lock = NSLock()

    private var converter: AVAudioConverter?
    private var file: AVAudioFile?
    private var framesWritten: AVAudioFramePosition = 0
    private var paused = false
    private var levelHandler: LevelHandler?
    private var sampleHandler: SampleHandler?
    private var lastLevelSentAt: CFAbsoluteTime = 0

    /// The shortest interval between level reports.
    private static let levelInterval: CFAbsoluteTime = 1.0 / 15.0

    // MARK: - Access

    var access: CaptureAccess { Self.currentAccess }

    func requestAccess() async -> CaptureAccess { await Self.request() }

    /// The system-audio capturer takes this same path when it wants the microphone too.
    static var currentAccess: CaptureAccess {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .undetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    static func request() async -> CaptureAccess {
        guard currentAccess == .undetermined else { return currentAccess }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        return granted ? .granted : .denied
    }

    // MARK: - Capturing

    func start(
        writingTo url: URL,
        onLevels: @escaping LevelHandler,
        onSamples: SampleHandler? = nil
    ) throws {
        guard access == .granted else { throw CaptureError.accessDenied }
        guard let target = CaptureFormat.float32 else {
            throw CaptureError.engineFailed("the target format could not be created")
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        // With permission not granted, or no device, the format comes back as 0 Hz.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw CaptureError.engineFailed(
                "the converter could not be set up (\(inputFormat.sampleRate) Hz → \(target.sampleRate) Hz)")
        }

        let audioFile: AVAudioFile
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            audioFile = try AVAudioFile(forWriting: url, settings: CaptureFormat.fileSettings)
        } catch {
            throw CaptureError.fileCreationFailed(error.localizedDescription)
        }

        lock.withLock {
            self.converter = converter
            self.file = audioFile
            self.framesWritten = 0
            self.paused = false
            self.levelHandler = onLevels
            self.sampleHandler = onSamples
            self.lastLevelSentAt = 0
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer, target: target)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            lock.withLock {
                self.file = nil
                self.converter = nil
            }
            try? FileManager.default.removeItem(at: url)
            throw CaptureError.engineFailed(error.localizedDescription)
        }
    }

    func pause() {
        lock.withLock { paused = true }
    }

    func resume() {
        lock.withLock { paused = false }
    }

    @discardableResult
    func stop() -> TimeInterval {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        return lock.withLock {
            let frames = framesWritten
            // Releasing the reference is the only way to close the file.
            file = nil
            converter = nil
            levelHandler = nil
            sampleHandler = nil
            framesWritten = 0
            paused = false
            return Double(frames) / CaptureFormat.sampleRate
        }
    }

    // MARK: - Audio thread

    private func handle(_ buffer: AVAudioPCMBuffer, target: AVAudioFormat) {
        let work: (AVAudioConverter, AVAudioFile)? = lock.withLock {
            guard !paused, let converter, let file else { return nil }
            return (converter, file)
        }
        guard let (converter, file) = work else { return }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        let source = ConverterInput(buffer)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in source.next(status) }
        guard error == nil, output.frameLength > 0 else { return }

        do {
            try file.write(from: output)
        } catch {
            return
        }

        let level = CaptureLevel.rms(of: output)
        lock.withLock {
            framesWritten += AVAudioFramePosition(output.frameLength)
        }
        emitSamples(from: output, level: level)
        publish(level)
    }

    /// Hands the samples to live transcription. Called from the audio thread; with no
    /// listener, the conversion cost is never paid at all.
    private func emitSamples(from buffer: AVAudioPCMBuffer, level: Float) {
        let handler: SampleHandler? = lock.withLock { sampleHandler }
        guard let handler else { return }
        handler(samples(from: buffer), level)
    }

    /// Everything here is the microphone, so the breakdown is the level twice over.
    private func publish(_ level: Float) {
        let handler: LevelHandler? = lock.withLock {
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastLevelSentAt >= Self.levelInterval else { return nil }
            lastLevelSentAt = now
            return levelHandler
        }
        guard let handler else { return }
        let levels = CaptureLevels.microphoneOnly(level)
        Task { @MainActor in handler(levels) }
    }

}
