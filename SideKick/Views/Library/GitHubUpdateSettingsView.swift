import SwiftUI
import UIKit

struct GitHubUpdateSettingsView: View {
    let target: GitHubUpdateTarget

    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var environment
    @State private var tokenID: String?
    @State private var repositoryURL = ""
    @State private var source: GitHubUpdateSource = .latestRelease
    @State private var workflowFile = "build.yml"
    @State private var branch = "main"
    @State private var assetName = ""
    @State private var message: String?
    @State private var showingMessage = false
    @State private var history: [GitHubUpdateHistoryEntry] = []
    @State private var builds: [GitHubTrackedBuild] = []
    @State private var selectedBaselineKey: String?
    @State private var baselineWasEdited = false
    @State private var installedNeedsConfirmation = false
    @State private var isLoadingHistory = false
    @State private var didLoad = false
    @State private var didFinishInitialLoad = false
    @State private var tokenChangedDuringInitialLoad = false
    @State private var historyTokenID: String?
    @State private var hasHistoryTokenIdentity = false
    @State private var loadedSource = ""
    @State private var queryGeneration = UUID()
    @State private var historyPage = 1

    private let store = GitHubUpdateConfigurationStore.shared

    init(app: InstalledAppSummary) {
        self.init(target: app.updateTarget)
    }

    init(target: GitHubUpdateTarget) {
        self.target = target
        let isSideKick = target.kind == .installed && target.id == Bundle.main.bundleIdentifier
        let vpnExtension = Bundle.main.bundleURL.appendingPathComponent("PlugIns/SideKickVPN.appex", isDirectory: true)
        let defaultSelfUpdateAsset = FileManager.default.fileExists(atPath: vpnExtension.path)
            ? "SideKick-vpn-unsigned-ipa"
            : "SideKick-unsigned-ipa"
        _repositoryURL = State(initialValue: isSideKick ? "https://github.com/huzaifah1530-bot/SideKick" : "")
        _source = State(initialValue: isSideKick ? .actionsArtifact : .latestRelease)
        _workflowFile = State(initialValue: isSideKick ? "ios-build.yml" : "build.yml")
        _assetName = State(initialValue: isSideKick ? defaultSelfUpdateAsset : "")
    }

