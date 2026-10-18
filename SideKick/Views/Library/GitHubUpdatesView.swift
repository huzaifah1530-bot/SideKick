import SwiftUI
import UIKit

struct GitHubUpdatesSummaryRow: View {
    let queuedCount: Int
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let hasUpdates = summary.availableCount > 0 || queuedCount > 0
        HStack(spacing: Spacing.s) {
            Image(systemName: hasUpdates ? "arrow.down.circle.fill" : "arrow.down.circle")
                .font(.title3)
                .foregroundStyle(hasUpdates ? Color.sideKickAccent : Color.secondary)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Updates").font(.body.weight(.semibold))
                Text(queuedCount > 0 ? "\(queuedCount) downloaded · \(summary.title)" : summary.title)
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if environment.isCheckingGitHubUpdates {
                ProgressView().accessibilityLabel("Checking GitHub")
            } else if summary.availableCount > 0 {
                Text("\(summary.availableCount)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.sideKickOnAccent)
                    .padding(.horizontal, Spacing.xs)
                    .frame(minWidth: 24, minHeight: 24)
                    .background(Color.sideKickAccent, in: Capsule())
                    .accessibilityLabel("\(summary.availableCount) available")
            }
        }
        .padding(.vertical, Spacing.xxs)
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
    @Environment(\.openURL) private var openURL
    @State private var sourceConfigurationID: String?
    @State private var statusConfigurationID: String?

    private var configurations: [GitHubUpdateConfiguration] {
        environment.githubConfigurations.sorted {
            name(for: $0).localizedCaseInsensitiveCompare(name(for: $1)) == .orderedAscending
        }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Spacing.xs) {
                        if environment.isCheckingGitHubUpdates { ProgressView() }
                        Text(summary.title).font(.title3.weight(.semibold))
                    }
                    if let date = environment.lastGitHubCheckFinishedAt {
                        Text("Checked \(date.formatted(.relative(presentation: .named)))")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: Spacing.xxs, bottom: 0, trailing: Spacing.xxs))
                if let error = environment.githubConfigurationError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }

            if !queuedIPAs.isEmpty {
                Section("Downloaded") {
                    ForEach(queuedIPAs) { ipa in
                        NavigationLink {
                            if let installed = installedApp(for: ipa) {
                                AppManagementView(installedApp: installed)
                            } else { AppManagementView(queuedUpdate: ipa) }
                        } label: {
                            SideKickLibraryAppRow(
                                name: ipa.name,
                                versionText: installedApp(for: ipa) == nil ? "\(ipa.version) · Choose which app to update" : "\(ipa.version) · Ready to install",
                                iconData: ipa.iconData,
                                metadata: { EmptyView() },
                                status: { EmptyView() }
                            )
                        }
                        .contextMenu {
                            if let installed = installedApp(for: ipa) {
                                SwiftUI.Button {
                                    UIApplication.shared.open(InstalledApp.openAppURL(targetBundleIdentifier: installed.resignedBundleIdentifier))
                                } label: {
                                    Label("Open Current Version", systemImage: "arrow.up.forward.app")
                                }
                            }
                            SwiftUI.Button {
                                UIPasteboard.general.string = ipa.bundleIdentifier
                            } label: {
                                Label("Copy Bundle ID", systemImage: "doc.on.doc")
                            }
                        }
                    }
                }
            }

            rows("Available", states: [.updateAvailable])
            rows("Needs Attention", states: [.failed, .noMatchingDownload, .unknownInstalledBuild, .indeterminate])
            rows("Up to Date", states: [.current, .installedAhead, .skipped], includeUnchecked: true)
            if configurations.isEmpty, environment.githubConfigurationError == nil {
                ContentUnavailableView("No Update Sources", systemImage: "arrow.down.circle",
                    description: Text("Open an app in My Apps and choose GitHub Updates to track its builds."))
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Updates")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                SwiftUI.Button { Task { await refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Check for Updates")
                .disabled(environment.isCheckingGitHubUpdates)
            }
        }
        .refreshable { await refresh() }
        .navigationDestination(item: $sourceConfigurationID) { id in
            if let target = updateTarget(for: id) {
                GitHubUpdateSettingsView(target: target)
            }
        }
        .navigationDestination(item: $statusConfigurationID) { id in
            if let configuration = configurations.first(where: { $0.id == id }) {
                GitHubAppUpdateStatusView(configuration: configuration)
            }
        }
        .task { environment.requestGitHubUpdateCheck() }
    }

    private var summary: GitHubUpdateSummary {
        GitHubUpdateSummary(configuredIDs: Set(configurations.map(\.id)), checks: environment.githubChecks,
            isChecking: environment.isCheckingGitHubUpdates, configurationFailed: environment.githubConfigurationError != nil)
    }

    @ViewBuilder private func rows(_ title: String, states: Set<GitHubCheckState>, includeUnchecked: Bool = false) -> some View {
        let matches = configurations.filter { configuration in check(for: configuration).map { states.contains($0.state) } ?? includeUnchecked }
        if !matches.isEmpty {
            Section(title) { ForEach(matches) { configuration in row(configuration) } }
        }
    }

    private func row(_ configuration: GitHubUpdateConfiguration) -> some View {
        NavigationLink {
            if let candidate = check(for: configuration)?.candidate,
               let app = environment.installedApps.first(where: { $0.id == configuration.id }) {
                GitHubUpdateDetailView(candidate: candidate, app: app)
            } else {
                GitHubAppUpdateStatusView(configuration: configuration)
            }
        } label: {
            let result = check(for: configuration)
            SideKickLibraryAppRow(
                name: name(for: configuration),
                versionText: rowSubtitle(configuration, result: result),
                iconData: icon(for: configuration),
                metadata: { EmptyView() },
                status: {
                    switch result?.state {
                    case .updateAvailable?:
                        StatusBadge(title: "Update", systemImage: "arrow.down.circle.fill", tone: .accent)
                    case .failed?, .noMatchingDownload?:
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityLabel("Needs attention")
                    case .skipped?:
                        Text("Skipped").font(.subheadline).foregroundStyle(.secondary)
                    default:
                        EmptyView()
                    }
                }
            )
        }
        .contextMenu { updateMenu(configuration) }
    }

    @ViewBuilder
    private func updateMenu(_ configuration: GitHubUpdateConfiguration) -> some View {
        let result = check(for: configuration)
        let installed = environment.installedApps.first { $0.id == configuration.id }
        Section {
            if result?.candidate != nil {
                SwiftUI.Button { statusConfigurationID = configuration.id } label: {
                    Label("Review Update", systemImage: "arrow.down.circle")
                }
            }
            SwiftUI.Button {
                Task { await refresh() }
            } label: {
                Label("Check Now", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(environment.isCheckingGitHubUpdates)
            if let installed {
                SwiftUI.Button {
                    UIApplication.shared.open(InstalledApp.openAppURL(targetBundleIdentifier: installed.resignedBundleIdentifier))
                } label: {
                    Label("Open App", systemImage: "arrow.up.forward.app")
                }
            }
        }
        Section {
            SwiftUI.Button { sourceConfigurationID = configuration.id } label: {
                Label("Update Source…", systemImage: "slider.horizontal.3")
            }
            if let url = URL(string: configuration.repositoryURL) {
                SwiftUI.Button { openURL(url) } label: {
                    Label("View on GitHub", systemImage: "safari")
                }
                SwiftUI.Button {
                    UIPasteboard.general.string = configuration.repositoryURL
                } label: {
                    Label("Copy Repository Link", systemImage: "link")
                }
            }
        }
    }

    private func updateTarget(for id: String) -> GitHubUpdateTarget? {
        environment.installedApps.first { $0.id == id }?.updateTarget
            ?? environment.liveContainerState.apps.first { $0.id == id }?.updateTarget
    }

    private func rowSubtitle(_ configuration: GitHubUpdateConfiguration, result: GitHubCheckResult?) -> String {
        guard let result else { return "Not checked yet" }
        if result.state == .updateAvailable, let build = result.latestBuild { return build.version }
        if let installed = configuration.installedBuildLabel, result.state == .current || result.state == .installedAhead {
            return installed
        }
        return result.state.title
    }

    private func check(for configuration: GitHubUpdateConfiguration) -> GitHubCheckResult? {
        environment.githubChecks.first {
            $0.targetID == configuration.id && ($0.checkedConfiguration == configuration
                || ($0.state == .failed && $0.checkedConfiguration == nil))
        }
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
    @State private var reviewCandidateID: String?

    private var currentConfiguration: GitHubUpdateConfiguration? {
        environment.githubConfigurations.first { $0.id == configuration.id }
    }
    private var target: GitHubUpdateTarget? {
        environment.installedApps.first { $0.id == configuration.id }?.updateTarget
            ?? environment.liveContainerState.apps.first { $0.id == configuration.id }?.updateTarget
    }
    private var targetIconData: Data? {
        environment.installedApps.first { $0.id == configuration.id }?.iconData
            ?? environment.liveContainerState.apps.first { $0.id == configuration.id }?.iconData
    }
    private var check: GitHubCheckResult? {
        environment.githubChecks.first {
            $0.targetID == configuration.id && ($0.checkedConfiguration == currentConfiguration
                || ($0.state == .failed && $0.checkedConfiguration == nil))
        }
    }
    var body: some View {
        List {
            if let target, let source = currentConfiguration {
                Section {
                    DetailHeader(iconData: targetIconData, title: target.name, subtitle: target.version) {
                        statusBadge
                    }
                    if let check {
                        Text(check.state.message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                    if let candidate = check?.candidate {
                        installLink(candidate)
                            .padding(.top, Spacing.xs)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                Section {
                    LabeledContent("Installed", value: target.version)
                    if let build = check?.latestBuild {
                        LabeledContent("Latest", value: build.version)
                    }
                    if check?.state == .failed, let detail = check?.detail {
                        Text(detail).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    SwiftUI.Button {
                        Task { await environment.gitHubSettingsChanged(); await environment.awaitPendingGitHubChecks() }
                    } label: {
                        HStack {
                            Text("Check Again")
                            if environment.isCheckingGitHubUpdates { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(environment.isCheckingGitHubUpdates)
                } footer: {
                    if check?.state == .unknownInstalledBuild {
                        Text("Version names alone don’t identify a GitHub build. Confirm the build you installed in Update Source.")
                    }
                }
                Section {
                    DisclosureGroup("Build Details") {
                        LabeledContent("GitHub build", value: source.installedBuildLabel
                            ?? (source.installedBuild == nil ? "Unconfirmed" : "Confirmed release"))
                        if let build = check?.latestBuild {
                            Text(build.title)
                            LabeledContent("File", value: build.assetName)
                            if let date = build.date {
                                LabeledContent("Published", value: date.formatted(date: .abbreviated, time: .shortened))
                            }
                        }
                        if check?.state != .failed, let detail = check?.detail {
                            Text(detail).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if let date = check?.checkedAt {
                            LabeledContent("Checked", value: date.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                    NavigationLink("Update Source") { GitHubUpdateSettingsView(target: target) }
                }
            } else {
                ContentUnavailableView("App Unavailable", systemImage: "app.dashed",
                    description: Text("Refresh My Apps or reconnect its LiveContainer folder to check this source."))
            }
        }
        .listStyle(.insetGrouped)
        .navigationDestination(item: $reviewCandidateID) { _ in
            if let candidate = check?.candidate { reviewDestination(candidate) }
        }
        .navigationTitle(target?.name ?? "App Update")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private var statusBadge: some View {
        switch check?.state {
        case .updateAvailable?: StatusBadge(title: "Update available", systemImage: "arrow.down.circle.fill", tone: .accent)
        case .current?, .installedAhead?: StatusBadge(title: "Up to date", systemImage: "checkmark.circle.fill", tone: .success)
        case .failed?, .noMatchingDownload?: StatusBadge(title: check?.state.title ?? "Needs attention", systemImage: "exclamationmark.triangle.fill", tone: .warning)
        case .some(let state): StatusBadge(title: state.title, systemImage: "questionmark.circle", tone: .neutral)
        case nil: StatusBadge(title: "Not checked yet", systemImage: "clock", tone: .neutral)
        }
    }

    /// A Button, not a NavigationLink: links inside a List render as dim rows with a chevron.
    @ViewBuilder private func installLink(_ candidate: GitHubUpdateCandidate) -> some View {
        if candidate.targetKind == .liveContainer || environment.installedApps.contains(where: { $0.id == candidate.bundleIdentifier }) {
            SwiftUI.Button { reviewCandidateID = candidate.id } label: {
                ActionLabel(candidate.isKnownNewer ? "Review Update" : "Review Build")
            }
            .primaryActionStyle()
        }
    }

    @ViewBuilder private func reviewDestination(_ candidate: GitHubUpdateCandidate) -> some View {
        if candidate.targetKind == .liveContainer {
            LiveContainerGuestDetailView(guestID: candidate.bundleIdentifier)
        } else if let app = environment.installedApps.first(where: { $0.id == candidate.bundleIdentifier }) {
            GitHubUpdateDetailView(candidate: candidate, app: app)
        }
    }
}
