import AppKit
import SwiftUI

/// Everything that has been through the app before — `docs/UI_SPEC.md` → Left pane.
///
/// Recordings and dropped files in one list, because from the user's side they are the same
/// question: what have I transcribed, and where did the text go (ADR-024). Selecting a row
/// reads its transcript into the output pane, so a past recording can be read without
/// leaving the app.
struct HistoryPane: View {
    @Environment(AppState.self) private var state

    @State private var entries: [HistoryEntry] = []
    @State private var entryToTrash: HistoryEntry?

    var body: some View {
        @Bindable var state = state

        Group {
            if entries.isEmpty {
                emptyState
            } else {
                List(entries, selection: selectionBinding) { entry in
                    row(entry)
                        .tag(entry.id)
                        .contextMenu { menu(for: entry) }
                }
                .listStyle(.inset)
            }
        }
        .onAppear(perform: reload)
        // A recording finishing, or a job completing, should show up here without a click.
        .onChange(of: state.recording.isFinalizing) { _, busy in if !busy { reload() } }
        .onChange(of: state.history) { _, _ in reload() }
        .confirmationDialog(
            trashPrompt,
            isPresented: .init(
                get: { entryToTrash != nil }, set: { if !$0 { entryToTrash = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let entry = entryToTrash { trash(entry) }
                entryToTrash = nil
            }
            Button("Cancel", role: .cancel) { entryToTrash = nil }
        } message: {
            Text("The transcripts are kept. You can recover the audio from the Trash.")
        }
        .safeAreaInset(edge: .bottom) { footer }
    }

    // MARK: - Rows

    private func row(_ entry: HistoryEntry) -> some View {
        let missing = !FileManager.default.fileExists(atPath: entry.source.path)
        return HStack(spacing: 8) {
            Image(systemName: entry.symbol)
                .foregroundStyle(missing ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .lineLimit(1)
                    .foregroundStyle(missing ? .secondary : .primary)
                HStack(spacing: 4) {
                    Text(entry.dateLabel)
                    if !entry.outputs.isEmpty {
                        Text(verbatim: "· \(entry.outputs.map(\.pathExtension).joined(separator: " "))")
                            .monospaced()
                    }
                    // The row stays: it is still a record of work done, and silently dropping
                    // it would be the app deciding the user's history for them.
                    if missing { Text("· file missing") }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func menu(for entry: HistoryEntry) -> some View {
        Button("Transcribe Again") { state.transcribeAgain(entry.source) }
            .disabled(!FileManager.default.fileExists(atPath: entry.source.path))
        Button("Show in Finder") { reveal(entry.source) }
        if !entry.outputs.isEmpty {
            Divider()
            ForEach(entry.outputs, id: \.self) { output in
                Button("Open \(output.lastPathComponent)") { NSWorkspace.shared.open(output) }
            }
        }
        Divider()
        if entry.kind == .recording {
            Button("Move Audio to Trash…", role: .destructive) { entryToTrash = entry }
        }
        Button("Remove from History") {
            state.forgetHistory(entry)
            reload()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Nothing here yet")
                .foregroundStyle(.secondary)
            Text("Finished files and recordings are listed here")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var footer: some View {
        HStack {
            Text(countLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Show Folder") { reveal(state.recordingDirectory) }
                .font(.caption)
                .buttonStyle(.link)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var countLabel: String {
        let recordings = entries.count { $0.kind == .recording }
        return String(localized: "\(entries.count) items · \(recordings) recordings")
    }

    private var trashPrompt: String {
        guard let entry = entryToTrash else { return String(localized: "Move to the Trash?") }
        return String(localized: "Move \(entry.name) to the Trash?")
    }

    // MARK: - Actions

    /// `List` selects by tag; the state keeps the loaded transcript next to the id.
    private var selectionBinding: Binding<String?> {
        Binding(
            get: { state.selectedHistoryID },
            set: { id in state.selectHistory(entries.first { $0.id == id }) }
        )
    }

    private func reload() {
        entries = state.historyEntries()
    }

    private func trash(_ entry: HistoryEntry) {
        state.moveRecordingToTrash(entry.source)
        reload()
    }

    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
