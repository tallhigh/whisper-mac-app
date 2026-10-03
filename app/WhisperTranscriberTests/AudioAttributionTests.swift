import CoreAudio
import Foundation
import Testing

@testable import WhisperTranscriber

/// The tests behind ADR-026. The bug they pin down was found by measurement: with AirPods
/// connected and a browser playing, a tap installed on the browser's **main** process never
/// called the IOProc once, while a tap on the renderer helper that was actually playing
/// delivered the audio at full level.
@Suite("Audio apps")
struct AudioApplicationTests {

    private func entry(_ pid: pid_t, _ bundleID: String?) -> AudioProcessList.Entry {
        AudioProcessList.Entry(objectID: AudioObjectID(pid), pid: pid, bundleID: bundleID)
    }

    /// Chrome plays through renderer helpers. Listing them separately would offer the user
    /// several entries called "com.google.Chrome.helper" and none called "Google Chrome".
    @Test("Several processes of one app become one entry")
    func groupsHelpersUnderTheirApp() {
        let processes = [
            entry(8519, "com.google.Chrome.helper"),
            entry(8520, "com.google.Chrome.helper"),
        ]
        let apps = AudioProcessList.group(processes) { _ in
            AudioProcessList.Owner(bundleID: "com.google.Chrome", name: "Google Chrome")
        }

        #expect(apps.count == 1)
        #expect(apps[0].name == "Google Chrome")
        #expect(apps[0].bundleID == "com.google.Chrome")
        #expect(apps[0].pids.sorted() == [8519, 8520])
    }

    @Test("Different apps stay apart, sorted by name")
    func keepsDistinctAppsApart() {
        let owners: [pid_t: AudioProcessList.Owner] = [
            1: .init(bundleID: "us.zoom.xos", name: "Zoom"),
            2: .init(bundleID: "com.apple.Music", name: "Music"),
        ]
        let apps = AudioProcessList.group([entry(1, nil), entry(2, nil)]) {
            owners[$0.pid] ?? .init(bundleID: nil, name: nil)
        }

        #expect(apps.map(\.name) == ["Music", "Zoom"])
    }

    /// A daemon with no owning application must stay pickable rather than vanish from the list.
    @Test("A process with no owning app is still listed")
    func keepsUnownedProcesses() {
        let apps = AudioProcessList.group([entry(77, nil)]) { _ in
            AudioProcessList.Owner(bundleID: nil, name: nil)
        }

        #expect(apps.count == 1)
        #expect(apps[0].name == "PID 77")
        #expect(apps[0].id == "pid:77")
    }

    /// The id has to survive a refresh: the helper pids behind an app change as tabs open and
    /// close, and a picker keyed on a pid would silently lose the user's selection.
    @Test("The id is stable while the processes behind it change")
    func idSurvivesChangingProcesses() {
        let resolve: (AudioProcessList.Entry) -> AudioProcessList.Owner = { _ in
            .init(bundleID: "com.google.Chrome", name: "Google Chrome")
        }
        let first = AudioProcessList.group([entry(1, nil)], resolve: resolve)
        let second = AudioProcessList.group([entry(2, nil), entry(3, nil)], resolve: resolve)

        #expect(first[0].id == second[0].id)
        #expect(first[0].pids != second[0].pids)
    }

    @Test("A parent pid can be read for the running process")
    func readsTheParentPID() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let parent = AudioProcessList.parentPID(of: pid)

        #expect(parent != nil)
        #expect(parent != pid)
    }
}

@Suite("Capture levels")
struct CaptureLevelsTests {

    @Test("A microphone-only report has no system side")
    func microphoneOnly() {
        let levels = CaptureLevels.microphoneOnly(0.5)

        #expect(levels.combined == 0.5)
        #expect(levels.microphone == 0.5)
        #expect(levels.system == nil)
        #expect(!levels.hasSystemAudio)
    }

    /// A silent tap delivers exact zeros, so the floor only has to clear the scaling's own
    /// rounding — it is set far below anything audible.
    @Test("Digital silence does not count as system audio")
    func silenceIsNotPresence() {
        #expect(!CaptureLevels(combined: 0.4, microphone: 0.4, system: 0).hasSystemAudio)
        #expect(CaptureLevels(combined: 0.4, microphone: 0.4, system: 0.2).hasSystemAudio)
    }

    @Test("Unknown is not the same as zero")
    func unknownIsNotZero() {
        let unknown = CaptureLevels(combined: 0.4, microphone: nil, system: nil)

        #expect(unknown.system == nil)
        #expect(!unknown.hasSystemAudio)
    }

    // MARK: - Attributing the aggregate's channels

    /// The aggregate lays its input out as the sub-devices first, then the taps. A loud
    /// microphone must not be able to make a dead tap look alive.
    @Test("A loud microphone and a silent tap are reported apart")
    func separatesTheOrigins() {
        var energy = CaptureOriginEnergy()
        energy.add(100, frames: 1000, microphone: true)
        energy.add(0, frames: 1000, microphone: false)

        let levels = energy.levels(combined: 0.9, expectingMicrophone: true)

        #expect((levels.microphone ?? 0) > 0.3)
        #expect(levels.system == 0)
        #expect(!levels.hasSystemAudio)
    }

    @Test("With no microphone asked for, only the system side is reported")
    func systemOnly() {
        var energy = CaptureOriginEnergy()
        energy.add(100, frames: 1000, microphone: false)

        let levels = energy.levels(combined: 0.5, expectingMicrophone: false)

        #expect(levels.microphone == nil)
        #expect(levels.hasSystemAudio)
    }

    /// If the channel layout isn't what we measured it to be, saying "no system audio" would
    /// be an accusation we can't support. Both halves come back unknown instead.
    @Test("An unattributable layout reports unknown, not zero")
    func refusesToGuess() {
        var energy = CaptureOriginEnergy()
        energy.add(100, frames: 1000, microphone: false)

        let levels = energy.levels(combined: 0.5, expectingMicrophone: true)

        #expect(levels.microphone == nil)
        #expect(levels.system == nil)
        #expect(levels.combined == 0.5)
    }
}
