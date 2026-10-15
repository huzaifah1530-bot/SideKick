import SwiftUI

struct GitHubDiagnosticsView: View {
    @State private var entries: [GitHubDiagnosticsStore.Entry] = []
    @State private var persistenceFailed = false
    @State private var confirmingClear = false

    var body: some View {
        List {
            Section {
                Text("Recent automatic checks, app checks, and GitHub responses. Tokens, passwords and response bodies are excluded. Logs stay on this device unless you share them.")
                    .font(.footnote).foregroundStyle(.secondary)
                if persistenceFailed {
                    Label("Recent events are available, but the log could not be saved on this device.", systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if entries.isEmpty {
                ContentUnavailableView("No Update Logs Yet", systemImage: "list.bullet.clipboard", description: Text("Pull to refresh My Apps or open an app’s GitHub versions to record a check."))
            } else {
                Section {
                    ShareLink(item: GitHubDiagnosticsStore.export(entries)) {
                        Label("Share Update Logs", systemImage: "square.and.arrow.up")
                    }
                    SwiftUI.Button("Clear Logs", role: .destructive) { confirmingClear = true }
                }
                Section("Recent activity") {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(entry.event.title).fontWeight(.medium)
                                Spacer()
                                Text(entry.date, style: .time).font(.caption).foregroundStyle(.secondary)
                            }
                            if !entry.details.isEmpty {
                                Text(entry.details).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Text(entry.date, style: .date).font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
        .navigationTitle("GitHub Update Logs")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload() }
        .task {
            while !Task.isCancelled {
                await reload()
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
            }
        }
        .confirmationDialog("Clear GitHub update logs?", isPresented: $confirmingClear, titleVisibility: .visible) {
            SwiftUI.Button("Clear Logs", role: .destructive) {
                Task { await GitHubDiagnosticsStore.shared.clear(); await reload() }
            }
        } message: { Text("This removes diagnostic history from this device. Your update sources and installed builds stay saved.") }
    }

    @MainActor private func reload() async {
        let snapshot = await GitHubDiagnosticsStore.shared.snapshot()
        entries = snapshot.entries
        persistenceFailed = snapshot.persistenceFailed
    }
}
