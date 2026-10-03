import AppKit
import CoreAudio
import Foundation

/// Lists the processes Core Audio knows about.
///
/// The list isn't hard-coded: whatever Zoom, Chrome or Safari is playing shows up.
enum AudioProcessList {

    /// The processes **currently playing audio**, sorted by name.
    ///
    /// Only those producing output: answering "which app should I record" shouldn't mean
    /// hunting through 27 silent processes.
    static func playing(
        excluding excludedPID: pid_t = ProcessInfo.processInfo.processIdentifier
    )
        -> [AudioProcess]
    {
        all().filter { $0.pid != excludedPID && isRunningOutput($0.objectID) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func all() -> [AudioProcess] {
        objectIDs(of: AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
            .compactMap(process(for:))
    }

    /// A process's Core Audio object id. The id changes if the process restarts, so it is
    /// resolved again when a recording starts.
    static func objectID(forPID pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var input = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &input,
            &size,
            &objectID
        )
        guard status == noErr, objectID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return objectID
    }

    // MARK: - Internals

    private static func process(for objectID: AudioObjectID) -> AudioProcess? {
        guard let pid: pid_t = scalar(objectID, kAudioProcessPropertyPID) else { return nil }
        let bundleID = string(objectID, kAudioProcessPropertyBundleID)
        let application = NSRunningApplication(processIdentifier: pid)
        let name =
            application?.localizedName
            ?? bundleID.map { ($0 as NSString).lastPathComponent }
            ?? "PID \(pid)"
        return AudioProcess(objectID: objectID, pid: pid, bundleID: bundleID, name: name)
    }

    private static func isRunningOutput(_ objectID: AudioObjectID) -> Bool {
        (scalar(objectID, kAudioProcessPropertyIsRunningOutput) as UInt32?) ?? 0 != 0
    }

    private static func objectIDs(
        of objectID: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr, size > 0
        else {
            return []
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    private static func scalar<T: Numeric>(
        _ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: T = .zero
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        return status == noErr ? value : nil
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
