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
        let defaultSelfUpdateAsset = "SideKick-unsigned-ipa"
        _repositoryURL = State(initialValue: isSideKick ? "https://github.com/huzaifah1530-bot/SideKick" : "")
        _source = State(initialValue: isSideKick ? .actionsArtifact : .latestRelease)
        _workflowFile = State(initialValue: isSideKick ? "ios-build.yml" : "build.yml")
        _assetName = State(initialValue: isSideKick ? defaultSelfUpdateAsset : "")
    }

    @State private var isConfirmingRemoval = false
    @State private var hasSavedConfiguration = false
    @State private var workflowName = ""
    @State private var artifactSuggestions: [String] = []
    @State private var isDetectingSource = false
    @State private var detectionMessage: String?
    @State private var detectedRepository = ""
    /// What's on disk (or the initial defaults for a new source). Leaving with a different draft
    /// asks to save, like the other settings pages with a Save button.
    @State private var savedDraft: Draft?

    private struct Draft: Equatable {
        let repositoryURL: String
        let source: GitHubUpdateSource
        let workflowFile: String
        let branch: String
        let assetName: String
        let tokenID: String?
        let baselineKey: String?
    }

    private var draft: Draft {
        Draft(repositoryURL: repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines), source: source,
              workflowFile: source == .actionsArtifact ? workflowFile : "", branch: source == .actionsArtifact ? branch : "",
              assetName: assetName, tokenID: tokenID, baselineKey: selectedBaselineKey)
    }

    private var isDirty: Bool {
        guard let savedDraft else { return false }
        return draft != savedDraft
    }

    var body: some View {
        Form {
            Section {
                TextField("github.com/owner/repository", text: $repositoryURL)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                GitHubTokenSelectionLink(selection: $tokenID)
            } header: {
                Text("Repository")
            } footer: {
                Text("SideKick checks for new builds and asks before downloading anything.")
            }

            Section {
                Picker("Builds from", selection: $source) {
                    Text("Releases").tag(GitHubUpdateSource.latestRelease)
                    Text("Actions").tag(GitHubUpdateSource.actionsArtifact)
                }
                .pickerStyle(.segmented)
                .disabled(isDetectingSource)
                if isDetectingSource {
                    HStack(spacing: Spacing.xs) { ProgressView(); Text("Checking where this repository publishes IPAs…").foregroundStyle(.secondary) }
                }
                if source == .actionsArtifact {
                    NavigationLink {
                        GitHubWorkflowPickerView(
                            repositoryURL: repositoryURL,
                            tokenID: tokenID,
                            selection: $workflowFile,
                            selectedName: $workflowName,
                            onArtifactNames: { names in
                                artifactSuggestions = names
                                if names.count == 1 { assetName = names[0] }
                                else if !names.contains(where: { $0.caseInsensitiveCompare(assetName) == .orderedSame }) { assetName = "" }
                            }
                        )
                    } label: {
                        LabeledContent("Workflow", value: workflowName.isEmpty ? (workflowFile.isEmpty ? "Choose" : workflowFile) : workflowName)
                    }
                    .disabled(!isValidRepository)
                    LabeledContent("Branch") {
                        TextField("All branches", text: $branch)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                if source == .actionsArtifact && artifactSuggestions.count > 1 {
                    Picker("Artifact", selection: $assetName) {
                        Text("Any IPA").tag("")
                        ForEach(artifactSuggestions, id: \.self) { Text($0).tag($0) }
                    }
                } else {
                    LabeledContent(source == .latestRelease ? "IPA name" : "Artifact") {
                        TextField("Any", text: $assetName)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
            } header: {
                Text("Builds")
            } footer: {
                if let detectionMessage {
                    Text(detectionMessage)
                } else if source == .actionsArtifact {
                    Text("Choose a workflow that builds IPAs. Only runs with an IPA artifact count as updates.")
                } else {
                    Text("Use * in the name to match changing version numbers.")
                }
            }

            if !repositoryURL.isEmpty {
                Section {
                    if history.isEmpty && isLoadingHistory {
                        // The list behind this row is empty until GitHub answers; opening it now
                        // would show a blank page that never fills in.
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Installed Build")
                                Text("Loading builds…").font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            ProgressView()
                        }
                        .accessibilityElement(children: .combine)
                    } else if history.isEmpty {
                        SwiftUI.Button {
                            Task { await loadHistory() }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(selectedBaselineKey == nil ? "Find Installed Build" : "Load Builds")
                                if selectedBaselineKey != nil {
                                    Text("Saved build · load builds to change it")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
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
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Installed Build")
                                Text(selectedBaselineKey.flatMap { selectedKey in
                                    history.first(where: { $0.key == selectedKey }).map(historyLabel)
                                } ?? (selectedBaselineKey == nil ? "Not confirmed" : "Saved build"))
                                    .font(.subheadline)
                                    .foregroundStyle(selectedBaselineKey == nil ? Color.orange : Color.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    if isLoadingHistory && !history.isEmpty {
                        HStack(spacing: Spacing.xs) {
                            ProgressView()
                            Text("Loading more builds…").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    HStack {
                        Text("Installed Build")
                        Spacer()
                        Menu {
                            SwiftUI.Button { Task { await loadHistory(forceRefresh: true) } } label: {
                                Label("Reload Builds", systemImage: "arrow.clockwise")
                            }
                            SwiftUI.Button { Task { await loadHistory(append: true) } } label: {
                                Label("Load Older Builds", systemImage: "clock.arrow.circlepath")
                            }
                            .disabled(isLoadingHistory || history.isEmpty)
                            SwiftUI.Button { selectedBaselineKey = nil; baselineWasEdited = true } label: {
                                Label("I Don’t Know", systemImage: "questionmark.circle")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.body)
                        }
                        .accessibilityLabel("Installed Build Options")
                        .textCase(nil)
                    }
                } footer: {
                    Text(installedNeedsConfirmation
                         ? "Confirm the build you actually installed, or leave it unknown."
                         : "Only choose a build you installed. Downloading doesn’t mark it installed.")
                }
            }

            if hasSavedConfiguration {
                Section {
                    SwiftUI.Button("Stop Tracking Updates", role: .destructive) { isConfirmingRemoval = true }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                SwiftUI.Button("Save") { Task { if await save() { dismiss() } } }
                    .fontWeight(.semibold)
                    .disabled(repositoryURL.isEmpty || (hasSavedConfiguration && !isDirty))
            }
        }
        .confirmationDialog("Stop tracking updates?", isPresented: $isConfirmingRemoval, titleVisibility: .visible) {
            SwiftUI.Button("Stop Tracking", role: .destructive) {
                Task {
                    do { try await store.remove(bundleIdentifier: target.id); dismiss() }
                    catch { message = error.localizedDescription; showingMessage = true }
                }
            }
        } message: {
            Text("SideKick will stop checking GitHub for \(target.name). The installed app isn’t changed.")
        }
        .guardUnsavedSettings(isDirty: isDirty, save: {
            // The guard navigates away itself after a successful save.
            await save()
        }, discard: {
            guard let savedDraft else { return }
            repositoryURL = savedDraft.repositoryURL
            source = savedDraft.source
            workflowFile = savedDraft.workflowFile.isEmpty ? workflowFile : savedDraft.workflowFile
            branch = savedDraft.branch
            assetName = savedDraft.assetName
            tokenID = savedDraft.tokenID
            selectedBaselineKey = savedDraft.baselineKey
            baselineWasEdited = false
        })
        .navigationTitle("Update Source")
        .task(id: repositoryURL) {
            // Wait for typing to settle, then pick the source that actually publishes IPAs.
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await detectSource()
        }
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
            // The discarded request was the only one in flight; start again with the new token
            // so the list doesn't stay empty.
            if isValidRepository { Task { await loadHistory() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sideKickGitHubSettingsDidChange)) { _ in
            Task {
                guard !baselineWasEdited,
                      let saved = try? await store.configuration(for: target.id),
                      saved.hasSameSource(as: draftConfiguration) else { return }
                selectedBaselineKey = saved.effectiveBaselineKey
                // Another screen saved a new installed build; that isn't an unsaved edit here.
                if let current = savedDraft {
                    savedDraft = Draft(repositoryURL: current.repositoryURL, source: current.source,
                        workflowFile: current.workflowFile, branch: current.branch, assetName: current.assetName,
                        tokenID: current.tokenID, baselineKey: saved.effectiveBaselineKey)
                }
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
                savedDraft = draft
                didFinishInitialLoad = true
                historyTokenID = tokenID
                hasHistoryTokenIdentity = true
                return
            }
            hasSavedConfiguration = true
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
            savedDraft = draft
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

    /// Returns true when saved. Callers decide whether to leave the page.
    @MainActor
    @discardableResult
    private func save() async -> Bool {
        guard let url = URL(string: repositoryURL), url.host?.lowercased() == "github.com",
              url.path.split(separator: "/").count >= 2 else {
            message = "Enter a valid GitHub repository URL."
            showingMessage = true
            return false
        }
        do {
            let configuration = GitHubUpdateConfiguration(bundleIdentifier: target.id, repositoryURL: repositoryURL,
                source: source, workflowFile: workflowFile, branch: branch, assetName: assetName,
                lastInstalledUpdateKey: nil, tokenID: tokenID)
            try await store.saveSettings(configuration, baselineKey: selectedBaselineKey,
                baselineWasEdited: baselineWasEdited, observation: target.observation)
            savedDraft = draft
            hasSavedConfiguration = true
            return true
        } catch {
            message = error.localizedDescription
            showingMessage = true
            return false
        }
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
            if let saved = try? await store.configuration(for: target.id),
               saved.hasSameSource(as: configuration), saved.tokenID == credentialID,
               queryGeneration == generation, sourceIdentity == identity, tokenID == credentialID {
                let check = GitHubCheckResult(targetID: target.id, state: .failed,
                    detail: error.localizedDescription, checkedConfiguration: saved, checkedAt: .now)
                _ = await environment.publishDetailGitHubCheck(check, target: target)
            }
        }
    }

    private var isValidRepository: Bool {
        guard let url = URL(string: repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["github.com", "www.github.com"].contains(url.host?.lowercased() ?? "") else { return false }
        return url.path.split(separator: "/").count >= 2
    }

    /// For a new source, choose Releases when they contain IPAs and Actions otherwise.
    /// Saved sources keep their configuration; this only fills in what's still unset.
    @MainActor private func detectSource() async {
        // SideKick's own source is preconfigured; never second-guess it.
        guard didFinishInitialLoad, isValidRepository, !hasSavedConfiguration,
              target.id != Bundle.main.bundleIdentifier,
              detectedRepository != repositoryURL else { return }
        detectedRepository = repositoryURL
        isDetectingSource = true
        defer { isDetectingSource = false }
        let token = try? GitHubCredentialStore().load(id: tokenID)
        let service = GitHubUpdateService()
        guard let releasesHaveIPA = try? await service.releasesContainIPA(repositoryURL, token: token) else {
            detectionMessage = nil
            return
        }
        if releasesHaveIPA {
            source = .latestRelease
            detectionMessage = "This repository’s releases include IPAs."
            return
        }
        source = .actionsArtifact
        detectionMessage = "Releases here don’t include IPAs, so SideKick switched to Actions."
        guard let summaries = try? await service.workflowSummaries(repositoryURL, token: token) else { return }
        let ipaWorkflows = summaries.filter(\.buildsIPA)
        if ipaWorkflows.count == 1, let only = ipaWorkflows.first {
            workflowFile = String(only.workflow.id)
            workflowName = only.workflow.name
            artifactSuggestions = only.ipaArtifactNames
            if only.ipaArtifactNames.count == 1 { assetName = only.ipaArtifactNames[0] }
            branch = ""
            detectionMessage = "Releases here don’t include IPAs. “\(only.workflow.name)” is the only workflow that builds one, so it’s selected."
        } else if ipaWorkflows.isEmpty {
            detectionMessage = "Neither releases nor recent Actions runs include an IPA. Check the repository or add a token."
        } else {
            workflowFile = ""
            workflowName = ""
            detectionMessage = "Releases here don’t include IPAs. Choose one of the \(ipaWorkflows.count) workflows that build them."
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

    @State private var isShowingInstall = false

    private var installedApp: InstalledAppSummary? { environment.installedApps.first { $0.id == target.id } }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(item.title).font(.headline).lineLimit(4)
                    if let date = item.date {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, Spacing.xxs)
                if let build {
                    LabeledContent("Version", value: build.version)
                    LabeledContent("File", value: build.assetName).lineLimit(1)
                }
            } footer: {
                Text("Installing an older build replaces the app’s version. Older versions may not open data from newer ones.")
            }
            InlineActionsSection { versionActions }
            if let message {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationDestination(isPresented: $isShowingInstall) {
            if let candidate = preparedCandidate, let installedApp {
                GitHubUpdateDetailView(candidate: candidate, app: installedApp, isVersionSelection: true)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    SwiftUI.Button { confirmingBaseline = true } label: {
                        Label("I’ve Installed This Version", systemImage: "checkmark.circle")
                    }
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("More")
            }
        }
        .navigationTitle("Version")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Installed this exact build?", isPresented: $confirmingBaseline) {
            SwiftUI.Button("Select as Installed") { selectedKey = item.key; dismiss() }
            SwiftUI.Button("Cancel", role: .cancel) { }
        } message: { Text("This only marks the build in Update Source; it doesn’t install anything. Save to apply.") }
        .sheet(isPresented: $showingShare, onDismiss: {
            if let shareURL { try? FileManager.default.removeItem(at: shareURL) }
            shareURL = nil
        }) {
            if let shareURL { LiveContainerIPAActivity(url: shareURL) }
        }
    }

    @ViewBuilder
    private var versionActions: some View {
        if let candidate = preparedCandidate {
            if target.kind == .installed {
                SwiftUI.Button { isShowingInstall = true } label: { ActionLabel("Install This Version") }
                    .primaryActionStyle()
                    .disabled(installedApp == nil)
            } else if let job = downloadJob, job.isDownloading {
                ProgressView(value: job.progress ?? 0).tint(.sideKickAccent)
                SwiftUI.Button { environment.githubUpdateDownloads.cancelDownload(for: candidate) } label: {
                    ActionLabel("Cancel Download")
                }
                .secondaryActionStyle()
                .tint(.red)
            } else if downloadJob?.queuedIPA != nil {
                HStack(spacing: Spacing.s) {
                    SwiftUI.Button { Task { await shareGuest(candidate) } } label: {
                        ActionLabel("Send to LC", systemImage: "square.and.arrow.up", isWorking: working)
                    }
                    .primaryActionStyle()
                    .disabled(working)
                    SwiftUI.Button { Task { await downloadGuest(candidate) } } label: {
                        ActionLabel("Re-download", systemImage: "arrow.clockwise")
                    }
                    .secondaryActionStyle()
                    .tint(.sideKickAccent)
                    .disabled(working)
                }
                SwiftUI.Button("Delete IPA", role: .destructive) {
                    Task { try? await environment.githubUpdateDownloads.discardDownload(for: candidate, ipaImportStore: environment.ipaImportStore) }
                }
                .font(.body.weight(.semibold))
                .frame(minHeight: 44)
            } else {
                SwiftUI.Button { Task { await downloadGuest(candidate) } } label: {
                    ActionLabel("Download IPA", systemImage: "arrow.down.circle", isWorking: working)
                }
                .primaryActionStyle()
                .disabled(working)
            }
        } else {
            SwiftUI.Button { Task { await prepare() } } label: {
                ActionLabel("Use This Version", isWorking: working)
            }
            .primaryActionStyle()
            .disabled(build == nil || working)
            Text("Saves this source. Nothing installs until you choose to.")
                .font(.footnote).foregroundStyle(.secondary)
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
            if let source = candidate.sourceIdentity {
                LiveContainerHandoffRecord(guest: guest, candidate: candidate, source: source).save()
            }
            message = nil
        } catch { message = error.localizedDescription }
    }
}
