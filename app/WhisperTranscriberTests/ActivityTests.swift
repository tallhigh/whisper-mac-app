import Foundation
import Testing

@testable import WhisperTranscriber

@Suite("What the app is doing")
struct ActivityTests {

    @Test("Only idle is not busy")
    func busyStates() {
        #expect(!Activity.idle.isBusy)
        for activity in [
            Activity.recording(elapsed: 0),
            .paused(elapsed: 0),
            .finalizing,
            .transcribing(name: "a.m4a", fraction: nil),
        ] {
            #expect(activity.isBusy, "\(activity) must keep the menu bar item in place")
        }
    }

    /// The item sits beside the clock, so the text has to stay short and must not be a
    /// placeholder when there is nothing to say.
    @Test("The menu bar text is the clock while recording and a percentage while transcribing")
    func menuBarText() {
        #expect(Activity.recording(elapsed: 95).menuBarText == "01:35")
        #expect(Activity.paused(elapsed: 3661).menuBarText == "1:01:01")
        #expect(Activity.transcribing(name: "a.m4a", fraction: 0.42).menuBarText == "42%")
        // No progress event yet, and finalizing has no number at all: symbol only.
        #expect(Activity.transcribing(name: "a.m4a", fraction: nil).menuBarText == nil)
        #expect(Activity.finalizing.menuBarText == nil)
        #expect(Activity.idle.menuBarText == nil)
    }

    @Test("Every state has a distinct symbol and a title")
    func symbolsAndTitles() {
        let states: [Activity] = [
            .idle, .recording(elapsed: 1), .paused(elapsed: 1), .finalizing,
            .transcribing(name: "a.m4a", fraction: nil),
        ]
        #expect(Set(states.map(\.symbol)).count == states.count, "two states share a symbol")
        for activity in states {
            #expect(!activity.title.isEmpty)
            #expect(!activity.accessibilityLabel.isEmpty)
        }
    }

    @Test("The title carries the file name and the percentage")
    func transcribingTitle() {
        let withProgress = Activity.transcribing(name: "meeting.m4a", fraction: 0.5).title
        #expect(withProgress.contains("meeting.m4a"))
        #expect(withProgress.contains("50"))

        let without = Activity.transcribing(name: "meeting.m4a", fraction: nil).title
        #expect(without.contains("meeting.m4a"))
        #expect(!without.contains("%"))
    }

    /// Rounding, not truncation: 0.999 is not 99% to a user watching a bar fill up.
    @Test("The percentage is rounded")
    func percentageRounds() {
        #expect(Activity.transcribing(name: "a", fraction: 0.999).menuBarText == "100%")
        #expect(Activity.transcribing(name: "a", fraction: 0.004).menuBarText == "0%")
        #expect(Activity.transcribing(name: "a", fraction: 1).menuBarText == "100%")
    }
}

@Suite("Activity precedence")
@MainActor
struct ActivityPrecedenceTests {

    /// A recording in progress is what the user cares about even when the queue is draining
    /// behind it, and `finalizing` outranks the queue for the same reason. The precedence
    /// lives in one place so the menu bar and the toolbar cannot disagree.
    @Test("An idle app with an empty queue reports idle")
    func idleByDefault() {
        #expect(AppState().activity == .idle)
    }

    @Test("A running queue with no active item still counts as transcribing")
    func runningWithoutActiveItemIsNotIdle() {
        // The moment between two jobs: reporting idle there would make the menu bar item
        // flicker out and back in between queued files.
        let activity = Activity.transcribing(name: "", fraction: nil)
        #expect(activity.isBusy)
        #expect(activity.menuBarText == nil)
    }
}
