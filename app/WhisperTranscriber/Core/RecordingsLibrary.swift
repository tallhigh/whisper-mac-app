import Foundation

/// One past recording on disk, with whatever transcripts were found beside it.
struct RecordingEntry: Identifiable, Equatable, Sendable {
    let url: URL
    let createdAt: Date
    let byteCount: Int64
    /// The transcript files that belong to this recording, sorted by extension.
    let transcripts: [URL]

    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    var dateLabel: String {
        createdAt.formatted(date: .abbreviated, time: .shortened)
    }
}

/// Reads the recordings that already exist — `docs/DECISIONS.md` → ADR-021.
///
/// There is **no index file**. The folder is the record: what is on disk is what the list
/// shows, so a recording moved or deleted in Finder needs no reconciliation, and nothing can
/// drift out of step with reality. The cost is that a recording moved elsewhere disappears
/// from the list, which is the honest outcome — the app does not know where it went.
enum RecordingsLibrary {

    /// Reads the recordings in `directory`, newest first.
    ///
    /// - Parameter transcriptSearchPaths: the folders a transcript could be in. Output can go
    ///   beside the source or into a chosen folder, so both are looked at; a duplicate is
    ///   only listed once.
    static func entries(
        in directory: URL,
        transcriptSearchPaths: [URL] = [],
        fileManager: FileManager = .default
    ) -> [RecordingEntry] {
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey, .isRegularFileKey]
        guard
            let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
        else { return [] }

        let searchPaths = [directory] + transcriptSearchPaths

        let entries = contents.compactMap { url -> RecordingEntry? in
            guard url.pathExtension.lowercased() == RecordingFile.fileExtension else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { return nil }

            return RecordingEntry(
                url: url,
                // A file with no creation date is possible on some volumes; the distant past
                // sorts it last rather than dropping it from the list.
                createdAt: values?.creationDate ?? .distantPast,
                byteCount: Int64(values?.fileSize ?? 0),
                transcripts: transcripts(for: url, in: searchPaths, fileManager: fileManager)
            )
        }

        return entries.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            // A stable order for files sharing a timestamp, so the list doesn't shuffle.
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// The transcripts belonging to one recording.
    ///
    /// Matched **exactly**, never by prefix: a recording called `Meeting.m4a` must not claim
    /// an unrelated `Meeting notes.txt` that happens to start with the same word. The only
    /// names accepted are the ones the writers produce — the stem, or the stem plus the live
    /// suffix, with a format's own extension.
    static func transcripts(
        for recording: URL,
        in directories: [URL],
        fileManager: FileManager = .default
    ) -> [URL] {
        let stem = recording.deletingPathExtension().lastPathComponent
        let stems = [stem, stem + LiveTranscriptWriter.liveSuffix]
        let extensions = Set(OutputFormat.allCases.map(\.fileExtension))

        var found: [URL] = []
        var seen = Set<String>()
        for directory in directories {
            for candidateStem in stems {
                for ext in extensions.sorted() {
                    let url = directory.appending(path: "\(candidateStem).\(ext)")
                    guard fileManager.fileExists(atPath: url.path) else { continue }
                    // The same folder can appear twice (output set to "beside the source").
                    guard seen.insert(url.standardizedFileURL.path).inserted else { continue }
                    found.append(url)
                }
            }
        }
        return found
    }

    enum DeleteError: LocalizedError, Equatable {
        case notARecording(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notARecording(let name):
                String(localized: "\(name) is not a recording.")
            case .failed(let detail):
                String(localized: "The recording could not be moved to the Trash: \(detail)")
            }
        }
    }

    /// Moves a recording to the Trash.
    ///
    /// **The Trash, not `removeItem`.** A model file can be downloaded again; a recording of a
    /// conversation that happened once cannot. Deleting it outright would make a misclick
    /// unrecoverable, so this is the one deletion in the app that stays recoverable (ADR-021).
    /// The transcripts are left alone: they are the part worth keeping.
    @discardableResult
    static func moveToTrash(_ recording: URL, fileManager: FileManager = .default) throws -> URL? {
        guard recording.pathExtension.lowercased() == RecordingFile.fileExtension else {
            throw DeleteError.notARecording(recording.lastPathComponent)
        }
        do {
            var trashed: NSURL?
            try fileManager.trashItem(at: recording, resultingItemURL: &trashed)
            return trashed as URL?
        } catch {
            throw DeleteError.failed(error.localizedDescription)
        }
    }
}
