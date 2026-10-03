import AVFoundation
import Foundation

/// The captured samples and that buffer's level.
typealias SampleHandler = @Sendable ([Int16], Float) -> Void

/// The contract for audio capture.
///
/// The interface and the state machine talk to this; the tests run against a fake
/// implementation without touching the microphone. `SystemAudioCapture`, which captures
/// system audio, is plugged into the same protocol (`docs/LIVE_TRANSCRIPTION.md` → Audio sources).
protocol AudioCapturing: Sendable {

    /// The **current** state of access; asks nothing.
    var access: CaptureAccess { get }

    /// Shows the system permission dialog if needed.
    func requestAccess() async -> CaptureAccess

    /// Starts capturing and writes the audio to `url`.
    ///
    /// `onLevel` reports the audio level (0...1) for the UI a few times a second; it is
    /// called from the main actor, **not** from the real-time audio thread.
    ///
    /// `onSamples` is called for every buffer, **from the audio thread**: 16 kHz mono
    /// int16 samples plus that buffer's RMS. Live transcription uses it; the level comes
    /// along so silent chunks need not be sent to the worker (digital silence produces
    /// severe hallucination, measured).
    func start(
        writingTo url: URL,
        onLevel: @escaping @Sendable (Float) -> Void,
        onSamples: SampleHandler?
    ) throws

    func pause()
    func resume()

    /// Stops and returns the duration of the audio written.
    @discardableResult
    func stop() -> TimeInterval
}

/// The capture layer's errors.
enum CaptureError: LocalizedError {
    case accessDenied
    case noInputDevice
    case engineFailed(String)
    case fileCreationFailed(String)
    /// A Core Audio step failed. `status` is the whole diagnosis: which call returned
    /// which code is written to the log (the method from ADR-016).
    case tapFailed(step: String, status: OSStatus)
    case noAudioProcess

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            String(localized: "Microphone access was not granted.")
        case .noInputDevice:
            String(localized: "No usable microphone was found.")
        case .engineFailed(let detail):
            String(localized: "Audio capture could not be started: \(detail)")
        case .fileCreationFailed(let detail):
            String(localized: "The recording file could not be created: \(detail)")
        case .tapFailed(let step, let status):
            String(localized: "System audio could not be captured (\(step): \(Int(status))).")
        case .noAudioProcess:
            String(localized: "The selected app isn't playing any audio right now.")
        }
    }

    var suggestion: String? {
        switch self {
        case .accessDenied:
            String(localized: "Grant access in System Settings → Privacy & Security → Microphone.")
        case .noInputDevice:
            String(localized: "Connect a microphone and try again.")
        case .tapFailed:
            String(localized: "Check the audio-recording permission in System Settings.")
        case .noAudioProcess:
            String(localized: "Start the audio in the app and try again.")
        case .engineFailed, .fileCreationFailed:
            nil
        }
    }
}

/// The target format whisper expects.
///
/// 16 kHz mono — exactly what `whisper_worker.decode_audio` gets from ffmpeg. The live
/// path using the same representation is what keeps an unexplained difference from
/// appearing between the two passes.
enum CaptureFormat {
    static let sampleRate: Double = 16_000
    static let channels: AVAudioChannelCount = 1

    /// The format shared by the converter and the file writer.
    static var float32: AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )
    }

    /// The recording file's settings. AAC 32 kbps, 16 kHz mono ≈ 14 MB/hour.
    static var fileSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channels),
            AVEncoderBitRateKey: 32_000,
        ]
    }

    /// Converts float32 samples to the int16 the worker expects.
    ///
    /// `decode_audio` takes `s16le` from ffmpeg and divides by 32768.0; this is the
    /// inverse. In live mode the audio flows to the worker in this form.
    static func int16Samples(from samples: [Float]) -> [Int16] {
        samples.map { sample in
            let clamped = min(max(sample, -1), 1)
            // We scale by 32767 on the negative side too, to avoid overflowing to -32768.
            return Int16(clamping: Int(clamped * 32767))
        }
    }
}

/// A source that hands the converter its buffer **once**.
///
/// `AVAudioConverterInputBlock` is declared `@Sendable`, but the converter calls it
/// synchronously on the same thread. Capturing a local variable warns under strict
/// concurrency; putting the state in a reference type both removes the warning and
/// states the intent plainly.
///
/// Handing the buffer over twice would make the converter process the same audio again.
final class ConverterInput: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var supplied = false

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if supplied {
            status.pointee = .noDataNow
            return nil
        }
        supplied = true
        status.pointee = .haveData
        return buffer
    }
}

enum CaptureLevel {
    /// RMS squeezed into 0...1. For the level meter; not a measurement.
    static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            let sample = channel[index]
            sum += sample * sample
        }
        let value = (sum / Float(buffer.frameLength)).squareRoot()
        // Speech RMS is typically 0.02–0.2; we spread that across the visible range.
        return min(value * 4, 1)
    }
}

extension AudioCapturing {

    /// Converts the converted float32 buffer to int16 and hands it to the listener.
    ///
    /// The worker expects the same representation as `decode_audio`: 16 kHz mono int16.
    /// The conversion happens here so both capturers go through the same code.
    func samples(from buffer: AVAudioPCMBuffer) -> [Int16] {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return [] }
        let count = Int(buffer.frameLength)
        return CaptureFormat.int16Samples(
            from: Array(UnsafeBufferPointer(start: channel, count: count)))
    }
}
