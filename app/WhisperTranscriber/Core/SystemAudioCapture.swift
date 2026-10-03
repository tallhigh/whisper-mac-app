import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Captures system audio (and the microphone too, if asked) with a Core Audio **process
/// tap** — `docs/LIVE_TRANSCRIPTION.md` → Audio sources.
///
/// Why not ScreenCaptureKit: this is an audio app, and asking the user for screen-recording
/// permission would be disproportionate. `CATapDescription` gives us the mono mixdown and
/// per-process selection out of the box.
///
/// If the microphone is wanted too, the tap and the microphone become sub-devices of **the
/// same aggregate device**; that leaves clock drift to Core Audio's own rate converter, with
/// no need to align two separate streams by hand.
///
/// `@unchecked Sendable`: Core Audio objects and `AVAudioFile` are not Sendable; setup and
/// teardown are serialised with `lock`, and the IOProc block captures references that don't
/// change after setup.
final class SystemAudioCapture: AudioCapturing, @unchecked Sendable {

    private let source: AudioSource
    private let scope: SystemAudioScope

    private let lock = NSLock()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private var framesWritten: AVAudioFramePosition = 0
    private var paused = false
    private var levelHandler: (@Sendable (Float) -> Void)?
    private var sampleHandler: SampleHandler?
    private var lastLevelSentAt: CFAbsoluteTime = 0

    private static let levelInterval: CFAbsoluteTime = 1.0 / 15.0

    init(source: AudioSource, scope: SystemAudioScope) {
        self.source = source
        self.scope = scope
    }

    // MARK: - Access

    /// There is no query API like `AVCaptureDevice` for system audio; the permission only
    /// becomes apparent when you try to install the tap. If the microphone is wanted too,
    /// its state is what decides.
    var access: CaptureAccess {
        guard source.capturesMicrophone else { return .granted }
        return MicrophoneCapture.currentAccess
    }

    func requestAccess() async -> CaptureAccess {
        guard source.capturesMicrophone else { return .granted }
        return await MicrophoneCapture.request()
    }

    // MARK: - Starting

    func start(
        writingTo url: URL,
        onLevel: @escaping @Sendable (Float) -> Void,
        onSamples: SampleHandler? = nil
    ) throws {
        guard let target = CaptureFormat.float32 else {
            throw CaptureError.engineFailed("the target format could not be created")
        }

        let tap = try createTap()
        let aggregate: AudioObjectID
        do {
            aggregate = try createAggregate(tapUID: tap.uid)
        } catch {
            AudioHardwareDestroyProcessTap(tap.id)
            throw error
        }

        let sampleRate = Self.nominalSampleRate(of: aggregate) ?? tap.sampleRate
        guard sampleRate > 0,
            let deviceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1,
                interleaved: false),
            let converter = AVAudioConverter(from: deviceFormat, to: target)
        else {
            Self.tearDown(tap: tap.id, aggregate: aggregate, ioProc: nil)
            throw CaptureError.engineFailed("the converter could not be set up (\(sampleRate) Hz)")
        }

