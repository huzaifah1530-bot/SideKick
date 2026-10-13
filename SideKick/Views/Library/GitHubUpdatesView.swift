import SwiftUI
import UIKit

struct GitHubUpdatesSummaryRow: View {
    let queuedCount: Int
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.app.fill")
                .font(.title2).foregroundStyle(Color.sideKickAccent)
                .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 4) {
                Text("Updates").font(.body.weight(.semibold))
                Text(queuedCount > 0 ? "\(queuedCount) downloaded · \(summary.title)" : summary.title)
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if environment.isCheckingGitHubUpdates {
                ProgressView().accessibilityLabel("Checking GitHub")
            } else if summary.availableCount > 0 {
                Text("\(summary.availableCount)").font(.body.weight(.semibold)).foregroundStyle(Color.sideKickAccent)
            }
        }
        .padding(.vertical, 5)
    }

    private var summary: GitHubUpdateSummary {
        GitHubUpdateSummary(configuredIDs: Set(environment.githubConfigurations.map(\.id)),
            checks: environment.githubChecks, isChecking: environment.isCheckingGitHubUpdates,
            configurationFailed: environment.githubConfigurationError != nil)
    }
}

struct GitHubUpdatesView: View {
    let queuedIPAs: [ImportedIPA]
    @Environment(AppEnvironment.self) private var environment

    private var configurations: [GitHubUpdateConfiguration] {
        environment.githubConfigurations.sorted {
            name(for: $0).localizedCaseInsensitiveCompare(name(for: $1)) == .orderedAscending
        }
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    if environment.isCheckingGitHubUpdates { ProgressView() }
                    Text(summary.title).font(.headline)
                }
                if let date = environment.lastGitHubCheckFinishedAt {
                    Text("Last check finished \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("GitHub is checked on launch. Pull down to check again.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error = environment.githubConfigurationError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                }
                SwiftUI.Button("Check for Updates") { Task { await refresh() } }
                    .disabled(environment.isCheckingGitHubUpdates)
            }

