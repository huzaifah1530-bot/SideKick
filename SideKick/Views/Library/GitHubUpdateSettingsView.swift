import SwiftUI

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
    @State private var selectedBaselineKey: String?
    @State private var recommendedBaselineKey: String?
    @State private var isLoadingHistory = false
    @State private var didLoad = false
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
        _repositoryURL = State(initialValue: isSideKick ? "https://github.com/huzaifah1530-bot/SideKick" : "")
        _source = State(initialValue: isSideKick ? .actionsArtifact : .latestRelease)
        _workflowFile = State(initialValue: isSideKick ? "ios-build.yml" : "build.yml")
        _assetName = State(initialValue: isSideKick ? "SideKick-unsigned-ipa" : "")
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
                Text("SideKick checks this GitHub repository for a newer IPA. A matching update is shown for your approval; it is never downloaded in the background. For Actions, the selected workflow must publish the IPA as a downloadable artifact. Use * in the asset name for changing version numbers.")
            }

            if !repositoryURL.isEmpty {
                Section {
                    if history.isEmpty && selectedBaselineKey == nil {
                        SwiftUI.Button {
                            Task { await loadHistory() }
                        } label: {
                            HStack {
                                Text("Find installed version")
                                Spacer()
                                if isLoadingHistory { ProgressView() }
                            }
                        }
                        .disabled(isLoadingHistory)
                    } else {
                        NavigationLink {
                            GitHubBaselineSelectionView(
                                history: history,
                                selectedKey: $selectedBaselineKey,
                                recommendedKey: recommendedBaselineKey
                            )
                        } label: {
                            LabeledContent(
                                "Version currently installed",
                                value: selectedBaselineKey.flatMap { selectedKey in
                                    history.first(where: { $0.key == selectedKey }).map(historyLabel)
                                } ?? selectedBaselineKey.map { "Saved build: \($0)" } ?? "Choose a version"
                            )
                        }
                        .fullWidthListSeparators()
                        if let recommendedBaselineKey,
                           let recommendation = history.first(where: { $0.key == recommendedBaselineKey }) {
                            Label("Suggested from the original IPA date: \(recommendation.title)", systemImage: "sparkles")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            SwiftUI.Button("Use Suggested Version") { selectedBaselineKey = recommendedBaselineKey }
                        } else {
                            Text("Choose the version you already have installed. SideKick uses this as the starting point and won’t ask you to reinstall it.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        SwiftUI.Button("Reload versions") { Task { await loadHistory() } }
                    }
                    SwiftUI.Button("Load older versions") { Task { await loadHistory(append: true) } }
                        .disabled(isLoadingHistory)
                } header: {
                    Text("Installed Version")
                } footer: {
                    Text("SideKick compares release or build history from this source. The version label in the IPA doesn’t need to match GitHub’s tag or build number.")
                }
            }

            if !repositoryURL.isEmpty {
                Section {
                    SwiftUI.Button("Save GitHub Update Settings") { Task { await save() } }
                        .disabled(selectedBaselineKey == nil)
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
            historyPage = 1
            recommendedBaselineKey = nil
            selectedBaselineKey = nil
            isLoadingHistory = false
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
                return
            }
            tokenID = config.tokenID
            repositoryURL = config.repositoryURL
            source = config.source
            workflowFile = config.workflowFile
            branch = config.branch
            assetName = config.assetName
            selectedBaselineKey = config.effectiveBaselineKey
            loadedSource = sourceIdentity
            await loadHistory(configuration: config)
        } catch { message = error.localizedDescription; showingMessage = true }

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
            let previous = try await store.configuration(for: target.id)
            var configuration = GitHubUpdateConfiguration(
                bundleIdentifier: target.id, repositoryURL: repositoryURL, source: source,
                workflowFile: workflowFile, branch: branch, assetName: assetName,
                baselineUpdateKey: selectedBaselineKey, lastInstalledUpdateKey: nil, tokenID: tokenID
            )
            if let previous, previous.hasSameSource(as: configuration) {
                configuration = previous
                configuration.tokenID = tokenID
                configuration.setInstalledBaseline(selectedBaselineKey)
            }
            try await store.save(configuration)
            dismiss()
        } catch { message = error.localizedDescription; showingMessage = true }
    }

    @MainActor
    private func loadHistory(configuration existing: GitHubUpdateConfiguration? = nil, append: Bool = false) async {
        guard !isLoadingHistory else { return }
        isLoadingHistory = true
        let generation = queryGeneration
        let identity = sourceIdentity
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
            let token = try GitHubCredentialStore().load(id: tokenID)
            let entries = try await GitHubUpdateService().history(for: configuration, token: token, page: page)
            guard queryGeneration == generation, sourceIdentity == identity, !Task.isCancelled else { return }
            historyPage = page
            if append {
                let known = Set(history.map(\.key))
                history += entries.filter { !known.contains($0.key) }
            } else { history = entries }
            recommendedBaselineKey = nil
            if selectedBaselineKey == nil {
                let storedKey = configuration.lastInstalledUpdateKey ?? configuration.baselineUpdateKey
                if let storedKey, let migrated = history.first(where: { legacyKey(for: $0.key) == storedKey }) {
                    selectedBaselineKey = migrated.key
                }
            }
            let importedApps = (try? await environment.ipaImportStore.importedApps()) ?? []
            let importedIPA = importedApps.first {
                $0.bundleIdentifier.lowercased() == target.id.lowercased()
            }
            let ipaDate = importedIPA?.sourceCreatedAt
            if let ipaDate, target.kind == .installed {
                recommendedBaselineKey = history
                    .filter { ($0.date ?? .distantFuture) <= ipaDate }
                    .max(by: { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) })?.key
            }
            if history.isEmpty { message = "No matching releases or downloadable build artifacts were found. Check the source settings and asset name."; showingMessage = true }
        } catch {
            guard queryGeneration == generation else { return }
            message = error.localizedDescription
            showingMessage = true
        }
    }

    private var sourceIdentity: String {
        [repositoryURL, source.rawValue, workflowFile, branch, assetName].joined(separator: "\n")
    }

    @MainActor
    private func loadHistory() async {
        await loadHistory(configuration: nil)
    }

    private func historyLabel(_ item: GitHubUpdateHistoryEntry) -> String {
        guard let date = item.date else { return item.title }
        return "\(item.title) · \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    private func legacyKey(for currentKey: String) -> String? {
        let parts = currentKey.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "release" else { return nil }
        return "release:\(parts[2]):\(parts[3])"
    }
}

private struct GitHubBaselineSelectionView: View {
    let history: [GitHubUpdateHistoryEntry]
    @Binding var selectedKey: String?
    let recommendedKey: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                if let recommendedKey,
                   let recommendation = history.first(where: { $0.key == recommendedKey }) {
                    SwiftUI.Button(action: {
                        select(recommendation)
                    }) {
                        HStack(spacing: 12) {
                            Image(systemName: "sparkles")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Suggested version")
                                    .font(.body.weight(.medium))
                                Text(historyLabel(recommendation))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selectedKey == recommendation.key {
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

                ForEach(history) { item in
                    SwiftUI.Button(action: {
                        select(item)
                    }) {
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
                Text("Select the release or build that is currently installed. SideKick will only offer newer entries as updates.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Installed Version")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func select(_ item: GitHubUpdateHistoryEntry) {
        selectedKey = item.key
        dismiss()
    }

    private func historyLabel(_ item: GitHubUpdateHistoryEntry) -> String {
        guard let date = item.date else { return item.title }
        return "\(item.title) · \(date.formatted(date: .abbreviated, time: .omitted))"
    }
}
