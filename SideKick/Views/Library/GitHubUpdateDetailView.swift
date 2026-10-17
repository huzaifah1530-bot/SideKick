import SwiftUI
import UIKit

struct GitHubUpdateDetailView: View {
    let candidate: GitHubUpdateCandidate
    let app: InstalledAppSummary
    let isVersionSelection: Bool
    let showsDetails: Bool

    private var selectedCandidate: GitHubUpdateCandidate { candidate }

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var accountStore = SigningAccountStore()
    @State private var errorMessage: String?
    @State private var isConfirmingInstalledBuild = false
    @State private var isConfirmingSkip = false
    @State private var tokenID: String?
    @State private var isLoadingToken = true
    @State private var discoveredBuilds: [GitHubUpdateCandidate]
    @State private var isLoadingBuilds = false
    @State private var buildHistoryPage = 0
    @State private var hasMoreBuilds = true
    @State private var installedBuildKey: String?

    private let configurationStore = GitHubUpdateConfigurationStore.shared

    init(candidate: GitHubUpdateCandidate, app: InstalledAppSummary, isVersionSelection: Bool = false, showsDetails: Bool = false) {
        self.candidate = candidate
        self.app = app
        self.isVersionSelection = isVersionSelection
        self.showsDetails = showsDetails
        _discoveredBuilds = State(initialValue: [candidate])
    }

    private var expectedUpdateBundleIdentifiers: Set<String> {
        app.updateMatchingBundleIdentifiers
    }

    private var eligibleAccounts: [SigningAccountSummary] { accountStore.accounts }

    private var account: SigningAccountSummary? {
        eligibleAccounts.first {
            $0.hasSavedSession &&
            $0.accountIdentifier == app.accountIdentifier &&
            $0.teamIdentifier == app.teamIdentifier
        }
    }

    private var downloadJob: GitHubUpdateDownloadJob? { environment.githubUpdateDownloads.jobs[selectedCandidate.id] }

    private var installedBuildIsUnconfirmed: Bool {
        environment.githubChecks.contains {
            $0.targetID == app.id && $0.state == .unknownInstalledBuild &&
                $0.checkedConfiguration?.sourceIdentity == selectedCandidate.sourceIdentity
        }
    }

    var body: some View {
        List {
            if !showsDetails && !isVersionSelection {
                reviewContent
            } else {
                detailsContent
            }
        }
        .listStyle(.insetGrouped)
        .toolbar { reviewToolbar }
        .navigationTitle(isVersionSelection ? "Install Version" : showsDetails ? "Builds" : "Update")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { Task { await accountStore.reload() } }
        .onReceive(NotificationCenter.default.publisher(for: .sideKickSigningAccountsDidChange)) { _ in
            Task { await accountStore.reload() }
        }
        .task {
            do {
                let configuration = try await configurationStore.configuration(for: app.id)
                tokenID = configuration?.tokenID
                installedBuildKey = configuration?.effectiveBaselineKey
            } catch { errorMessage = error.localizedDescription }
            isLoadingToken = false
            await validateDownload()
            if showsDetails && !isVersionSelection { await loadBuilds() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await validateDownload() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sideKickImportedIPAsDidChange)) { _ in
            Task { await validateDownload() }
        }
        .alert("Installed this exact build?", isPresented: $isConfirmingInstalledBuild) {
            SwiftUI.Button("I’ve Installed It") { Task { await resolveUpdate(markInstalled: true) } }
            SwiftUI.Button("Cancel", role: .cancel) { }
        } message: {
            Text("Only confirm if you installed this GitHub build. A matching version name isn’t enough.")
        }
        .confirmationDialog("Skip this build?", isPresented: $isConfirmingSkip, titleVisibility: .visible) {
            SwiftUI.Button("Skip Build", role: .destructive) { Task { await resolveUpdate(markInstalled: false) } }
            SwiftUI.Button("Cancel", role: .cancel) { }
        } message: {
            Text("This build will be hidden. Future updates from this source will still appear.")
        }
    }

    @ViewBuilder
    private var detailsContent: some View {
        if isVersionSelection || selectedCandidate.updateKey != candidate.updateKey {
            Section {
                Text("You selected a build from history. Installing it can replace a newer installed version.")
                    .foregroundStyle(.secondary)
            }
        } else if !selectedCandidate.isKnownNewer {
            Section { Text("The installed GitHub build is unverified. Review this downloadable build or confirm the build you already installed.").foregroundStyle(.secondary) }
        }
        Section {
            DetailHeader(iconData: app.iconData, title: app.name, subtitle: selectedCandidate.newVersion)
        }
        .listRowBackground(Color.clear)

        if let errorMessage {
            Section {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.red).textSelection(.enabled)
            }
        }