    var body: some View {
        Form {
            Section {
                TextField("https://github.com/owner/repository", text: $repositoryURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                GitHubTokenSelectionLink(selection: $tokenID)
                Picker("Update source", selection: $source) {
                    ForEach(GitHubUpdateSource.allCases) { option in Text(option.title).tag(option) }
                }
                if source == .actionsArtifact {
                    TextField("Workflow file or ID", text: $workflowFile)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Branch (blank for all)", text: $branch)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                TextField(source == .latestRelease ? "IPA asset name (optional)" : "Artifact name (optional)", text: $assetName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Update source")
            } footer: {
                Text("SideKick checks this GitHub repository for a newer IPA. A matching update is shown for your approval; it is never downloaded in the background. For Actions, the selected workflow must publish the IPA as a downloadable artifact. Use * in the asset name for changing version numbers.")
            }

            if !repositoryURL.isEmpty {
                Section {
                    if history.isEmpty && selectedBaselineKey == nil {
                        SwiftUI.Button {
                            Task { await loadHistory() }
                        } label: {
                            HStack {
                                Text("Load Build History")
                                Spacer()
                                if isLoadingHistory { ProgressView() }
                            }
                        }
                        .disabled(isLoadingHistory)
                    } else {
                        NavigationLink {
                            GitHubBaselineSelectionView(
                                history: history,
                                builds: builds,
                                target: target,
                                configuration: draftConfiguration,
                                onSourceSaved: { baselineWasEdited = false },
                                selectedKey: Binding(get: { selectedBaselineKey }, set: { selectedBaselineKey = $0; baselineWasEdited = true })
                            )
                        } label: {
                            LabeledContent(
                                "Versions & Installed Build",
                                value: selectedBaselineKey.flatMap { selectedKey in
                                    history.first(where: { $0.key == selectedKey }).map(historyLabel)
                                } ?? selectedBaselineKey.map { "Saved build: \($0)" } ?? "Choose a version"
                            )
                        }
                        .fullWidthListSeparators()
                        Text(installedNeedsConfirmation ? "Previous tracking or changed app files need confirmation. Choose the build you actually installed, or leave it unknown." : "Only choose a build you actually installed. Checking or downloading a build does not mark it installed.")
                            .font(.footnote).foregroundStyle(.secondary)
                        SwiftUI.Button("Reload versions") { Task { await loadHistory(forceRefresh: true) } }
                    }
                    SwiftUI.Button("I Don’t Know the Installed Build") { selectedBaselineKey = nil; baselineWasEdited = true }
                    SwiftUI.Button("Load older versions") { Task { await loadHistory(append: true) } }
                        .disabled(isLoadingHistory || history.isEmpty)
                } header: {
                    Text("Installed Version")
                } footer: {
                    Text("SideKick compares release or build history from this source. The version label in the IPA doesn’t need to match GitHub’s tag or build number.")
                }
            }

            if !repositoryURL.isEmpty {
                Section {
                    SwiftUI.Button("Save GitHub Update Settings") { Task { await save() } }
                    SwiftUI.Button("Remove GitHub Update Settings", role: .destructive) {
                        Task {
                            do { try await store.remove(bundleIdentifier: target.id); dismiss() }
                            catch { message = error.localizedDescription; showingMessage = true }
                        }
                    }
                }
            }
        }
        .navigationTitle("GitHub Updates")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of: sourceIdentity) { _, value in
            guard didLoad, value != loadedSource else { return }
            loadedSource = value
            queryGeneration = UUID()
            history = []
            builds = []
            historyPage = 1
            baselineWasEdited = false
            selectedBaselineKey = nil
            isLoadingHistory = false
        }
        .onChange(of: tokenID) { _, value in
            guard didLoad else { return }
            guard didFinishInitialLoad else {
                tokenChangedDuringInitialLoad = true
                return
            }
            guard !hasHistoryTokenIdentity || value != historyTokenID else { return }
            historyTokenID = value
            queryGeneration = UUID()
            history = []
            builds = []
            historyPage = 1
            isLoadingHistory = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .sideKickGitHubSettingsDidChange)) { _ in
            Task {
                guard !baselineWasEdited,
                      let saved = try? await store.configuration(for: target.id),
                      saved.hasSameSource(as: draftConfiguration) else { return }
                selectedBaselineKey = saved.effectiveBaselineKey
            }
        }
        .alert("GitHub Updates", isPresented: $showingMessage) {
            SwiftUI.Button("OK", role: .cancel) { }
        } message: { Text(message ?? "") }
    }

    @MainActor
    private func load() async {
        guard !didLoad else { return }
        didLoad = true
        do {
            guard let config = try await store.configuration(for: target.id) else {
                loadedSource = sourceIdentity
                didFinishInitialLoad = true
                historyTokenID = tokenID
                hasHistoryTokenIdentity = true
                return
            }
            if !tokenChangedDuringInitialLoad { tokenID = config.tokenID }
            repositoryURL = config.repositoryURL
            source = config.source
            workflowFile = config.workflowFile
            branch = config.branch
            assetName = config.assetName
            selectedBaselineKey = config.effectiveBaselineKey
            installedNeedsConfirmation = config.installedBuild == nil || config.installedBuild?.observation != target.observation
            baselineWasEdited = false
            loadedSource = sourceIdentity
            didFinishInitialLoad = true
            historyTokenID = tokenID
            hasHistoryTokenIdentity = true
            await loadHistory(configuration: config)
        } catch {
            didFinishInitialLoad = true
            historyTokenID = tokenID
            hasHistoryTokenIdentity = true
            message = error.localizedDescription
            showingMessage = true
        }

    }

    @MainActor
    private func save() async {
        guard let url = URL(string: repositoryURL), url.host?.lowercased() == "github.com",
              url.path.split(separator: "/").count >= 2 else {
            message = "Enter a valid GitHub repository URL."
            showingMessage = true
            return
        }
        do {
            let configuration = GitHubUpdateConfiguration(bundleIdentifier: target.id, repositoryURL: repositoryURL,
                source: source, workflowFile: workflowFile, branch: branch, assetName: assetName,
                lastInstalledUpdateKey: nil, tokenID: tokenID)
            try await store.saveSettings(configuration, baselineKey: selectedBaselineKey,
                baselineWasEdited: baselineWasEdited, observation: target.observation)
            dismiss()
        } catch { message = error.localizedDescription; showingMessage = true }
    }

    @MainActor
    private func loadHistory(configuration existing: GitHubUpdateConfiguration? = nil, append: Bool = false, forceRefresh: Bool = false) async {
        guard !isLoadingHistory else { return }
        isLoadingHistory = true
        let generation = queryGeneration
        let identity = sourceIdentity
        let credentialID = tokenID
        let page = append ? historyPage + 1 : 1
        defer { if queryGeneration == generation { isLoadingHistory = false } }
        let configuration = existing ?? GitHubUpdateConfiguration(
            bundleIdentifier: target.id,
            repositoryURL: repositoryURL,
            source: source,
            workflowFile: workflowFile,
            branch: branch,
            assetName: assetName,
            baselineUpdateKey: nil,
            lastInstalledUpdateKey: nil
        )
        do {
            let token = try GitHubCredentialStore().load(id: credentialID)
            let service = GitHubUpdateService()
            let downloadedBuilds = try await service.downloadableHistory(for: configuration, token: token, page: page, forceRefresh: forceRefresh)
            let entries = downloadedBuilds.map(\.historyEntry)
            guard queryGeneration == generation, sourceIdentity == identity,
                  tokenID == credentialID, !Task.isCancelled else { return }
            historyPage = page
            if append {
                let known = Set(history.map(\.key))
                history += entries.filter { !known.contains($0.key) }
                builds += downloadedBuilds.filter { !known.contains($0.key) }
            } else { history = entries; builds = downloadedBuilds }
            // The saved source and target must still match. Draft settings can
            // populate a list, but cannot replace an app-owned update result.
            if page == 1, let saved = try await store.configuration(for: target.id),
               saved.hasSameSource(as: configuration), saved.tokenID == credentialID {
                var check = try await service.check(for: target, configuration: saved, token: token, forceRefresh: false)
                guard queryGeneration == generation, sourceIdentity == identity, tokenID == credentialID else { return }
                check.checkedConfiguration = saved
                _ = await environment.publishDetailGitHubCheck(check, target: target)
            }
            if history.isEmpty { message = "No matching releases or downloadable build artifacts were found. Check the source settings and asset name."; showingMessage = true }
        } catch {
            guard queryGeneration == generation, sourceIdentity == identity,
                  tokenID == credentialID else { return }
            let urlCancellation = (error as? URLError)?.code == .cancelled
            if Task.isCancelled || error is CancellationError || urlCancellation {
                message = "The history request was cancelled. Reload versions to try again."
                showingMessage = true
                return
            }
            message = error.localizedDescription
            showingMessage = true
        }
    }

    private var sourceIdentity: String {
        [repositoryURL, source.rawValue, workflowFile, branch, assetName].joined(separator: "\n")
    }

    private var draftConfiguration: GitHubUpdateConfiguration {
        GitHubUpdateConfiguration(bundleIdentifier: target.id, repositoryURL: repositoryURL,
            source: source, workflowFile: workflowFile, branch: branch, assetName: assetName,
            lastInstalledUpdateKey: nil, tokenID: tokenID)
    }

    @MainActor
    private func loadHistory() async {
        await loadHistory(configuration: nil)
    }

    private func historyLabel(_ item: GitHubUpdateHistoryEntry) -> String {
        guard let date = item.date else { return item.title }
        return "\(item.title) · \(date.formatted(date: .abbreviated, time: .omitted))"
    }
}

