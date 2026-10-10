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

    var body: some View {
        List {
            Section {
                Text(repositoryURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                    .font(.headline).textSelection(.enabled)
                GitHubTokenSelectionLink(selection: $tokenID)
                Picker("Source", selection: $source) {
                    Text("Releases").tag(GitHubUpdateSource.latestRelease)
                    Text("Actions Builds").tag(GitHubUpdateSource.actionsArtifact)
                }.pickerStyle(.segmented)
                if source == .actionsArtifact {
                    NavigationLink {
                        GitHubWorkflowPickerView(repositoryURL: repositoryURL.absoluteString, tokenID: tokenID, selection: $workflowID, selectedName: $workflowName)
                    } label: {
                        LabeledContent("Workflow", value: workflowName.isEmpty ? "Choose Workflow" : workflowName)
                    }
                    HStack {
                        Text("Branch")
                        TextField("Repository branch", text: $branchDraft)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onSubmit { branch = branchDraft.trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                    SwiftUI.Button("Load Branch Builds") { branch = branchDraft.trimmingCharacters(in: .whitespacesAndNewlines); reloadID = UUID() }
                }
            } header: { Text("Repository") } footer: {
                Text("Choose the IPA you want. After installation, SideKick tracks this exact release or build and uses this token for future update checks. Actions artifacts need a GitHub token and must contain an IPA.")
            }
            Section {
                ForEach(choices) { choice in
                    NavigationLink {
                        GitHubRepositoryDownloadView(choice: choice, tokenID: tokenID, onImported: onImported)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(choice.candidate.title).font(.body.weight(.medium))
                            Text(choice.candidate.assetName).font(.subheadline).foregroundStyle(.secondary)
                            if let date = choice.date {
                                Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .fullWidthListSeparators()
                }
                if isLoading { HStack { ProgressView(); Text("Finding downloads…") } }
                else if choices.isEmpty && errorMessage == nil {
                    ContentUnavailableView("No Downloads Found", systemImage: "arrow.down.doc", description: Text(source == .latestRelease ? "This repository has no release IPAs. Try Actions Builds or another token." : "Choose a workflow and branch with successful builds and unexpired IPA artifacts."))
                }
                if hasMore && !isLoading {
                    SwiftUI.Button("Load More") { Task { await loadMore() } }
                }
            } header: { Text(source == .latestRelease ? "Release IPAs" : "Successful Build Artifacts") }
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    SwiftUI.Button("Try Again") { reloadID = UUID() }
                }
            }
        }
        .navigationTitle("GitHub Repository")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: requestKey) { await load() }
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

private struct GitHubWorkflowPickerView: View {
    let repositoryURL: String
    let tokenID: String?
    @Binding var selection: String
    @Binding var selectedName: String
    @Environment(\.dismiss) private var dismiss
    @State private var workflows: [GitHubUpdateService.Workflow] = []
    @State private var page = 0
    @State private var hasMore = true
    @State private var loading = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            ForEach(workflows) { workflow in
                SwiftUI.Button {
                    selection = String(workflow.id); selectedName = workflow.name; dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(workflow.name).foregroundStyle(.primary)
                            Text(workflow.path).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selection == String(workflow.id) { Image(systemName: "checkmark") }
                    }
                }.fullWidthListSeparators()
            }
            if loading { ProgressView() }
            else if hasMore { SwiftUI.Button("Load More Workflows") { Task { await load() } } }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            if !loading && workflows.isEmpty && errorMessage == nil { Text("No workflows found in this repository.").foregroundStyle(.secondary) }
        }
        .navigationTitle("Choose Workflow")
        .navigationBarTitleDisplayMode(.inline)
        .task { if page == 0 { await load() } }
    }
    @MainActor private func load() async {
        guard !loading else { return }
        loading = true; errorMessage = nil
        defer { loading = false }
        do {
            let token = try GitHubCredentialStore().load(id: tokenID)
            let result = try await GitHubUpdateService().workflows(repositoryURL, token: token, page: page + 1)
            try Task.checkCancellation()
            let ids = Set(workflows.map(\.id))
            workflows += result.filter { !ids.contains($0.id) }; page += 1; hasMore = result.count == 100
        } catch is CancellationError { }
        catch { errorMessage = error.localizedDescription }
    }
}

private struct GitHubRepositoryDownloadView: View {
    let choice: GitHubImportChoice
    @State var tokenID: String?
    let onImported: (ImportedIPA) async throws -> Void
    @Environment(AppEnvironment.self) private var environment
    @State private var progress: GitHubDownloadProgress?
    @State private var task: Task<Void, Never>?
    @State private var importedApp: ImportedIPA?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                LabeledContent("Version", value: choice.candidate.newVersion)
                LabeledContent("Download", value: choice.candidate.assetName)
                GitHubTokenSelectionLink(selection: $tokenID).disabled(task != nil)
            } header: { Text(choice.candidate.title) } footer: {
                Text("Update tracking is configured when you install this IPA. Future downloads come from the same repository, workflow, branch, and asset name.")
            }
            Section {
                if let importedApp {
                    Label("Ready to install", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    NavigationLink { AppManagementView(importedApp: importedApp) } label: { Label("Review App", systemImage: "app") }
                } else if task != nil {
                    ProgressView(value: progress?.fractionCompleted)
                    Text(progress.map { ByteCountFormatter.string(fromByteCount: $0.bytesWritten, countStyle: .file) + " downloaded" } ?? "Starting download…")
                        .font(.subheadline).foregroundStyle(.secondary)
                    SwiftUI.Button("Cancel Download", role: .cancel) { task?.cancel() }
                } else {
                    SwiftUI.Button {
                        task = Task { await download() }
                    } label: { Label("Download IPA", systemImage: "arrow.down.circle.fill") }
                }
            }
            if let errorMessage { Section { Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red) } }
        }
        .navigationTitle("Download from GitHub")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { task?.cancel() }
    }
    @MainActor private func download() async {
        defer { task = nil }
        errorMessage = nil; progress = nil
        var prepared: ImportedIPA?
        do {
            let token = try GitHubCredentialStore().load(id: tokenID)
            let url = try await GitHubUpdateService().downloadIPA(for: choice.candidate, token: token) { value in
                Task { @MainActor in progress = value }
            }
            defer { try? FileManager.default.removeItem(at: url) }
            try Task.checkCancellation()
            let app = try await environment.ipaImportStore.importRepositoryIPA(from: url, choice: choice, tokenID: tokenID)
            prepared = app
            try Task.checkCancellation()
            try await onImported(app)
            importedApp = app
            prepared = nil
        } catch {
            if let prepared { try? await environment.ipaImportStore.delete(prepared) }
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }
}
