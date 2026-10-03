import Foundation
import Testing

@testable import WhisperTranscriber

@Suite("Past work")
struct JobHistoryTests {

    private func entry(
        _ path: String,
        kind: HistoryEntry.Kind = .file,
        at seconds: TimeInterval,
        outputs: [String] = []
    ) -> HistoryEntry {
        HistoryEntry(
            source: URL(filePath: path),
            kind: kind,
            date: Date(timeIntervalSince1970: seconds),
            outputs: outputs.map { URL(filePath: $0) },
            model: "small",
            language: "tr"
        )
    }

    @Test("Newest first")
    func sortsNewestFirst() {
        let list = JobHistory.adding(
            entry("/a.m4a", at: 100), to: [entry("/b.m4a", at: 200)])

        #expect(list.map(\.name) == ["b", "a"])
    }

    /// Transcribing the same file twice is one row updated, not two rows: the list answers
    /// "what have I done", not "how many times".
    @Test("Running the same file again replaces its row")
    func replacesTheSameSource() {
        var list = [entry("/x.m4a", at: 100, outputs: ["/x.txt"])]
        list = JobHistory.adding(entry("/x.m4a", at: 300, outputs: ["/x.srt"]), to: list)

        #expect(list.count == 1)
        #expect(list[0].outputs.map(\.lastPathComponent) == ["x.srt"])
    }

    @Test("The list is capped")
    func capsTheList() {
        var list: [HistoryEntry] = []
        for index in 0..<(JobHistory.limit + 25) {
            list = JobHistory.adding(entry("/f\(index).m4a", at: Double(index)), to: list)
        }

        #expect(list.count == JobHistory.limit)
        // The cap drops the oldest, so the newest must still be there.
        #expect(list.first?.name == "f\(JobHistory.limit + 24)")
    }

    @Test("A round trip through the file keeps everything")
    func savesAndLoads() throws {
        let url = URL(filePath: NSTemporaryDirectory())
            .appending(path: "wt-history-\(UUID().uuidString)/history.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let original = [entry("/a.m4a", kind: .recording, at: 10, outputs: ["/a.txt"])]
        #expect(JobHistory.save(original, to: url))

        #expect(JobHistory.load(from: url) == original)
    }

    @Test("A missing or corrupt file reads as empty rather than throwing")
    func toleratesAMissingFile() throws {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "wt-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(JobHistory.load(from: directory.appending(path: "nothing.json")).isEmpty)

        let corrupt = directory.appending(path: "corrupt.json")
        try Data("not json".utf8).write(to: corrupt)
        #expect(JobHistory.load(from: corrupt).isEmpty)
    }

    // MARK: - Merging with the recordings folder

    private func recording(_ path: String, at seconds: TimeInterval) -> RecordingEntry {
        RecordingEntry(
            url: URL(filePath: path),
            createdAt: Date(timeIntervalSince1970: seconds),
            byteCount: 1024,
            transcripts: []
        )
    }

    /// A recording that was never transcribed has no stored entry, but it still happened.
    @Test("A recording that was never transcribed still appears")
    func mergesUntranscribedRecordings() {
        let merged = JobHistory.merged(
            stored: [entry("/dropped.m4a", at: 100)],
            recordings: [recording("/rec/never.m4a", at: 200)]
        )

        #expect(merged.map(\.name) == ["never", "dropped"])
        #expect(merged[0].kind == .recording)
    }

    /// The stored entry is the one that knows what the run produced, so it wins.
    @Test("A recording already in the history is not listed twice")
    func doesNotDuplicateAKnownRecording() {
        let merged = JobHistory.merged(
            stored: [entry("/rec/known.m4a", kind: .recording, at: 100, outputs: ["/rec/known.txt"])],
            recordings: [recording("/rec/known.m4a", at: 100)]
        )

        #expect(merged.count == 1)
        #expect(merged[0].outputs.map(\.lastPathComponent) == ["known.txt"])
    }

    @Test("The same path written differently is still one row")
    func matchesPathsAfterStandardizing() {
        let merged = JobHistory.merged(
            stored: [entry("/rec/./known.m4a", kind: .recording, at: 100)],
            recordings: [recording("/rec/known.m4a", at: 100)]
        )

        #expect(merged.count == 1)
    }

    // MARK: - Refreshing against the disk

    @Test("Outputs that have been deleted are dropped, and the row is kept")
    func refreshDropsMissingOutputs() throws {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "wt-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let present = directory.appending(path: "here.txt")
        try Data("x".utf8).write(to: present)
        let absent = directory.appending(path: "gone.txt")

        let refreshed = JobHistory.refreshed([
            HistoryEntry(
                source: directory.appending(path: "a.m4a"), kind: .file,
                date: .now, outputs: [present, absent], model: nil, language: nil)
        ])

        #expect(refreshed.count == 1, "the row stays even when its outputs are gone")
        #expect(refreshed[0].outputs == [present])
    }
}

@Suite("Sidebar tabs")
struct SidebarTabTests {

    @Test("Both tabs have a title and a symbol of their own")
    func tabsAreDistinct() {
        #expect(SidebarTab.allCases.count == 2)
        #expect(Set(SidebarTab.allCases.map(\.symbol)).count == 2)
        for tab in SidebarTab.allCases {
            #expect(!tab.title.isEmpty)
        }
    }
}
