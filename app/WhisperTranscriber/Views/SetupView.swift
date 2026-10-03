import SwiftUI

/// The first-launch setup screen — docs/UI_SPEC.md "Setup screen".
///
/// Setup doesn't start by itself: what will be downloaded, how much room it takes and that
/// the system is left alone are all spelled out first.
struct SetupView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 24) {
            header

            switch state.runtime {
            case .installing(let step, let fraction):
                progress(step: step, fraction: fraction)
            case .broken:
                failure
            default:
                invitation
            }
        }
        .padding(40)
        .frame(minWidth: 560, minHeight: 440)
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
            Text("Setup required")
                .font(.title2.weight(.semibold))
        }
    }

    // MARK: - The invitation

    private var invitation: some View {
        VStack(spacing: 20) {
            Text(
                """
                Whisper Transcriber takes notes on this Mac — no bot joins your calls and \
                no audio leaves the machine. To do that it installs an isolated Python \
                environment of its own.
                """
            )
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 420)

            VStack(alignment: .leading, spacing: 8) {
                bullet("arrow.down.circle", "About 850 MB to download, 890 MB on disk")
                bullet("clock", "~1 minute on a fast connection, once only")
                bullet("lock.shield", "Your system Python and Homebrew are left alone")
                bullet("wifi.slash", "Works offline once installed — no account, no API key")
                bullet("folder", layout)
            }
            .frame(maxWidth: 420, alignment: .leading)

            Button("Start Setup") { state.startProvisioning() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var layout: String {
        String(localized: "Setup location: ~/Library/Application Support/WhisperTranscriber")
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).font(.callout)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
    }

    // MARK: - Progress

    private func progress(step: ProvisionStep, fraction: Double) -> some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                // Real progress, not indeterminate: based on the steps' measured weights.
                ProgressView(value: fraction)
                    .frame(maxWidth: 420)
                    .accessibilityLabel("Setup progress")
                    .accessibilityValue(String(localized: "\(Int(fraction * 100)) percent"))
                Text("\(step.rawValue)/\(ProvisionStep.count) · \(step.title)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if step == .installDependencies {
                Text("This is the longest step; it can take a few minutes.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            logPane

            Button("Cancel", role: .cancel) { state.cancelProvisioning() }
        }
    }

    private var logPane: some View {
        DisclosureGroup("Details") {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(state.setupLog.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .frame(height: 120)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))
        }
        .frame(maxWidth: 420)
    }

    // MARK: - Error

    private var failure: some View {
        VStack(spacing: 16) {
            if let error = state.setupError {
                Text(error.message)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)

                if !error.detail.isEmpty {
                    ScrollView {
                        Text(error.detail)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxWidth: 460, maxHeight: 160)
                    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))
                }
            } else if case .broken(let reason) = state.runtime {
                Text(reason)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
                    .textSelection(.enabled)
            }

            HStack(spacing: 12) {
                // The cheap thing first: retry without deleting the environment.
                Button("Try Again") {
                    Task { await state.retryHealthCheck() }
                }
                .buttonStyle(.borderedProminent)

                Button("Reinstall Environment") { state.startProvisioning() }
                    .help("Deletes the runtime and installs it from scratch (~850 MB download)")

                Button("Copy Log") { copyLog() }
                Button("Open Log Folder") {
                    NSWorkspace.shared.open(state.layout.logs)
                }
            }
        }
    }

    private func copyLog() {
        let text = (state.setupLog + [state.setupError?.detail ?? ""])
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

#Preview("Setup") {
    SetupView().environment(AppState())
}
