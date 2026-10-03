import Foundation

/// The text accumulating in a live session.
///
/// It holds only the **committed** pieces; the provisional text appears on screen but is
/// not written to a file. Timestamps are absolute from the start of the recording.
struct LiveTranscript: Equatable, Sendable {

    private(set) var segments: [EngineEvent.Committed] = []

    var isEmpty: Bool { segments.isEmpty }

    mutating func append(_ segment: EngineEvent.Committed) {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        segments.append(
            EngineEvent.Committed(text: text, start: segment.start, end: segment.end))
    }

    mutating func removeAll() {
        segments.removeAll()
    }

    /// The text as one piece, for reading.
    var joined: String {
        segments.map(\.text).joined(separator: " ")
    }

    /// The `txt` format: every segment on its own line, as whisper's writer does it.
    var plainText: String {
        segments.map(\.text).joined(separator: "\n") + "\n"
    }

    /// The `notes` format: the same layout as the worker's `write_notes` output.
    var notesText: String {
        segments
            .map { "- [\(TranscriptionItem.clock($0.start))] \($0.text)" }
            .joined(separator: "\n") + "\n"
    }

    /// The formats this text can produce.
    ///
    /// Only `txt` and `notes`: we have the segment text and a timestamp, and not the fields
    /// `srt`/`vtt`/`json`/`tsv` need. The second pass (whisper's own writers) produces
    /// those — we don't imitate whisper's formats (CLAUDE.md, architecture rule 5).
    static let writableFormats: Set<OutputFormat> = [.txt, .notes]

    func text(for format: OutputFormat) -> String? {
        switch format {
        case .txt: plainText
        case .notes: notesText
        case .srt, .vtt, .json, .tsv: nil
        }
    }
}

/// Writes the live text to disk.
///
/// Runs the instant "Finish" is pressed (`docs/LIVE_TRANSCRIPTION.md` →
/// Persistence of the live text).
enum LiveTranscriptWriter {

    /// If the accurate pass is coming too, the live text goes to a file of its own.
    ///
    /// An earlier design wrote both to the same file, and because the second pass overwrote
    /// the live text, it was lost. Two separate files both preserve the live text and remove
    /// the need for an exception to the overwrite check: there is no colliding name any more.
    static var liveSuffix: String { String(localized: " (live)") }

    @discardableResult
    static func write(
        _ transcript: LiveTranscript,
        for audio: URL,
        settings: WhisperSettings,
        suffixed: Bool
    ) -> [URL] {
        guard !transcript.isEmpty else { return [] }

        let directory = settings.resolvedOutputDirectory(for: audio)
        let stem = audio.deletingPathExtension().lastPathComponent + (suffixed ? liveSuffix : "")
        var written: [URL] = []

        for format in OutputFormat.allCases where settings.outputFormats.contains(format) {
            guard let text = transcript.text(for: format) else { continue }
            let url = directory.appending(path: "\(stem).\(format.fileExtension)")
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
                written.append(url)
            } catch {
                continue
            }
        }
        return written
    }
}
