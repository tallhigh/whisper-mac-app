import Foundation
import Testing

@testable import WhisperTranscriber

@Suite("Past recordings")
struct RecordingsLibraryTests {

    private func makeFolder() throws -> URL {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "wt-recordings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ name: String, in directory: URL, bytes: Int = 4) throws -> URL {
        let url = directory.appending(path: name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    @Test("Only m4a files are listed")
    func listsOnlyRecordings() throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try write("Meeting.m4a", in: directory)
        _ = try write("Meeting.txt", in: directory)
        _ = try write("notes.md", in: directory)
        _ = try write("other.mp3", in: directory)

        let entries = RecordingsLibrary.entries(in: directory)

        #expect(entries.map(\.name) == ["Meeting"])
        #expect(entries.first?.byteCount == 4)
    }

    @Test("Newest first")
    func sortsNewestFirst() throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = try write("Older.m4a", in: directory)
        let new = try write("Newer.m4a", in: directory)
        // Creation dates come from the file system, so they are set rather than assumed.
        try FileManager.default.setAttributes(
            [.creationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes(
            [.creationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: new.path)

        #expect(RecordingsLibrary.entries(in: directory).map(\.name) == ["Newer", "Older"])
    }

    @Test("The transcripts beside a recording are found")
    func findsTranscripts() throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try write("Meeting.m4a", in: directory)
        _ = try write("Meeting.txt", in: directory)
        _ = try write("Meeting.md", in: directory)
        _ = try write("Meeting.srt", in: directory)

        let entry = try #require(RecordingsLibrary.entries(in: directory).first)

        #expect(Set(entry.transcripts.map(\.lastPathComponent)) == ["Meeting.txt", "Meeting.md", "Meeting.srt"])
    }

    @Test("The live transcript counts as one of them")
    func findsLiveTranscript() throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try write("Call.m4a", in: directory)
        _ = try write("Call\(LiveTranscriptWriter.liveSuffix).txt", in: directory)

        let entry = try #require(RecordingsLibrary.entries(in: directory).first)

        #expect(entry.transcripts.count == 1)
        #expect(entry.transcripts[0].lastPathComponent.contains(LiveTranscriptWriter.liveSuffix))
    }

    /// The trap: a prefix match would hand `Meeting.m4a` a file belonging to something else.
    @Test("A file that merely starts with the same word is not claimed")
    func doesNotMatchByPrefix() throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try write("Meeting.m4a", in: directory)
        _ = try write("Meeting notes from last year.txt", in: directory)
        _ = try write("Meeting-2.txt", in: directory)

        let entry = try #require(RecordingsLibrary.entries(in: directory).first)

        #expect(entry.transcripts.isEmpty)
    }

    @Test("A transcript in the chosen output folder is found too")
    func findsTranscriptInOutputFolder() throws {
        let recordings = try makeFolder()
        let output = try makeFolder()
        defer {
            try? FileManager.default.removeItem(at: recordings)
            try? FileManager.default.removeItem(at: output)
        }
        _ = try write("Standup.m4a", in: recordings)
        _ = try write("Standup.txt", in: output)

        let entry = try #require(
            RecordingsLibrary.entries(in: recordings, transcriptSearchPaths: [output]).first)

        #expect(entry.transcripts.map(\.lastPathComponent) == ["Standup.txt"])
    }

    /// With output set to "beside the source", the same folder is searched twice.
    @Test("A transcript found twice is listed once")
    func doesNotDuplicate() throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try write("One.m4a", in: directory)
        _ = try write("One.txt", in: directory)

        let entry = try #require(
            RecordingsLibrary.entries(in: directory, transcriptSearchPaths: [directory]).first)

        #expect(entry.transcripts.count == 1)
    }

    @Test("A folder that does not exist gives an empty list, not an error")
    func missingFolderIsEmpty() {
        let directory = URL(filePath: "/tmp/wt-definitely-missing-\(UUID().uuidString)")
        #expect(RecordingsLibrary.entries(in: directory).isEmpty)
    }

    @Test("A subfolder is not descended into")
    func ignoresSubfolders() throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nested = directory.appending(path: "old")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try write("Buried.m4a", in: nested)
        _ = try write("Top.m4a", in: directory)

        #expect(RecordingsLibrary.entries(in: directory).map(\.name) == ["Top"])
    }

    /// A recording cannot be downloaded again, so this one deletion stays recoverable.
    @Test("Trashing moves the audio and keeps the transcripts")
    func trashKeepsTranscripts() throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = try write("Trashme-\(UUID().uuidString).m4a", in: directory)
        let transcript = try write("\(audio.deletingPathExtension().lastPathComponent).txt", in: directory)

        let trashed = try RecordingsLibrary.moveToTrash(audio)

        #expect(!FileManager.default.fileExists(atPath: audio.path))
        #expect(FileManager.default.fileExists(atPath: transcript.path))
        // It went to the Trash rather than being unlinked, so it is still somewhere.
        if let trashed {
            #expect(trashed.path.contains(".Trash"))
            try? FileManager.default.removeItem(at: trashed)
        }
    }

    @Test("Trashing refuses anything that is not a recording")
    func trashRefusesOtherFiles() throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = try write("Notes.txt", in: directory)

        #expect(throws: RecordingsLibrary.DeleteError.notARecording("Notes.txt")) {
            try RecordingsLibrary.moveToTrash(transcript)
        }
        #expect(FileManager.default.fileExists(atPath: transcript.path))
    }
}
