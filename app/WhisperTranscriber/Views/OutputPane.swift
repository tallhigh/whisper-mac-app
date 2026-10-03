import AppKit
import SwiftUI

/// The bottom-right pane: the TEXT and LOG tabs — `docs/UI_SPEC.md`.
struct OutputPane: View {
    @Environment(AppState.self) private var state
    @State private var tab = Tab.transcript
    @State private var autoScroll = true

    enum Tab: String, CaseIterable, Identifiable {
        case transcript, log
        var id: String { rawValue }
        var title: String {
            switch self {
            case .transcript: String(localized: "TEXT")
            case .log: String(localized: "LOG")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // In the History tab the picker lists the row's transcripts instead of
            // TEXT/LOG: a recording has both a live and an accurate version, and which one
            // you are reading is the thing worth choosing (ADR-025).
            if state.sidebarTab == .history {
                if state.historyOutputs.count > 1 {
                    Picker("Transcript", selection: historyOutputBinding) {
                        ForEach(state.historyOutputs, id: \.self) { url in
                            Text(HistoryEntry.label(for: url)).tag(url)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(8)
                } else if let url = state.selectedHistoryOutput {
                    Text(HistoryEntry.label(for: url))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(8)
                }
            } else {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(8)
            }

            Divider()

            Group {
                // The History tab reads a finished transcript off disk; the queue shows the
                // one being produced. Which pane is showing decides which (ADR-024).
                if state.sidebarTab == .history {
                    historyText
                } else if let item = state.selectedItem {
                    switch tab {
                    case .transcript: transcript(item)
                    case .log: log(item)
                    }
                } else {
                    placeholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            actions
        }
        .frame(minHeight: 180)
    }

    private var placeholder: some View {
        Text("Select a file")
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// `Picker` writes through a binding; the state owns which transcript is loaded.
    private var historyOutputBinding: Binding<URL> {
        Binding(
            get: { state.selectedHistoryOutput ?? state.historyOutputs.first ?? URL(filePath: "/") },
            set: { state.selectHistoryOutput($0) }
        )
    }

    /// The transcript of the selected history row, read from disk.
    @ViewBuilder
    private var historyText: some View {
        if let text = state.historyText {
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .font(.body.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        } else if let message = state.historyTextError {
            Text(message)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("Select something from the history")
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Text

    private func transcript(_ item: TranscriptionItem) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(item.transcript.isEmpty ? waitingText(item) : item.transcript)
                    .font(.body)
                    .foregroundStyle(item.transcript.isEmpty ? .tertiary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .id("transcript-end")
            }
            .onChange(of: item.transcript) {
                guard autoScroll else { return }
                withAnimation { proxy.scrollTo("transcript-end", anchor: .bottom) }
            }
        }
    }

    private func waitingText(_ item: TranscriptionItem) -> String {
        switch item.state {
        case .queued: String(localized: "This file is waiting in the queue.")
        case .running: String(localized: "The text will appear here as the segments arrive.")
        case .cancelled: String(localized: "The job was cancelled.")
        case .failed: item.failure?.message ?? String(localized: "The job failed.")
        case .completed: String(localized: "No text was produced.")
        }
    }

    // MARK: - Log

    private func log(_ item: TranscriptionItem) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(item.logLines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(color(for: line))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }

                    if let failure = item.failure, !failure.detail.isEmpty {
                        Text(failure.detail)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                }
                .padding(12)
            }
            .onChange(of: item.logLines.count) {
                guard autoScroll, let last = item.logLines.indices.last else { return }
                proxy.scrollTo(last, anchor: .bottom)
            }
        }
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("[error]") { return .red }
        if line.hasPrefix("[warning]") || line.hasPrefix("[undecodable]") { return .orange }
        return .secondary
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 10) {
            if let item = state.selectedItem, let failure = item.failure,
                let suggestion = failure.suggestion
            {
                Label(suggestion, systemImage: "lightbulb")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Toggle("Follow", isOn: $autoScroll)
                .toggleStyle(.checkbox)
                .font(.caption)

            Button("Copy") { copy() }
                .disabled(state.selectedItem == nil)

            Button("Reveal in Finder") { reveal() }
                .disabled(state.selectedItem?.result?.outputs.isEmpty ?? true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func copy() {
        guard let item = state.selectedItem else { return }
        let text = tab == .transcript ? item.transcript : item.logLines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func reveal() {
        guard let outputs = state.selectedItem?.result?.outputs, !outputs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(outputs.map(\.url))
    }
}