            if !queuedIPAs.isEmpty {
                Section("Downloaded") {
                    ForEach(queuedIPAs) { ipa in
                        NavigationLink {
                            if let installed = installedApp(for: ipa) {
                                AppManagementView(installedApp: installed)
                            } else { AppManagementView(queuedUpdate: ipa) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ipa.name).fontWeight(.semibold)
                                Text("Version \(ipa.version) · \(installedApp(for: ipa) == nil ? "Review installation target" : "Ready to install")")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            rows("Available Updates", states: [.updateAvailable])
            rows("Review Installed Build", states: [.unknownInstalledBuild, .indeterminate])
            rows("Current", states: [.current, .installedAhead])
            rows("Skipped", states: [.skipped])
            rows("Needs Attention", states: [.failed, .noMatchingDownload])
            let pending = configurations.filter { check(for: $0) == nil }
            if !pending.isEmpty {
                Section("Waiting to Check") { ForEach(pending) { configuration in row(configuration) } }
            }
            if configurations.isEmpty, environment.githubConfigurationError == nil {
                Section {
                    ContentUnavailableView("No GitHub Sources", systemImage: "arrow.down.app",
                        description: Text("Open an app in My Apps and choose GitHub Updates to track its builds."))
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Updates")
        .refreshable { await refresh() }
        .task { environment.requestGitHubUpdateCheck() }
    }

    private var summary: GitHubUpdateSummary {
        GitHubUpdateSummary(configuredIDs: Set(configurations.map(\.id)), checks: environment.githubChecks,
            isChecking: environment.isCheckingGitHubUpdates, configurationFailed: environment.githubConfigurationError != nil)
    }

    @ViewBuilder private func rows(_ title: String, states: Set<GitHubCheckState>) -> some View {
        let matches = configurations.filter { configuration in check(for: configuration).map { states.contains($0.state) } ?? false }
        if !matches.isEmpty {
            Section(title) { ForEach(matches) { configuration in row(configuration) } }
        }
    }

    private func row(_ configuration: GitHubUpdateConfiguration) -> some View {
        NavigationLink {
            GitHubAppUpdateStatusView(configuration: configuration)
        } label: {
            HStack(spacing: 12) {
                GitHubUpdateAppIcon(data: icon(for: configuration))
                VStack(alignment: .leading, spacing: 4) {
                    Text(name(for: configuration)).font(.body.weight(.semibold))
                    Text(check(for: configuration)?.state.title ?? "Not Checked Yet")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let installed = configuration.installedBuildLabel {
                        Text("\(check(for: configuration)?.state == .unknownInstalledBuild ? "Last confirmed" : "Installed"): \(installed)")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let build = check(for: configuration)?.latestBuild {
                        Text("Latest: \(build.version)").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .fullWidthListSeparators()
    }

    private func check(for configuration: GitHubUpdateConfiguration) -> GitHubCheckResult? {
        environment.githubChecks.first { $0.targetID == configuration.id && $0.checkedConfiguration == configuration }
    }
    private func name(for configuration: GitHubUpdateConfiguration) -> String {
        environment.installedApps.first { $0.id == configuration.id }?.name
            ?? environment.liveContainerState.apps.first { $0.id == configuration.id }?.name
            ?? configuration.originalBundleIdentifier ?? URL(string: configuration.repositoryURL)?.lastPathComponent ?? "Unavailable App"
    }
    private func installedApp(for ipa: ImportedIPA) -> InstalledAppSummary? {
        if let id = ipa.queuedForInstalledAppID { return environment.installedApps.first { $0.id == id } }
        let matches = environment.installedApps.filter { $0.updateMatchingBundleIdentifiers.contains(ipa.bundleIdentifier.lowercased()) }
        return matches.count == 1 ? matches.first : nil
    }
    private func icon(for configuration: GitHubUpdateConfiguration) -> Data? {
        environment.installedApps.first { $0.id == configuration.id }?.iconData
            ?? environment.liveContainerState.apps.first { $0.id == configuration.id }?.iconData
    }
    @MainActor private func refresh() async {
        await environment.gitHubSettingsChanged()
        await environment.awaitPendingGitHubChecks()
    }
}

private struct GitHubAppUpdateStatusView: View {
    let configuration: GitHubUpdateConfiguration
    @Environment(AppEnvironment.self) private var environment

    private var currentConfiguration: GitHubUpdateConfiguration? {
        environment.githubConfigurations.first { $0.id == configuration.id }
    }
    private var target: GitHubUpdateTarget? {
        environment.installedApps.first { $0.id == configuration.id }?.updateTarget
            ?? environment.liveContainerState.apps.first { $0.id == configuration.id }?.updateTarget
    }
    private var check: GitHubCheckResult? {
        environment.githubChecks.first { $0.targetID == configuration.id && $0.checkedConfiguration == currentConfiguration }
    }
    var body: some View {
        List {
            if let target, let source = currentConfiguration {
                Section("Installed") {
                    LabeledContent("App", value: target.name)
                    LabeledContent("Version", value: target.version)
                    LabeledContent("GitHub build", value: source.installedBuildLabel
                        ?? (source.installedBuild == nil ? "Unconfirmed" : "Confirmed release"))
                    if check?.state == .unknownInstalledBuild {
                        Text("Confirm the exact build you installed. Version names alone do not identify a GitHub build.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("Latest on GitHub") {
                    Text(check?.state.title ?? "Not Checked Yet").font(.headline)
                    if let build = check?.latestBuild {
                        Text(build.title)
                        LabeledContent("File", value: build.assetName)
                        if let date = build.date { LabeledContent("Published", value: date.formatted(date: .abbreviated, time: .shortened)) }
                    }
                    if let detail = check?.detail { Text(detail).foregroundStyle(.secondary).textSelection(.enabled) }
                    if let candidate = check?.candidate {
                        installLink(candidate)
                    }
                    if let date = check?.checkedAt {
                        Text("Checked \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    NavigationLink("Versions & GitHub Source") { GitHubUpdateSettingsView(target: target) }
                    SwiftUI.Button("Check Again") {
                        Task { await environment.gitHubSettingsChanged(); await environment.awaitPendingGitHubChecks() }
                    }.disabled(environment.isCheckingGitHubUpdates)
                }
            } else {
                ContentUnavailableView("App Unavailable", systemImage: "app.dashed",
                    description: Text("Refresh My Apps or reconnect its LiveContainer folder to check this source."))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(target?.name ?? "App Update")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func installLink(_ candidate: GitHubUpdateCandidate) -> some View {
        if candidate.targetKind == .liveContainer {
            NavigationLink("Review in LiveContainer") { LiveContainerGuestDetailView(guestID: candidate.bundleIdentifier) }
        } else if let app = environment.installedApps.first(where: { $0.id == candidate.bundleIdentifier }) {
            NavigationLink(candidate.isKnownNewer ? "Review Update" : "Review Available Build") {
                GitHubUpdateDetailView(candidate: candidate, app: app)
            }
        }
    }
}

private struct GitHubUpdateAppIcon: View {
    let data: Data?
    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: "app.fill").resizable().scaledToFit().foregroundStyle(Color.sideKickAccent).padding(7) }
        }
        .frame(width: 44, height: 44)
        .clipShape(.rect(cornerRadius: 10))
        .accessibilityHidden(true)
    }
}