private struct GitHubBaselineSelectionView: View {
    let history: [GitHubUpdateHistoryEntry]
    let builds: [GitHubTrackedBuild]
    let target: GitHubUpdateTarget
    let configuration: GitHubUpdateConfiguration
    let onSourceSaved: () -> Void
    @Binding var selectedKey: String?

    var body: some View {
        List {
            Section {
                ForEach(history) { item in
                    NavigationLink {
                        GitHubHistoricalVersionView(item: item,
                            build: builds.first(where: { $0.key == item.key }), target: target,
                            configuration: configuration, onSourceSaved: onSourceSaved, selectedKey: $selectedKey)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title)
                                    .font(.body.weight(.medium))
                                if let date = item.date {
                                    Text(date.formatted(date: .abbreviated, time: .omitted))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if selectedKey == item.key {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .fullWidthListSeparators()
                }
            } header: {
                Text("Available versions")
            } footer: {
                Text("Open a version to download and install it, or identify the build you already installed.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Versions")
        .navigationBarTitleDisplayMode(.inline)
    }

}

private struct GitHubHistoricalVersionView: View {
    let item: GitHubUpdateHistoryEntry
    let build: GitHubTrackedBuild?
    let target: GitHubUpdateTarget
    let configuration: GitHubUpdateConfiguration
    let onSourceSaved: () -> Void
    @Binding var selectedKey: String?
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var preparedCandidate: GitHubUpdateCandidate?
    @State private var working = false
    @State private var message: String?
    @State private var confirmingBaseline = false
    @State private var shareURL: URL?
    @State private var showingShare = false

    private var downloadJob: GitHubUpdateDownloadJob? {
        preparedCandidate.flatMap { environment.githubUpdateDownloads.jobs[$0.id] }
    }

    var body: some View {
        List {
            Section("Version") {
                Text(item.title).font(.headline)
                if let date = item.date { LabeledContent("Published", value: date.formatted()) }
                if let build {
                    LabeledContent("Version", value: build.version)
                    LabeledContent("File", value: build.assetName)
                }
                Text("Installing an older build replaces the app’s version. Older versions may not support data created by newer versions.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                if let candidate = preparedCandidate {
                    if target.kind == .installed {
                        if let app = environment.installedApps.first(where: { $0.id == target.id }) {
                            NavigationLink("Download & Install This Version") {
                                GitHubUpdateDetailView(candidate: candidate, app: app, isVersionSelection: true)
                            }
                        } else {
                            Text("The installed app is unavailable. Refresh My Apps and reopen this version.")
                        }
                    } else {
                        GitHubUpdateDownloadControls(job: downloadJob,
                            onDownload: { Task { await downloadGuest(candidate) } },
                            onCancel: { environment.githubUpdateDownloads.cancelDownload(for: candidate) },
                            onSkip: {}, allowsSkip: false, isDisabled: working) {
                            SwiftUI.Button("Install in LiveContainer") { Task { await shareGuest(candidate) } }
                        }
                        Text("Choose LiveContainer in the share sheet and replace the existing guest. Verify the installation before marking this build installed.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    SwiftUI.Button("Use This Source & Review Installation") { Task { await prepare() } }
                        .disabled(build == nil || working)
                    Text("This saves the GitHub source shown in setup. Your installed build remains unchanged until installation succeeds or you confirm it manually.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if working { ProgressView() }
                if let message { Text(message).foregroundStyle(.red).textSelection(.enabled) }
            }
            Section {
                SwiftUI.Button("This Version Is Already Installed") { confirmingBaseline = true }
            }
        }
        .navigationTitle("Version Details")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Already installed this exact build?", isPresented: $confirmingBaseline) {
            SwiftUI.Button("Select Installed Build") { selectedKey = item.key; dismiss() }
            SwiftUI.Button("Cancel", role: .cancel) { }
        } message: { Text("This selects the installed build for setup; it does not install anything. Save GitHub settings to apply it.") }
        .sheet(isPresented: $showingShare, onDismiss: {
            if let shareURL { try? FileManager.default.removeItem(at: shareURL) }
            shareURL = nil
        }) {
            if let shareURL { LiveContainerIPAActivity(url: shareURL) }
        }
    }

    @MainActor private func prepare() async {
        guard let build, !working else { return }
        working = true
        defer { working = false }
        do {
            try await GitHubUpdateConfigurationStore.shared.saveSettings(configuration,
                baselineKey: nil, baselineWasEdited: false, observation: target.observation)
            let saved = try await GitHubUpdateConfigurationStore.shared.configuration(for: target.id)
            selectedKey = saved?.effectiveBaselineKey
            onSourceSaved()
            preparedCandidate = build.candidate(for: target, configuration: saved ?? configuration)
            if let preparedCandidate {
                await environment.githubUpdateDownloads.restoreQueuedFiles(for: [preparedCandidate],
                    ipaImportStore: environment.ipaImportStore)
            }
            message = nil
        } catch { message = error.localizedDescription }
    }

    @MainActor private func verifiedGuest(_ candidate: GitHubUpdateCandidate) async throws -> LiveContainerGuest {
        guard let guest = environment.liveContainerState.apps.first(where: { $0.id == target.id }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try await environment.liveContainerStore.rescan(guest.connectionID)
        let snapshot = try await environment.liveContainerStore.snapshot()
        guard let fresh = snapshot.apps.first(where: { $0.id == target.id }), fresh.isAvailable,
              let connection = snapshot.connections.first(where: { $0.id == fresh.connectionID }),
              connection.isConnected, connection.storageKind != .snapshot,
              let current = try await GitHubUpdateConfigurationStore.shared.configuration(for: target.id),
              current.sourceIdentity == candidate.sourceIdentity else {
            throw NSError(domain: "SideKick", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "The guest or GitHub source is unavailable or changed. Reconnect it and reopen this version."])
        }
        return fresh
    }

    @MainActor private func downloadGuest(_ candidate: GitHubUpdateCandidate) async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            let guest = try await verifiedGuest(candidate)
            let token = try GitHubCredentialStore().load(id: configuration.tokenID)
            environment.githubUpdateDownloads.start(candidate: candidate,
                expectedBundleIdentifiers: [guest.bundleIdentifier.lowercased()],
                ipaImportStore: environment.ipaImportStore, token: token)
            message = nil
        } catch { message = error.localizedDescription }
    }

    @MainActor private func shareGuest(_ candidate: GitHubUpdateCandidate) async {
        guard !working, let ipa = downloadJob?.queuedIPA else { return }
        working = true
        defer { working = false }
        do {
            let guest = try await verifiedGuest(candidate)
            guard ipa.bundleIdentifier.lowercased() == guest.bundleIdentifier.lowercased(),
                  ipa.githubUpdateKey == candidate.updateKey,
                  ipa.githubSourceIdentity == candidate.sourceIdentity else { throw CocoaError(.fileReadCorruptFile) }
            shareURL = try await environment.ipaImportStore.fileURL(for: ipa)
            showingShare = true
            message = nil
        } catch { message = error.localizedDescription }
    }
}
