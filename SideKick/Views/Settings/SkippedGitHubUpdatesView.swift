import SwiftUI

struct SkippedGitHubUpdatesView: View {
    @State private var entries: [GitHubUpdateConfiguration] = []
    @State private var errorMessage: String?

    private let store = GitHubUpdateConfigurationStore.shared

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView("No Skipped Updates", systemImage: "checkmark.circle",
                    description: Text("Updates you skip will appear here."))
            } else {
                Section {
                    ForEach(entries) { entry in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.bundleIdentifier)
                                    .font(.body.weight(.medium))
                                Text(entry.repositoryURL)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if let key = entry.dismissedUpdateKey {
                                    Text(key)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer(minLength: 8)
                            SwiftUI.Button("Undo") {
                                Task { await undo(entry) }
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 4)
                    }
                } footer: {
                    Text("Undoing a skip makes that build eligible to appear again the next time updates are checked.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Skipped Updates")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .sideKickGitHubSettingsDidChange)) { _ in
            Task { await reload() }
        }
        .alert("Skipped Updates", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            SwiftUI.Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @MainActor
    private func reload() async {
        do {
            let configurations = try await store.all()
            entries = configurations.filter { $0.dismissedUpdateKey != nil }
                .sorted { $0.bundleIdentifier.localizedCaseInsensitiveCompare($1.bundleIdentifier) == .orderedAscending }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func undo(_ entry: GitHubUpdateConfiguration) async {
        guard let key = entry.dismissedUpdateKey else { return }
        do {
            _ = try await store.undoSkip(key: key, targetID: entry.bundleIdentifier,
                expectedSource: entry.sourceIdentity)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
