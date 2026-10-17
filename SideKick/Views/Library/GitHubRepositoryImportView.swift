import SwiftUI

struct GitHubRepositoryImportView: View {
    let repositoryURL: URL
    let onImported: (ImportedIPA) async throws -> Void
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var tokenID: String?
    @State private var source: GitHubUpdateSource = .latestRelease
    @State private var workflowName = ""
    @State private var workflowID = ""
    @State private var branch = ""
    @State private var branchDraft = ""
    @State private var choices: [GitHubImportChoice] = []
    @State private var page = 1
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var reloadID = UUID()

    private var requestKey: String { "\(source.rawValue)|\(tokenID ?? "default")|\(workflowID)|\(branch)|\(reloadID)" }

    @State private var didChooseSource = false
    @State private var isDetectingSource = true
    @State private var releasesHaveIPA: Bool?

    var body: some View {
        List {
            Section {
                Text(repositoryURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                    .font(.headline).textSelection(.enabled)
                GitHubTokenSelectionLink(selection: $tokenID)
                Picker("Source", selection: Binding(get: { source }, set: { source = $0; didChooseSource = true })) {
                    Text("Releases").tag(GitHubUpdateSource.latestRelease)
                    Text("Actions").tag(GitHubUpdateSource.actionsArtifact)
                }
                .pickerStyle(.segmented)
                .disabled(isDetectingSource)
                if source == .actionsArtifact {
                    NavigationLink {
                        GitHubWorkflowPickerView(repositoryURL: repositoryURL.absoluteString, tokenID: tokenID, selection: $workflowID, selectedName: $workflowName)
                    } label: {
                        LabeledContent("Workflow", value: workflowName.isEmpty ? "Choose" : workflowName)
                    }
                    LabeledContent("Branch") {
                        TextField("Default branch", text: $branchDraft)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .submitLabel(.search)
                            .onSubmit { branch = branchDraft.trimmingCharacters(in: .whitespacesAndNewlines); reloadID = UUID() }
                    }
                }
            } header: { Text("Repository") } footer: {
                if isDetectingSource {
                    Text("Checking where this repository publishes IPAs…")
                } else if releasesHaveIPA == false && source == .actionsArtifact {
                    Text("This repository’s releases don’t include IPAs, so SideKick switched to Actions. Downloading Actions builds needs a GitHub token.")
                } else if source == .actionsArtifact {
                    Text("Only builds that produced an IPA artifact are shown. Downloading needs a GitHub token.")
                } else {
                    Text("SideKick tracks the build you install and checks the same source for updates.")
                }
            }
            Section {
                ForEach(choices) { choice in
                    NavigationLink {
                        GitHubRepositoryDownloadView(choice: choice, tokenID: tokenID, onImported: onImported)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(choice.candidate.title).font(.body.weight(.semibold)).lineLimit(2)
                            Text([choice.candidate.assetName, choice.date?.formatted(date: .abbreviated, time: .omitted)].compactMap { $0 }.joined(separator: " · "))
                                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(.vertical, Spacing.xxs)
                    }
                }
                if isLoading || isDetectingSource {
                    HStack(spacing: Spacing.xs) { ProgressView(); Text(isDetectingSource ? "Checking releases…" : "Finding IPA builds…").foregroundStyle(.secondary) }
                } else if source == .actionsArtifact && workflowID.isEmpty {
                    NavigationLink {
                        GitHubWorkflowPickerView(repositoryURL: repositoryURL.absoluteString, tokenID: tokenID, selection: $workflowID, selectedName: $workflowName)
                    } label: {
                        Label("Choose a Workflow", systemImage: "gearshape.2")
                    }
                } else if choices.isEmpty && errorMessage == nil {
                    ContentUnavailableView("No IPA Builds", systemImage: "shippingbox",
                        description: Text(source == .latestRelease
                            ? "No release here includes an IPA. Try Actions."
                            : "No recent successful run of this workflow produced an IPA artifact. Try another workflow or branch."))
                        .listRowBackground(Color.clear)
                }
                if hasMore && !isLoading {
                    SwiftUI.Button("Load More") { Task { await loadMore() } }
                }
            } header: { Text(source == .latestRelease ? "Releases with IPAs" : "Builds with IPAs") }
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    SwiftUI.Button("Try Again") { reloadID = UUID() }
                }
            }
        }
        .navigationTitle("Install from GitHub")
        .navigationBarTitleDisplayMode(.inline)
        .task { await detectSource() }
        .task(id: requestKey) { if !isDetectingSource { await load() } }
        .onChange(of: isDetectingSource) { _, detecting in if !detecting { reloadID = UUID() } }
    }

    /// Picks Releases when they contain IPAs, otherwise Actions, unless the user already chose.
    @MainActor private func detectSource() async {
        defer { isDetectingSource = false }
        guard !didChooseSource else { return }
        let token = try? GitHubCredentialStore().load(id: tokenID)
        let hasIPA = (try? await GitHubUpdateService().releasesContainIPA(repositoryURL.absoluteString, token: token)) ?? true
        releasesHaveIPA = hasIPA
        if !didChooseSource { source = hasIPA ? .latestRelease : .actionsArtifact }
    }

    @MainActor private func load() async {
        let key = requestKey
        choices = []; errorMessage = nil; hasMore = false; page = 1; isLoading = true
        defer { if key == requestKey { isLoading = false } }
        do {
            let token = try GitHubCredentialStore().load(id: tokenID)
            let service = GitHubUpdateService()
            if branch.isEmpty {
                let repository = try await service.repositoryInfo(repositoryURL.absoluteString, token: token)
                try Task.checkCancellation()
                branch = repository.default_branch; branchDraft = branch
                return // The request key restarts loading with the resolved branch.
            }
            if source == .actionsArtifact && workflowID.isEmpty {
                return // Let the user choose the workflow; do not guess which app to install.
            }
            let result = try await service.importChoices(repositoryURL: repositoryURL.absoluteString, source: source, workflow: workflowID, branch: branch, token: token, page: 1)
            try Task.checkCancellation()
            choices = result.choices; hasMore = result.hasMore
        } catch is CancellationError { }
        catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
    }

    @MainActor private func loadMore() async {
        guard !isLoading else { return }
        let key = requestKey
        isLoading = true
        defer { if requestKey == key { isLoading = false } }
        do {
            let token = try GitHubCredentialStore().load(id: tokenID)
            let result = try await GitHubUpdateService().importChoices(repositoryURL: repositoryURL.absoluteString, source: source, workflow: workflowID, branch: branch, token: token, page: page + 1)
            guard key == requestKey else { return }
            let existing = Set(choices.map(\.id))
            choices += result.choices.filter { !existing.contains($0.id) }
            page += 1; hasMore = result.hasMore
        } catch { if key == requestKey { errorMessage = error.localizedDescription } }
    }
}