        let audioFile: AVAudioFile
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            audioFile = try AVAudioFile(forWriting: url, settings: CaptureFormat.fileSettings)
        } catch {
            Self.tearDown(tap: tap.id, aggregate: aggregate, ioProc: nil)
            throw CaptureError.fileCreationFailed(error.localizedDescription)
        }

        lock.withLock {
            tapID = tap.id
            aggregateID = aggregate
            file = audioFile
            framesWritten = 0
            paused = false
            levelHandler = onLevel
            lastLevelSentAt = 0
        }

        // The block is created **after** setup: the converter, the file and the target format
        // are captured as immutable references, so they don't need to be read under the lock
        // inside the IOProc.
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, nil) {
            [weak self] _, inputData, _, _, _ in
            self?.handle(inputData, converter: converter, file: audioFile, target: target)
        }
        guard status == noErr, let procID else {
            Self.tearDown(tap: tap.id, aggregate: aggregate, ioProc: nil)
            resetState()
            throw CaptureError.tapFailed(step: "IOProc", status: status)
        }

        let startStatus = AudioDeviceStart(aggregate, procID)
        guard startStatus == noErr else {
            Self.tearDown(tap: tap.id, aggregate: aggregate, ioProc: procID)
            resetState()
            try? FileManager.default.removeItem(at: url)
            throw CaptureError.tapFailed(step: "AudioDeviceStart", status: startStatus)
        }

        lock.withLock { ioProcID = procID }
    }

    func pause() { lock.withLock { paused = true } }
    func resume() { lock.withLock { paused = false } }

    @discardableResult
    func stop() -> TimeInterval {
        let (tap, aggregate, proc) = lock.withLock {
            (tapID, aggregateID, ioProcID)
        }
        Self.tearDown(tap: tap, aggregate: aggregate, ioProc: proc)

        return lock.withLock {
            let frames = framesWritten
            file = nil
            levelHandler = nil
            sampleHandler = nil
            framesWritten = 0
            paused = false
            tapID = AudioObjectID(kAudioObjectUnknown)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
            ioProcID = nil
            return Double(frames) / CaptureFormat.sampleRate
        }
    }

    // MARK: - Tap and aggregate setup

    private struct Tap {
        var id: AudioObjectID
        var uid: String
        var sampleRate: Double
    }

    private func createTap() throws -> Tap {
        let description = CATapDescription()
        description.name = "Whisper Transcriber"
        // Visible only to us; it doesn't pollute other apps' device lists.
        description.isPrivate = true
        // We do **not** mute what the user hears; the call has to carry on.
        description.muteBehavior = .unmuted
        description.isMono = true
        description.isMixdown = true

        switch scope {
        case .everything:
            // An empty list + exclusive: "everything except what's listed".
            description.isExclusive = true
            description.processes = []
        case .processes(let processes):
            description.isExclusive = false
            // The ids change when a process restarts; we refresh them from the PID as the
            // recording starts.
            description.processes = processes.compactMap { process in
                AudioProcessList.objectID(forPID: process.pid)
            }
            guard !description.processes.isEmpty else {
                throw CaptureError.noAudioProcess
            }
        }

        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &id)
        guard status == noErr, id != AudioObjectID(kAudioObjectUnknown) else {
            throw CaptureError.tapFailed(step: "AudioHardwareCreateProcessTap", status: status)
        }

        let uid = Self.string(id, kAudioTapPropertyUID) ?? description.uuid.uuidString
        return Tap(id: id, uid: uid, sampleRate: Self.tapSampleRate(id) ?? 0)
    }

    private func createAggregate(tapUID: String) throws -> AudioObjectID {
        var subDevices: [[String: Any]] = []
        if source.capturesMicrophone, let micUID = Self.defaultInputUID() {
            // Drift compensation: the microphone and the tap run on separate clocks.
            subDevices.append([
                kAudioSubDeviceUIDKey as String: micUID,
                kAudioSubDeviceDriftCompensationKey as String: true,
            ])
        }

        let uid = UUID().uuidString
        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Whisper Transcriber Capture",
            kAudioAggregateDeviceUIDKey as String: uid,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: subDevices,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapUID,
                    kAudioSubTapDriftCompensationKey as String: true,
                ]
            ],
        ]
        // The clock source: the output device. The tap is already listening to it.
        if let outputUID = Self.defaultOutputUID() {
            description[kAudioAggregateDeviceMainSubDeviceKey as String] = outputUID
        }

        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
        guard status == noErr, id != AudioObjectID(kAudioObjectUnknown) else {
            throw CaptureError.tapFailed(step: "AudioHardwareCreateAggregateDevice", status: status)
        }
        return id
    }

    private func resetState() {
        lock.withLock {
            file = nil
            levelHandler = nil
            sampleHandler = nil
            tapID = AudioObjectID(kAudioObjectUnknown)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
            ioProcID = nil
        }
    }

    private static func tearDown(
        tap: AudioObjectID, aggregate: AudioObjectID, ioProc: AudioDeviceIOProcID?
    ) {
        if aggregate != AudioObjectID(kAudioObjectUnknown) {
            if let ioProc {
                AudioDeviceStop(aggregate, ioProc)
                AudioDeviceDestroyIOProcID(aggregate, ioProc)
            }
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        if tap != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tap)
        }
    }

    // MARK: - Audio thread

    /// Reduces **all** of the aggregate's input channels to mono.
    ///
    /// For `.both`, the buffer list carries both the microphone and the tap channels; summing
    /// them all and clamping is what makes both sides audible. Summing is preferred over
    /// averaging: we don't want our own voice halved when the other side goes quiet. Clipping
    /// is rare in practice — the two don't peak at the same moment.
    private func handle(
        _ inputData: UnsafePointer<AudioBufferList>,
        converter: AVAudioConverter,
        file: AVAudioFile,
        target: AVAudioFormat
    ) {
        let isPaused = lock.withLock { paused }
        guard !isPaused else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData))
        guard let first = buffers.first, first.mDataByteSize > 0 else { return }

        let channelsInFirst = max(Int(first.mNumberChannels), 1)
        let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channelsInFirst
        guard frames > 0 else { return }

        var mixed = [Float](repeating: 0, count: frames)
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let channels = max(Int(buffer.mNumberChannels), 1)
            let available = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let samples = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<frames {
                for channel in 0..<channels {
                    let index = frame * channels + channel
                    guard index < available else { break }
                    mixed[frame] += samples[index]
                }
            }
        }
        for index in mixed.indices {
            mixed[index] = min(max(mixed[index], -1), 1)
        }

        guard
            let source = AVAudioPCMBuffer(
                pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(frames)),
            let channel = source.floatChannelData?[0]
        else {
            return
        }
        mixed.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            channel.update(from: base, count: frames)
        }
        source.frameLength = AVAudioFrameCount(frames)

        let ratio = target.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frames) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return
        }

        let input = ConverterInput(source)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in input.next(status) }
        guard error == nil, output.frameLength > 0 else { return }

        do {
            try file.write(from: output)
        } catch {
            return
        }

        let level = CaptureLevel.rms(of: output)
        lock.withLock { framesWritten += AVAudioFramePosition(output.frameLength) }
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

    private func publish(_ level: Float) {
        let handler: (@Sendable (Float) -> Void)? = lock.withLock {
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastLevelSentAt >= Self.levelInterval else { return nil }
            lastLevelSentAt = now
            return levelHandler
        }
        guard let handler else { return }
        Task { @MainActor in handler(level) }
    }

    // MARK: - Core Audio helpers

    private static func tapSampleRate(_ tap: AudioObjectID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format) == noErr else {
            return nil
        }
        return format.mSampleRate
    }

    private static func nominalSampleRate(of device: AudioObjectID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr,
            rate > 0
        else {
            return nil
        }
        return rate
    }

    private static func defaultOutputUID() -> String? {
        deviceUID(for: kAudioHardwarePropertyDefaultOutputDevice)
    }

    private static func defaultInputUID() -> String? {
        deviceUID(for: kAudioHardwarePropertyDefaultInputDevice)
    }

    private static func deviceUID(for selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
            device != AudioObjectID(kAudioObjectUnknown)
        else {
            return nil
        }
        return string(device, kAudioDevicePropertyDeviceUID)
    }

    private static func string(
        _ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        return value as String?
    }
}
