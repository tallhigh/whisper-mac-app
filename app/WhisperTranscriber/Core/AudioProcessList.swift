import AppKit
import CoreAudio
import Darwin
import Foundation

/// Lists the **apps** Core Audio knows about — `docs/DECISIONS.md` → ADR-026.
///
/// The list isn't hard-coded: whatever Zoom, Chrome or Safari is playing shows up. What it
/// does hard-code is the step from a process to the app that owns it, because Core Audio
/// reports processes and the user thinks in apps, and for a browser those are not the same
/// thing.
enum AudioProcessList {

    /// The apps **currently playing audio**, sorted by name.
    ///
    /// Only those producing output: answering "which app should I record" shouldn't mean
    /// hunting through 27 silent processes. Several processes of one app collapse into one
    /// entry — Chrome plays through a renderer helper, and a list that showed the helpers
    /// separately would be a list of names the user has never seen.
    static func playing(
        excluding excludedPID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> [AudioApplication] {
        let processes = all().filter { $0.pid != excludedPID && isRunningOutput($0.objectID) }
        return group(processes)
    }

    /// Every Core Audio process object belonging to `app`, resolved **now**.
    ///
    /// Resolved at the moment recording starts, not when the user picked the app: a browser's
    /// audio moves between renderer helpers, which come and go with the tabs, so the pids
    /// captured when the picker was filled are already stale. Matching on the bundle id keeps
    /// "Google Chrome" meaning "whatever Chrome is playing through right now".
    static func objectIDs(for app: AudioApplication) -> [AudioObjectID] {
        let processes = all()
        if let bundleID = app.bundleID {
            let matching = processes.filter { owner(of: $0).bundleID == bundleID }
            if !matching.isEmpty { return matching.map(\.objectID) }
        }
        // No bundle id to match on (a daemon, say): fall back to the pids we were given.
        return app.pids.compactMap { objectID(forPID: $0) }
    }

    /// Whether any of these processes has an active output stream.
    ///
    /// Checked before the tap is created, because a tap whose processes are all producing
    /// nothing leaves the aggregate device with **no input stream at all** — and then the
    /// IOProc is never called, not even for the microphone sub-device, so the recording comes
    /// out zero seconds long and is deleted as too short. Measured; it is a silent total
    /// failure, and the user needs to be told before it happens rather than afterwards
    /// (ADR-026).
    static func isAnyProducingOutput(_ objectIDs: [AudioObjectID]) -> Bool {
        objectIDs.contains(where: isRunningOutput)
    }

    /// A single process, as Core Audio reports it.
    struct Entry: Equatable, Sendable {
        var objectID: AudioObjectID
        var pid: pid_t
        /// The bundle id of the process itself, which for a helper is the helper's own.
        var bundleID: String?
    }

    static func all() -> [Entry] {
        objectIDs(of: AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
            .compactMap(entry(for:))
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

    // MARK: - From a process to its app

    /// What a process is called and which app it belongs to.
    struct Owner: Equatable, Sendable {
        var bundleID: String?
        var name: String?
    }

    /// Walks up the parent chain until it reaches a process macOS considers an application.
    ///
    /// A Chrome renderer has no `NSRunningApplication` of its own and no name a user would
    /// recognise; its parent is the Chrome process, which has both. The walk is bounded —
    /// a cycle or a reparented orphan must not spin — and it stops at `launchd`.
    static func owner(of entry: Entry, limit: Int = 6) -> Owner {
        var pid = entry.pid
        for _ in 0..<limit {
            if let application = NSRunningApplication(processIdentifier: pid),
                let name = application.localizedName
            {
                return Owner(bundleID: application.bundleIdentifier, name: name)
            }
            guard let parent = parentPID(of: pid), parent > 1, parent != pid else { break }
            pid = parent
        }
        // Nothing in the chain is an app: keep whatever the process itself offers, so the
        // entry is still pickable rather than dropped.
        return Owner(
            bundleID: entry.bundleID,
            name: entry.bundleID.map { ($0 as NSString).lastPathComponent }
        )
    }

    /// Collapses processes into one entry per owning app.
    ///
    /// `resolve` is injected so the grouping can be tested without Core Audio or a live
    /// process tree.
    static func group(
        _ processes: [Entry],
        resolve: (Entry) -> Owner = { owner(of: $0) }
    ) -> [AudioApplication] {
        var order: [String] = []
        var apps: [String: AudioApplication] = [:]

        for process in processes {
            let owner = resolve(process)
            let name = owner.name ?? "PID \(process.pid)"
            let key = owner.bundleID ?? "pid:\(process.pid)"
            if var existing = apps[key] {
                existing.pids.append(process.pid)
                apps[key] = existing
            } else {
                order.append(key)
                apps[key] = AudioApplication(
                    pids: [process.pid], bundleID: owner.bundleID, name: name)
            }
        }

        return order.compactMap { apps[$0] }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }

    // MARK: - Internals

    private static func entry(for objectID: AudioObjectID) -> Entry? {
        guard let pid: pid_t = scalar(objectID, kAudioProcessPropertyPID) else { return nil }
        return Entry(
            objectID: objectID, pid: pid, bundleID: string(objectID, kAudioProcessPropertyBundleID))
    }

    static func isRunningOutput(_ objectID: AudioObjectID) -> Bool {
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
