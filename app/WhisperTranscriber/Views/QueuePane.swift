import AppKit
import SwiftUI

/// The left pane: the file queue — `docs/UI_SPEC.md` "Queue pane".
struct QueuePane: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        VStack(spacing: 0) {
            if state.queue.items.isEmpty {
                emptyState
            } else {
                List(selection: $state.selectedItemID) {
                    ForEach(state.queue.items) { item in
                        QueueRow(item: item)
                            .tag(item.id)
                            .contextMenu { menu(for: item) }
                    }
                    .onMove { source, destination in
                        state.queue.move(fromOffsets: source, toOffset: destination)
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            footer
        }
        .frame(minWidth: 260)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Drop audio files here")
                .foregroundStyle(.secondary)
            Text("m4a · mp3 · wav · mp4 and others")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text("or press ⇧⌘R to take notes from a call")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Clear completed") {
                state.queue.clearFinished()
            }
            .buttonStyle(.link)
            .font(.caption)
            .disabled(!state.queue.items.contains { $0.state.isFinished })
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var summary: String {
        let items = state.queue.items
        guard !items.isEmpty else { return String(localized: "The queue is empty") }
        let done = items.count { $0.state == .completed }
        let failed = items.count { $0.state == .failed }
        var parts = [String(localized: "\(items.count) files")]
        if done > 0 { parts.append(String(localized: "\(done) done")) }
        if failed > 0 { parts.append(String(localized: "\(failed) failed")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func menu(for item: TranscriptionItem) -> some View {
        if let output = item.result?.outputs.first {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([output.url])
            }
            Button("Copy Text") {
                copyTranscript(of: item)
            }
            Divider()
        }
        if item.state.isFinished {
            Button("Retry") { state.retry(item) }
        }
        Button("Remove from Queue", role: .destructive) {
            state.queue.remove(item)
        }
        .disabled(item.state == .running)
    }

    private func copyTranscript(of item: TranscriptionItem) {
        let text: String
        if let txt = item.result?.outputs.first(where: { $0.format == "txt" }),
            let contents = try? String(contentsOf: txt.url, encoding: .utf8)
        {
            text = contents
        } else {
            text = item.transcript
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A single row in the queue.
struct QueueRow: View {
    @Bindable var item: TranscriptionItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon
                .frame(width: 16)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    Text(item.statusText)
                        .font(.caption)
                        .foregroundStyle(item.state == .failed ? .red : .secondary)
                        .lineLimit(2)

                    if item.state == .running, let fraction = item.fraction {
                        // Nothing to localize; a number plus a percent sign.
                        Text(verbatim: "%\(Int(fraction * 100))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                if item.state == .running {
                    ProgressView(value: item.fraction)
                        .progressViewStyle(.linear)
                        .controlSize(.small)

                    if let time = item.timeText {
                        Text(time)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .help(item.failure?.suggestion ?? item.url.path)
        // The row is read as a single element; without this, VoiceOver walks the file name,
        // the state and the percentage separately.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.name)
        .accessibilityValue(accessibilityValue)
    }

    /// The state text VoiceOver reads for the row.
    private var accessibilityValue: String {
        guard item.state == .running, let fraction = item.fraction else { return item.statusText }
        return String(localized: "\(item.statusText), \(Int(fraction * 100)) percent")
    }

    @ViewBuilder
    private var icon: some View {
        switch item.state {
        case .queued:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running:
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.tint)
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "slash.circle").foregroundStyle(.secondary)
        }
    }
}
