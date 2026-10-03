import Foundation

/// Something that has been through the app before — `docs/DECISIONS.md` → ADR-024.
struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {

    enum Kind: String, Codable, Sendable {
        /// Recorded by the app.
        case recording
        /// Dropped in or opened.
        case file
    }

    var source: URL
    var kind: Kind
    var date: Date
    /// The files the run produced. Filtered against the disk when read, so a transcript the
    /// user has since deleted does not keep being offered.
    var outputs: [URL]
    var model: String?
    var language: String?

    /// Keyed by the source, which is what makes a recording and its later re-runs one row
    /// rather than several.
    var id: String { source.standardizedFileURL.path }
    var name: String { source.deletingPathExtension().lastPathComponent }

    var dateLabel: String { date.formatted(date: .abbreviated, time: .shortened) }

    var symbol: String { kind == .recording ? "waveform" : "doc" }

    /// Whether an output file is the live preview rather than the accurate pass.
    ///
    /// Told apart by the suffix the writer gives it, which is the only difference in the
    /// name — `Meeting (live).txt` beside `Meeting.txt`.
    static func isLive(_ url: URL) -> Bool {
        url.deletingPathExtension().lastPathComponent.hasSuffix(LiveTranscriptWriter.liveSuffix)
    }

    /// The label for an output in the picker: the format, and whether it is the live one.
    static func label(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return isLive(url) ? String(localized: "\(ext) · live") : ext
    }

    /// The live transcript, if one was kept.
    var liveOutput: URL? { outputs.first(where: Self.isLive) }
}

/// The record of past work, kept in `history.json`.
///
/// Unlike the recordings folder (ADR-021), a dropped file leaves nothing behind that can be
/// scanned: it could be anywhere on disk, and its outputs sit beside it or in a chosen folder.
/// For those, a written record is the only way to answer "what have I transcribed" — so this
/// is a stored list, and the recordings folder is merged into it rather than replaced by it.
enum JobHistory {

    /// Entries kept. Old enough that it covers any real use, small enough that the file stays
    /// trivial to read and write whole.
    static let limit = 500

    static func load(from url: URL) -> [HistoryEntry] {
        guard
            let data = try? Data(contentsOf: url),
            let entries = try? JSONDecoder().decode([HistoryEntry].self, from: data)
        else { return [] }
        return entries
    }

    @discardableResult
    static func save(_ entries: [HistoryEntry], to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entries).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Adds an entry, newest first, replacing any earlier run of the same source.
    ///
    /// Transcribing the same file twice should update the row rather than add a second one:
    /// the list answers "what have I done", not "how many times".
    static func adding(_ entry: HistoryEntry, to entries: [HistoryEntry]) -> [HistoryEntry] {
        var result = entries.filter { $0.id != entry.id }
        result.insert(entry, at: 0)
        result.sort { $0.date > $1.date }
        return Array(result.prefix(limit))
    }

    /// The list to show: the stored entries plus any recording that has never been
    /// transcribed, newest first.
    ///
    /// A recording already in the stored list keeps its stored entry, which is the one that
    /// knows what it produced.
    static func merged(
        stored: [HistoryEntry],
        recordings: [RecordingEntry]
    ) -> [HistoryEntry] {
        let known = Set(stored.map(\.id))

        let extras =
            recordings
            .filter { !known.contains($0.url.standardizedFileURL.path) }
            .map {
                HistoryEntry(
                    source: $0.url,
                    kind: .recording,
                    date: $0.createdAt,
                    outputs: $0.transcripts,
                    model: nil,
                    language: nil
                )
            }
        return (stored + extras).sorted { $0.date > $1.date }
    }

    /// Brings an entry's outputs in line with the disk.
    ///
    /// Two directions, and both matter. Outputs that have been deleted are **dropped**, so
    /// the list never offers to open a file that is gone. Transcripts found beside the source
    /// are **added**, which is how the live text appears next to the accurate one — it is
    /// written when the recording ends, before the job that gets stored, so it was never in
    /// the stored list (ADR-025).
    ///
    /// An entry whose source is gone is kept: it is still a record of work done, and the view
    /// marks it.
    static func refreshed(
        _ entries: [HistoryEntry],
        discoveringIn directories: [URL] = [],
        fileManager: FileManager = .default
    ) -> [HistoryEntry] {
        entries.map { entry in
            var copy = entry
            var outputs = entry.outputs.filter { fileManager.fileExists(atPath: $0.path) }
            var seen = Set(outputs.map(\.standardizedFileURL.path))

            let searchPaths = [entry.source.deletingLastPathComponent()] + directories
            for found in RecordingsLibrary.transcripts(
                for: entry.source, in: searchPaths, fileManager: fileManager)
            where seen.insert(found.standardizedFileURL.path).inserted {
                outputs.append(found)
            }

            // The **accurate** text first, and so the one opened by default. The live
            // version is a preview with known inaccuracies; making it the default would hand
            // the user the worse of the two every time. It sits beside it in the picker.
            copy.outputs = outputs.sorted { lhs, rhs in
                let lhsLive = HistoryEntry.isLive(lhs)
                let rhsLive = HistoryEntry.isLive(rhs)
                if lhsLive != rhsLive { return !lhsLive }
                return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent)
                    == .orderedAscending
            }
            return copy
        }
    }
}