        Section {
            LabeledContent("Installed", value: installedBuildText)
            LabeledContent("Selected", value: downloadJob?.queuedIPA.map { "\($0.version) (\($0.buildVersion))" } ?? selectedCandidate.newVersion)
            LabeledContent("Release", value: selectedCandidate.title).lineLimit(3)
            LabeledContent("File", value: selectedCandidate.assetName).lineLimit(2)
            LabeledContent("Source", value: selectedCandidate.source.title)
            LabeledContent("Apple Account", value: account?.email ?? app.accountEmail)
            GitHubTokenSelectionLink(selection: $tokenID).disabled(downloadJob?.isDownloading == true)
        } footer: {
            if selectedCandidate.source == .actionsArtifact {
                Text("Actions builds need a GitHub token with Actions read access.")
            }
        }

        if !isVersionSelection { Section {
            ForEach(discoveredBuilds) { build in
                NavigationLink {
                    GitHubUpdateDetailView(candidate: build, app: app, isVersionSelection: true)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(build.title).foregroundStyle(.primary).lineLimit(2)
                            Text(build.assetName + " · " + build.newVersion)
                                .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if build.updateKey == selectedCandidate.updateKey {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.sideKickAccent)
                                .accessibilityLabel("Selected")
                        } else if build.updateKey == installedBuildKey {
                            StatusBadge(title: "Installed", systemImage: "checkmark", tone: .neutral)
                        }
                    }
                    .contentShape(Rectangle())
                }
            }
            if hasMoreBuilds {
                SwiftUI.Button {
                    Task { await loadBuilds(append: true) }
                } label: {
                    HStack {
                        Text(isLoadingBuilds ? "Loading builds…" : "Load older builds")
                        Spacer()
                        if isLoadingBuilds { ProgressView() }
                    }
                }
                .disabled(isLoadingBuilds)
            }
        } header: {
            Text("Other Builds")
        } footer: {
            Text("A build is recorded as installed only after it installs.")
        } }

        Section("Download") {
            GitHubUpdateDownloadControls(
                job: downloadJob,
                onDownload: { startDownload() },
                onCancel: { environment.githubUpdateDownloads.cancelDownload(for: selectedCandidate) },
                onSkip: { Task { await resolveUpdate(markInstalled: false) } },
                allowsSkip: !isVersionSelection && selectedCandidate.updateKey == candidate.updateKey,
                isDisabled: isLoadingToken
            ) {
                if let queuedIPA = downloadJob?.queuedIPA {
                    installAction(for: queuedIPA)
                }
            }
        }

        Section {
            if downloadJob?.isDownloading != true {
                if let queuedIPA = downloadJob?.queuedIPA {
                    NavigationLink {
                        InstallAccountSelectionView(
                            app: queuedIPA,
                            accountStore: accountStore,
                            ipaStore: environment.ipaImportStore,
                            isUpdate: true,
                            onInstalled: { await finishUpdate(queuedIPA) },
                            onSourceMissing: { await validateDownload() },
                            currentTeamIdentifier: app.teamIdentifier
                        )
                    } label: {
                        Label("Update with Another Account…", systemImage: "person.2")
                    }
                }
                if installedBuildIsUnconfirmed {
                    SwiftUI.Button { isConfirmingInstalledBuild = true } label: {
                        Label("I’ve Installed This Build", systemImage: "checkmark.circle")
                    }
                }
            }
            NavigationLink {
                GitHubUpdateSettingsView(app: app)
            } label: {
                Label("Update Source", systemImage: "arrow.down.app")
            }
        }
    }

    @ViewBuilder
    private var reviewContent: some View {
        Section {
            DetailHeader(iconData: app.iconData, title: app.name, subtitle: selectedCandidate.title) {
                StatusBadge(
                    title: selectedCandidate.isKnownNewer ? "Update available" : "Build to review",
                    systemImage: selectedCandidate.isKnownNewer ? "arrow.down.circle.fill" : "questionmark.circle",
                    tone: selectedCandidate.isKnownNewer ? .accent : .neutral
                )
            }
        }
        .listRowBackground(Color.clear)

        Section {
            LabeledContent("Installed", value: installedBuildText)
            LabeledContent("Available", value: selectedCandidate.newVersion)
        } footer: {
            if installedBuildIsUnconfirmed {
                Text("SideKick can’t tell which GitHub build you installed. If it’s this one, choose I’ve Installed This Build from the menu.")
            }
        }

        if let errorMessage {
            Section {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.red).textSelection(.enabled)
            }
        }

        if selectedCandidate.source == .actionsArtifact, tokenID == nil, !isLoadingToken {
            Section {
                GitHubTokenSelectionLink(selection: $tokenID).disabled(downloadJob?.isDownloading == true)
            } footer: {
                Text("Actions builds need a GitHub token with Actions read access.")
            }
        }

        Section {
            GitHubUpdateDownloadControls(
                job: downloadJob,
                onDownload: { startDownload() },
                onCancel: { environment.githubUpdateDownloads.cancelDownload(for: selectedCandidate) },
                onSkip: {},
                allowsSkip: false,
                isDisabled: isLoadingToken
            ) {
                if let queuedIPA = downloadJob?.queuedIPA { installAction(for: queuedIPA) }
            }
        } footer: {
            if downloadJob?.queuedIPA == nil {
                Text("Nothing installs until you tap Install Update.")
            }
        }
    }

    private var installedBuildText: String {
        if let label = environment.githubConfigurations.first(where: { $0.id == app.id })?.installedBuildLabel {
            return label
        }
        return "\(app.version) (\(app.buildVersion))"
    }

    @ToolbarContentBuilder
    private var reviewToolbar: some ToolbarContent {
        if !showsDetails && !isVersionSelection {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    NavigationLink {
                        GitHubUpdateDetailView(candidate: candidate, app: app, showsDetails: true)
                    } label: {
                        Label("Other Builds & Details", systemImage: "list.bullet")
                    }
                    if installedBuildIsUnconfirmed && downloadJob?.isDownloading != true {
                        SwiftUI.Button { isConfirmingInstalledBuild = true } label: {
                            Label("I’ve Installed This Build", systemImage: "checkmark.circle")
                        }
                    }
                    if downloadJob?.isDownloading != true {
                        Divider()
                        SwiftUI.Button(role: .destructive) { isConfirmingSkip = true } label: {
                            Label("Skip This Build", systemImage: "forward.end")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        }
    }

    @ViewBuilder
    private func installAction(for queuedIPA: ImportedIPA) -> some View {
        if let account {
            NavigationLink {
                InstallConsoleView(
                    app: queuedIPA,
                    account: account,
                    accountStore: accountStore,
                    ipaStore: environment.ipaImportStore,
                    isUpdate: true,
                    onInstalled: { await finishUpdate(queuedIPA) },
                    onSourceMissing: { await validateDownload() }
                )
            } label: {
                ActionLabel(isVersionSelection ? "Install This Version" : "Install Update")
            }
            .primaryActionStyle()
        } else if let installedTeamAccount = eligibleAccounts.first(where: {
            $0.accountIdentifier == app.accountIdentifier && $0.teamIdentifier == app.teamIdentifier
        }) {
            NavigationLink {
                SigningAccountDetailView(account: installedTeamAccount, accountStore: accountStore)
            } label: {
                ActionLabel("Reconnect Account to Install", systemImage: "person.crop.circle.badge.exclamationmark")
            }
            .primaryActionStyle()
        } else {
            NavigationLink { AccountsView() } label: {
                ActionLabel("Add Account for Team \(app.teamIdentifier)", systemImage: "person.crop.circle.badge.plus")
            }
            .primaryActionStyle()
        }
    }

    @MainActor
    private func loadBuilds(append: Bool = false, forceRefresh: Bool = false) async {
        guard !isLoadingBuilds, !isLoadingToken else { return }
        isLoadingBuilds = true
        defer { isLoadingBuilds = false }
        do {
            guard let configuration = try await configurationStore.configuration(for: app.id) else { return }
            let token = try GitHubCredentialStore().load(id: tokenID)
            let page = append ? buildHistoryPage + 1 : 1
            let result = try await GitHubUpdateService().buildHistory(for: configuration, token: token, page: page, forceRefresh: forceRefresh)
            let builds = result.builds.map { build in
                GitHubUpdateCandidate(
                    bundleIdentifier: app.id,
                    appName: app.name,
                    currentVersion: app.version,
                    newVersion: build.version,
                    title: build.title,
                    assetName: build.assetName,
                    downloadURL: build.downloadURL,
                    updateKey: build.key,
                    source: configuration.source,
                    repositoryURL: configuration.repositoryURL,
                    targetKind: app.updateTarget.kind,
                    sourceIdentity: configuration.sourceIdentity,
                    isKnownNewer: configuration.effectiveBaselineKey.map {
                        GitHubTrackingPolicy.compare(build.key, to: $0) == .newer
                    } ?? false,
                    buildDate: build.date
                )
            }
            buildHistoryPage = page
            hasMoreBuilds = result.hasMore
            if append {
                let known = Set(discoveredBuilds.map(\.updateKey))
                discoveredBuilds += builds.filter { !known.contains($0.updateKey) }
            } else {
                discoveredBuilds = builds
            }
            if !discoveredBuilds.contains(where: { $0.updateKey == selectedCandidate.updateKey }) {
                discoveredBuilds.insert(selectedCandidate, at: 0)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func startDownload() {
        guard !isLoadingToken else { return }
        do {
            let token = try GitHubCredentialStore().load(id: tokenID)
            environment.githubUpdateDownloads.start(
                candidate: selectedCandidate,
                expectedBundleIdentifiers: expectedUpdateBundleIdentifiers,
                ipaImportStore: environment.ipaImportStore,
                token: token
            )
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor
    private func validateDownload() async {
        await environment.githubUpdateDownloads.validateQueuedFiles(ipaImportStore: environment.ipaImportStore)
    }

    @MainActor
    private func resolveUpdate(markInstalled: Bool) async {
        var resolutionRecorded = false
        do {
            guard let source = selectedCandidate.sourceIdentity else {
                errorMessage = "This update source is unavailable. The downloaded IPA was kept; reload the update and try again."
                return
            }
            guard let configuration = try await configurationStore.configuration(for: app.id) else {
                errorMessage = "This update configuration could not be found. The downloaded IPA was kept. Check the app’s GitHub update settings and try again."
                return
            }
            guard configuration.sourceIdentity == selectedCandidate.sourceIdentity else {
                errorMessage = "This update source changed. The downloaded IPA was kept; reopen the update from the current source."
                return
            }

            if markInstalled {
                let apps = try await SideStoreOperationService(accountStore: accountStore, ipaStore: environment.ipaImportStore)
                    .loadInstalledApps(loadIcons: false)
                guard let fresh = apps.first(where: { $0.id == app.id }) else {
                    errorMessage = "SideKick couldn’t find this installed app. The downloaded IPA was kept; refresh the app list and try again."
                    return
                }
                let imports = try await environment.ipaImportStore.importedApps()
                let queuedIPA = matchingQueuedIPA(in: imports)
                guard try await configurationStore.recordInstalled(
                    key: selectedCandidate.updateKey,
                    for: fresh.updateTarget,
                    expectedSource: source
                ) else {
                    errorMessage = "The update source changed before this build could be recorded. The downloaded IPA was kept; reopen the current update and try again."
                    return
                }
                resolutionRecorded = true
                if let queuedIPA { try await environment.ipaImportStore.delete(queuedIPA) }
            } else {
                let imports = try await environment.ipaImportStore.importedApps()
                let queuedIPA = matchingQueuedIPA(in: imports)
                guard try await configurationStore.skip(
                    key: selectedCandidate.updateKey,
                    title: selectedCandidate.title,
                    date: selectedCandidate.buildDate,
                    targetID: app.id,
                    expectedSource: source
                ) else {
                    errorMessage = "The update source changed before this update could be skipped. The downloaded IPA was kept; reopen the current update and try again."
                    return
                }
                resolutionRecorded = true
                if let queuedIPA { try await environment.ipaImportStore.delete(queuedIPA) }
            }

            environment.githubUpdateDownloads.removeJob(for: selectedCandidate)
            dismiss()
        } catch {
            if resolutionRecorded {
                errorMessage = "This update was recorded, but its queued IPA couldn’t be removed. The download is still available. \(error.localizedDescription)"
            } else {
                errorMessage = "Could not resolve this update. The queued IPA and download state were preserved. \(error.localizedDescription)"
            }
        }
    }

    private func matchingQueuedIPA(in imports: [ImportedIPA]) -> ImportedIPA? {
        func matches(_ ipa: ImportedIPA) -> Bool {
            ipa.queuedForInstalledAppID == selectedCandidate.bundleIdentifier &&
                ipa.githubUpdateKey == selectedCandidate.updateKey &&
                ipa.githubSourceIdentity == selectedCandidate.sourceIdentity &&
                ipa.githubRepositoryURL == selectedCandidate.repositoryURL
        }
        if let queuedIPA = downloadJob?.queuedIPA, matches(queuedIPA) { return queuedIPA }
        return imports.first(where: matches)
    }

    @MainActor
    private func finishUpdate(_ ipa: ImportedIPA) async {
        do {
            try await environment.ipaImportStore.delete(ipa)
            environment.githubUpdateDownloads.removeJob(for: selectedCandidate)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct GitHubUpdateDownloadControls<FinalAction: View>: View {
    let job: GitHubUpdateDownloadJob?
    let onDownload: () -> Void
    let onCancel: () -> Void
    let onSkip: () -> Void
    let allowsSkip: Bool
    let isDisabled: Bool
    let isSkipDisabled: Bool
    let finalAction: () -> FinalAction
    @State private var isConfirmingSkip = false

    init(
        job: GitHubUpdateDownloadJob?,
        onDownload: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onSkip: @escaping () -> Void,
        allowsSkip: Bool = true,
        isDisabled: Bool = false,
        isSkipDisabled: Bool = false,
        @ViewBuilder finalAction: @escaping () -> FinalAction
    ) {
        self.job = job
        self.onDownload = onDownload
        self.onCancel = onCancel
        self.onSkip = onSkip
        self.allowsSkip = allowsSkip
        self.isDisabled = isDisabled
        self.isSkipDisabled = isSkipDisabled
        self.finalAction = finalAction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let job, job.isDownloading {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("Downloading IPA…").font(.body.weight(.medium))
                        Spacer()
                        if let progress = job.progress {
                            Text(progress > 0 && progress < 0.01 ? "<1%" : String(format: "%.1f%%", progress * 100))
                                .font(.footnote.monospacedDigit())
                        }
                    }
                    if let progress = job.progress {
                        DownloadProgressBar(progress: progress).frame(height: 3)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    if job.bytesWritten > 0 {
                        let transferred = ByteCountFormatter.string(fromByteCount: job.bytesWritten, countStyle: .file)
                        Text(job.totalBytesExpected.map {
                            "Downloaded \(transferred) of \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))"
                        } ?? "Downloaded \(transferred) · total size unknown")
                            .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                    } else if job.totalBytesExpected == nil {
                        Text("The server did not report a file size; download activity is still shown above.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("You can leave this screen; the download continues.")
                        .font(.footnote).foregroundStyle(.secondary)
                    SwiftUI.Button("Cancel Download", role: .cancel, action: onCancel)
                        .font(.body.weight(.semibold))
                }
            } else if let message = job?.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                if job?.queuedIPA != nil { finalAction().disabled(isDisabled) }
                actionButton("Try Again", action: onDownload)
            } else if job?.queuedIPA != nil {
                finalAction().disabled(isDisabled)
                SwiftUI.Button("Download Again", action: onDownload)
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .disabled(isDisabled)
            } else {
                actionButton("Download IPA", action: onDownload).disabled(isDisabled)
            }

            if allowsSkip, job?.isDownloading != true {
                SwiftUI.Button { isConfirmingSkip = true } label: {
                    Label("Skip This Build", systemImage: "forward.end")
                }
                .disabled(isSkipDisabled)
            }
        }
        .confirmationDialog("Skip this update?", isPresented: $isConfirmingSkip, titleVisibility: .visible) {
            SwiftUI.Button("Skip Update", role: .destructive, action: onSkip)
            SwiftUI.Button("Cancel", role: .cancel) { }
        } message: {
            Text("This build will be hidden. SideKick will still show future updates from this source.")
        }
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        SwiftUI.Button(action: action) {
            ActionLabel(title, systemImage: "arrow.down.circle")
        }
        .primaryActionStyle()
    }
}

private struct DownloadProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(Color.sideKickAccent)
                    .frame(width: geometry.size.width * min(max(progress, 0), 1))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Download progress")
        .accessibilityValue("\(Int(progress * 100)) percent")
    }
}
