import SwiftUI

struct GitHubUpdateSettingsView: View {
    let app: InstalledAppSummary

    @Environment(\.dismiss) private var dismiss
    @State private var repositoryURL = ""
    @State private var source: GitHubUpdateSource = .latestRelease
    @State private var workflowFile = "build.yml"
    @State private var branch = "main"
    @State private var assetName = ""
    @State private var message: String?
    @State private var showingMessage = false

    private let store = GitHubUpdateConfigurationStore()

    init(app: InstalledAppSummary) {
        self.app = app
        let defaultRepo = app.bundleIdentifier == Bundle.main.bundleIdentifier
            ? "https://github.com/huzaifah1530-bot/SideKick"
            : ""
        _repositoryURL = State(initialValue: defaultRepo)
    }

    var body: some View {
        Form {
            Section {
                TextField("https://github.com/owner/repository", text: $repositoryURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Picker("Update source", selection: $source) {
                    ForEach(GitHubUpdateSource.allCases) { option in Text(option.title).tag(option) }
                }
                if source == .actionsArtifact {
                    TextField("Workflow file", text: $workflowFile)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Branch", text: $branch)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                TextField(source == .latestRelease ? "IPA asset name (optional)" : "Artifact name (optional)", text: $assetName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Update source")
            } footer: {
                Text("SideKick checks this public GitHub repository for a newer IPA. A matching update is shown for your approval; it is never downloaded in the background. For Actions, the selected workflow must publish the IPA as a downloadable artifact.")
            }

            if !repositoryURL.isEmpty {
                Section {
                    SwiftUI.Button("Save GitHub Update Settings") { Task { await save() } }
                    SwiftUI.Button("Remove GitHub Update Settings", role: .destructive) {
                        Task {
                            do { try await store.remove(bundleIdentifier: app.bundleIdentifier); dismiss() }
                            catch { message = error.localizedDescription; showingMessage = true }
                        }
                    }
                }
            }
        }
        .navigationTitle("GitHub Updates")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .alert("GitHub Updates", isPresented: $showingMessage) {
            SwiftUI.Button("OK", role: .cancel) { }
        } message: { Text(message ?? "") }
    }

    @MainActor
    private func load() async {
        guard let config = try? await store.configuration(for: app.bundleIdentifier) else { return }
        repositoryURL = config.repositoryURL
        source = config.source
        workflowFile = config.workflowFile
        branch = config.branch
        assetName = config.assetName
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
            let previous = try await store.configuration(for: app.bundleIdentifier)
            try await store.save(GitHubUpdateConfiguration(
                bundleIdentifier: app.bundleIdentifier,
                repositoryURL: repositoryURL,
                source: source,
                workflowFile: workflowFile,
                branch: branch,
                assetName: assetName,
                lastInstalledUpdateKey: previous?.repositoryURL == repositoryURL ? previous?.lastInstalledUpdateKey : nil
            ))
            dismiss()
        } catch { message = error.localizedDescription; showingMessage = true }
    }
}
