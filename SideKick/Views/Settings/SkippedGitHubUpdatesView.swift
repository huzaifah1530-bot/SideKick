import SwiftUI

struct SkippedGitHubUpdatesView: View {
    @Environment(AppEnvironment.self) private var environment
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
                            VStack(alignment: .leading, spacing: 5) {
                                Text(displayName(for: entry))
                                    .font(.body.weight(.medium))
                                Text(displayBuildTitle(for: entry))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text("\(entry.source.title) · \(repositoryName(for: entry))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if let date = entry.dismissedUpdateDate {
                                    Text("Build date · \(date.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                DisclosureGroup("Identifiers") {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("App ID: \(entry.bundleIdentifier)")
                                        if let key = entry.dismissedUpdateKey {
                                            Text("Build key: \(key)")
                                        }
                                    }
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                }
                                .font(.caption)
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
            let didUndo = try await store.undoSkip(key: key, targetID: entry.bundleIdentifier,
                expectedSource: entry.sourceIdentity)
            if !didUndo {
                errorMessage = "This skipped update or its source changed. The list has been refreshed."
            }
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func displayName(for entry: GitHubUpdateConfiguration) -> String {
        if let app = environment.installedApps.first(where: { $0.id == entry.bundleIdentifier }) {
            return app.name
        }
        if let guest = environment.liveContainerState.apps.first(where: { $0.id == entry.bundleIdentifier }) {
            return guest.name
        }
        if entry.bundleIdentifier.hasPrefix("livecontainer:") {
            let parts = entry.bundleIdentifier.split(separator: ":", omittingEmptySubsequences: false)
            if parts.count == 3,
               let folderData = Data(base64Encoded: String(parts[2])),
               let folder = String(data: folderData, encoding: .utf8) {
                let name = URL(fileURLWithPath: folder).deletingPathExtension().lastPathComponent
                if !name.isEmpty { return "Unavailable · \(name) (LiveContainer)" }
            }
            return "Unavailable LiveContainer app"
        }

        let productID = entry.originalBundleIdentifier ?? entry.bundleIdentifier
        var parts = productID.split(separator: ".").map(String.init)
        if let last = parts.last,
           last.count == 10,
           last.range(of: "^[A-Z0-9]+$", options: .regularExpression) != nil,
           parts.count > 1 {
            parts.removeLast()
        }
        if let name = parts.last, !name.isEmpty {
            return "Unavailable · \(name.replacingOccurrences(of: "-", with: " ").localizedCapitalized)"
        }
        return "Unavailable app"
    }

    private func displayBuildTitle(for entry: GitHubUpdateConfiguration) -> String {
        if let title = entry.dismissedUpdateTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        guard let key = entry.dismissedUpdateKey else { return "Skipped GitHub update" }
        let parts = key.split(separator: ":", omittingEmptySubsequences: false)
        if parts.first == "actions-v2", parts.count > 2 { return "Actions build \(parts[2])" }
        if parts.first == "actions", parts.count > 2 { return "Actions build \(parts[2])" }
        if parts.first == "release", parts.count == 4 {
            return "Release \(parts[2]) · \(parts[3])"
        }
        if parts.first == "release-v2" { return "GitHub release" }
        return "Skipped GitHub update"
    }

    private func repositoryName(for entry: GitHubUpdateConfiguration) -> String {
        guard let url = URL(string: entry.repositoryURL) else { return "GitHub repository" }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return "GitHub repository" }
        let owner = parts[0]
        let repository = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        return "\(owner)/\(repository)"
    }
}
