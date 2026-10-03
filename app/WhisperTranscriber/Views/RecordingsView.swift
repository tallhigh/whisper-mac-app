import AppKit
import SwiftUI

/// The recordings already on disk — `docs/UI_SPEC.md` → Recordings window.
///
/// A window of its own rather than a pane: the queue is about what is running now, and this
/// is about what happened before. It reads the folder each time it appears, so a file removed
/// in Finder is simply gone from the list (ADR-021).
struct RecordingsView: View {
    @Environment(AppState.self) private var state

    @State private var entries: [RecordingEntry] = []
    @State private var selection: URL?
    @State private var entryToTrash: RecordingEntry?

    var body: some View {
        VStack(spacing: 0) {
            if entries.isEmpty {
                emptyState
            } else {
                list
            }

            Divider()
            footer
        }
        .frame(minWidth: 460, minHeight: 320)
        .navigationTitle("Recordings")
        .onAppear(perform: reload)
        // A recording finishing while this window is open should appear in it.
        .onChange(of: state.recording.isFinalizing) { _, finalizing in
            if !finalizing { reload() }
        }
        .confirmationDialog(
            trashPrompt,
            isPresented: .init(
                get: { entryToTrash != nil }, set: { if !$0 { entryToTrash = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let entry = entryToTrash { state.moveRecordingToTrash(entry) }
                entryToTrash = nil
                reload()
            }
            Button("Cancel", role: .cancel) { entryToTrash = nil }
        } message: {
            Text("The transcripts are kept. You can recover the audio from the Trash.")
        }
    }

    private var list: some View {
        List(entries, selection: $selection) { entry in
            row(entry)
                .tag(entry.url)
                .contextMenu {
                    Button("Transcribe Again") { state.transcribeAgain(entry) }
                    Button("Show in Finder") { reveal(entry.url) }
                    if !entry.transcripts.isEmpty {
                        Divider()
                        ForEach(entry.transcripts, id: \.self) { transcript in
                            Button("Open \(transcript.lastPathComponent)") {
                                NSWorkspace.shared.open(transcript)
                            }
                        }
                    }
                    Divider()
                    Button("Move to Trash…", role: .destructive) { entryToTrash = entry }
                }
        }
        .listStyle(.inset)
    }

    private func row(_ entry: RecordingEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .lineLimit(1)
                Text(verbatim: "\(entry.dateLabel) · \(entry.sizeLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // What came out of it matters more than the audio did, so the formats are the
            // thing on the right.
            if entry.transcripts.isEmpty {
                Text("no transcript")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text(verbatim: entry.transcripts.map(\.pathExtension).joined(separator: " · "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No recordings yet")
                .foregroundStyle(.secondary)
            Text("Press ⇧⌘R in the main window to record one")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Button("Show Folder") { reveal(state.recordingDirectory) }

            if let selected = entries.first(where: { $0.url == selection }) {
                Button("Transcribe Again") { state.transcribeAgain(selected) }
                Button("Move to Trash…", role: .destructive) { entryToTrash = selected }
            }

            Spacer()

            if let message = state.recordingsError {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            } else {
                Text(countLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Refresh", systemImage: "arrow.clockwise", action: reload)
                .labelStyle(.iconOnly)
        }
        .padding(8)
    }

    private var countLabel: String {
        let total = entries.reduce(Int64(0)) { $0 + $1.byteCount }
        let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        return String(localized: "\(entries.count) recordings · \(size)")
    }

    private var trashPrompt: String {
        guard let entry = entryToTrash else { return String(localized: "Move to the Trash?") }
        return String(localized: "Move \(entry.name) to the Trash?")
    }

    private func reload() {
        entries = state.pastRecordings()
        if let selection, !entries.contains(where: { $0.url == selection }) {
            self.selection = nil
        }
    }

    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