/// Workflow chooser shared by Install from GitHub and Update Source. Workflows whose recent
/// successful runs produced an IPA artifact are listed first; the rest are tucked away.
struct GitHubWorkflowPickerView: View {
    let repositoryURL: String
    let tokenID: String?
    @Binding var selection: String
    @Binding var selectedName: String
    var onArtifactNames: (([String]) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var summaries: [GitHubUpdateService.WorkflowSummary] = []
    @State private var loading = false
    @State private var loaded = false
    @State private var errorMessage: String?
    @State private var showsOtherWorkflows = false

    private var ipaWorkflows: [GitHubUpdateService.WorkflowSummary] { summaries.filter(\.buildsIPA) }
    private var otherWorkflows: [GitHubUpdateService.WorkflowSummary] { summaries.filter { !$0.buildsIPA } }

    var body: some View {
        List {
            if loading {
                Section {
                    HStack(spacing: Spacing.xs) { ProgressView(); Text("Checking workflows for IPA builds…").foregroundStyle(.secondary) }
                }
            }
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    SwiftUI.Button("Try Again") { Task { await load() } }
                }
            }
            if loaded && !ipaWorkflows.isEmpty {
                Section {
                    ForEach(ipaWorkflows) { row($0) }
                } header: {
                    Text("Builds IPAs")
                } footer: {
                    Text("Recent successful runs of these workflows produced an IPA artifact.")
                }
            } else if loaded && errorMessage == nil {
                ContentUnavailableView("No IPA Workflows", systemImage: "shippingbox",
                    description: Text("No workflow here has a recent successful run with an IPA artifact. Artifacts expire, so older builds may be gone."))
                    .listRowBackground(Color.clear)
            }
            if loaded && !otherWorkflows.isEmpty {
                Section {
                    DisclosureGroup("Other Workflows (\(otherWorkflows.count))", isExpanded: $showsOtherWorkflows) {
                        ForEach(otherWorkflows) { row($0) }
                    }
                } footer: {
                    Text("These haven’t produced an IPA recently. Choose one only if you know it does.")
                }
            }
        }
        .navigationTitle("Workflow")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { if !loaded { await load() } }
    }

    private func row(_ summary: GitHubUpdateService.WorkflowSummary) -> some View {
        SwiftUI.Button {
            selection = String(summary.workflow.id)
            selectedName = summary.workflow.name
            onArtifactNames?(summary.ipaArtifactNames)
            dismiss()
        } label: {
            HStack(spacing: Spacing.s) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.workflow.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                    Text(summary.buildsIPA ? summary.ipaArtifactNames.joined(separator: ", ") : summary.workflow.path)
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if selection == String(summary.workflow.id) || selection == summary.workflow.path
                    || selection == (summary.workflow.path as NSString).lastPathComponent {
                    Image(systemName: "checkmark").foregroundStyle(Color.sideKickAccent).accessibilityLabel("Selected")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @MainActor private func load() async {
        guard !loading else { return }
        loading = true; errorMessage = nil
        defer { loading = false }
        do {
            let token = try GitHubCredentialStore().load(id: tokenID)
            summaries = try await GitHubUpdateService().workflowSummaries(repositoryURL, token: token)
            loaded = true
        } catch is CancellationError { }
        catch { errorMessage = error.localizedDescription; loaded = true }
    }
}

private struct GitHubRepositoryDownloadView: View {
    let choice: GitHubImportChoice
    @State var tokenID: String?
    let onImported: (ImportedIPA) async throws -> Void
    @Environment(AppEnvironment.self) private var environment
    @State private var jobID: UUID?

    var body: some View {
        List {
            Section {
                LabeledContent("Version", value: choice.candidate.newVersion)
                LabeledContent("File", value: choice.candidate.assetName)
                GitHubTokenSelectionLink(selection: $tokenID).disabled(jobID != nil)
            } header: { Text(choice.candidate.title) } footer: {
                Text("After you install it, SideKick checks this same source for updates.")
            }
            Section {
                if let jobID, environment.importDownloads.jobs[jobID] != nil {
                    ImportDownloadPanel(jobID: jobID)
                } else {
                    SwiftUI.Button {
                        jobID = environment.importDownloads.start(.repository(choice, tokenID: tokenID))
                    } label: {
                        Label("Download IPA", systemImage: "arrow.down.circle.fill")
                            .font(.body.weight(.semibold))
                    }
                }
            }
        }
        .navigationTitle("Download from GitHub")
        .navigationBarTitleDisplayMode(.inline)
        .trackVisibleImportDownload(jobID)
    }
}
