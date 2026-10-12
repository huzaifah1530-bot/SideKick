import SwiftUI
import UIKit

struct GitHubUpdateRow: View {
    let candidate: GitHubUpdateCandidate
    let iconData: Data?
    init(candidate: GitHubUpdateCandidate, app: InstalledAppSummary) { self.candidate = candidate; iconData = app.iconData }
    init(candidate: GitHubUpdateCandidate, iconData: Data?) { self.candidate = candidate; self.iconData = iconData }
    @Environment(AppEnvironment.self) private var environment

    private var downloadJob: GitHubUpdateDownloadJob? { environment.githubUpdateDownloads.jobs[candidate.id] }

    var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 12) {
                if let data = iconData, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit().frame(width: 50, height: 50)
                        .clipShape(.rect(cornerRadius: 11))
                } else {
                    Image(systemName: "arrow.down.app.fill")
                        .font(.system(size: 24)).foregroundStyle(.white)
                        .frame(width: 50, height: 50).background(.blue.gradient, in: .rect(cornerRadius: 11))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.appName).font(.body.weight(.semibold))
                    Text(updateStatus)
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(downloadJob?.isDownloading == true ? "DOWNLOADING" : candidate.isKnownNewer ? "UPDATE" : "REVIEW")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(downloadJob?.isDownloading == true ? Color.sideKickAccent : .blue)
            }
            if let job = downloadJob, job.isDownloading {
                if let progress = job.progress {
                    DownloadProgressBar(progress: progress).frame(height: 3)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
        }
        .padding(.vertical, 5)
    }

    private var updateStatus: String {
        guard let job = downloadJob else { return "\(candidate.isKnownNewer ? "Update available" : "Confirm installed build") · \(candidate.newVersion)" }
        if job.isDownloading {
            let transferred = job.bytesWritten > 0
                ? ByteCountFormatter.string(fromByteCount: job.bytesWritten, countStyle: .file)
                : nil
            if let progress = job.progress {
                let percent = progress > 0 && progress < 0.01 ? "<1%" : String(format: "%.1f%%", progress * 100)
                return "Downloading · \(percent)" + (transferred.map { " · \($0)" } ?? "")
            }
            return transferred.map { "Downloading · \($0)" } ?? "Downloading…"
        }
        if job.queuedIPA != nil { return "Downloaded · Ready to update" }
        if job.errorMessage != nil { return "Download failed · Tap to retry" }
        return "\(candidate.isKnownNewer ? "Update available" : "Confirm installed build") · \(candidate.newVersion)"
    }
}

struct GitHubUpdateDetailView: View {
    let candidate: GitHubUpdateCandidate
    let app: InstalledAppSummary

    @State private var selectedCandidate: GitHubUpdateCandidate

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var accountStore = SigningAccountStore()
    @State private var errorMessage: String?
    @State private var account: SigningAccountSummary?
    @State private var eligibleAccounts: [SigningAccountSummary] = []
    @State private var isConfirmingInstalledBuild = false
    @State private var tokenID: String?
    @State private var isLoadingToken = true
    @State private var isConfirmingSkip = false
    @State private var discoveredBuilds: [GitHubUpdateCandidate]
    @State private var isLoadingBuilds = false
    @State private var buildHistoryPage = 0
    @State private var hasMoreBuilds = true
    @State private var installedBuildKey: String?

    private let configurationStore = GitHubUpdateConfigurationStore.shared

    init(candidate: GitHubUpdateCandidate, app: InstalledAppSummary) {
        self.candidate = candidate
        self.app = app
        _selectedCandidate = State(initialValue: candidate)
        _discoveredBuilds = State(initialValue: [candidate])
    }

    private var expectedUpdateBundleIdentifiers: Set<String> {
        app.updateMatchingBundleIdentifiers
    }

    private var downloadJob: GitHubUpdateDownloadJob? { environment.githubUpdateDownloads.jobs[selectedCandidate.id] }

    var body: some View {
        List {
            if selectedCandidate.updateKey != candidate.updateKey {
                Section {
                    Text("You selected a build from history. Installing it can replace a newer installed version.")
                        .foregroundStyle(.secondary)
                }
            } else if !selectedCandidate.isKnownNewer {
                Section { Text("The installed GitHub build is unverified. Review this downloadable build or confirm the build you already installed.").foregroundStyle(.secondary) }
            }
            Section { GitHubTokenSelectionLink(selection: $tokenID).disabled(downloadJob?.isDownloading == true) }
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                }
            }

            Section {
                HStack(spacing: 15) {
                    if let data = app.iconData, let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFit().frame(width: 72, height: 72)
                            .clipShape(.rect(cornerRadius: 16))
                    } else {
                        Image(systemName: "app.fill").font(.system(size: 34)).foregroundStyle(.white)
                            .frame(width: 72, height: 72).background(.blue.gradient, in: .rect(cornerRadius: 16))
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(app.name).font(.title3.weight(.semibold))
                        Text(app.version == downloadJob?.queuedIPA?.version && app.buildVersion == downloadJob?.queuedIPA?.buildVersion
                            ? "Version \(app.version) · Build \(app.buildVersion)"
                            : "\(app.version) (\(app.buildVersion))  →  \(downloadJob?.queuedIPA?.version ?? selectedCandidate.newVersion) (\(downloadJob?.queuedIPA?.buildVersion ?? "unknown build"))")
                            .foregroundStyle(.secondary)
                        if selectedCandidate.source == .actionsArtifact {
                            Text(selectedCandidate.newVersion)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 5)
            }

            Section("Update") {
                LabeledContent("Source", value: selectedCandidate.source.title)
                LabeledContent("GitHub", value: selectedCandidate.title).lineLimit(2)
                LabeledContent("Download", value: selectedCandidate.assetName).lineLimit(2)
                LabeledContent("Signing account", value: account?.email ?? app.accountEmail)
            }

            Section {
                ForEach(discoveredBuilds) { build in
                    SwiftUI.Button { selectedCandidate = build } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(build.title).foregroundStyle(.primary).lineLimit(2)
                                Text(build.assetName + " · " + build.newVersion)
                                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if build.updateKey == selectedCandidate.updateKey {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.sideKickAccent)
                            } else if build.updateKey == installedBuildKey {
                                Text("INSTALLED").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .fullWidthListSeparators()
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
                    .fullWidthListSeparators()
                }
            } header: {
                Text("Available Builds")
            } footer: {
                Text("Choose any discovered IPA build to install it. SideKick records it as installed only after installation succeeds.")
            }

            Section {
                if let job = downloadJob, job.isDownloading {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Downloading IPA…").font(.body.weight(.medium))
                            Spacer()
                            if let progress = job.progress {
                                Text(progress > 0 && progress < 0.01 ? "<1%" : String(format: "%.1f%%", progress * 100))
                            }
                            else { ProgressView().controlSize(.small) }
                        }
                        Text("You can leave this page; the download will continue.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if job.bytesWritten > 0 {
                            Text("Downloaded \(ByteCountFormatter.string(fromByteCount: job.bytesWritten, countStyle: .file))")
                                .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                    .padding(.bottom, 8)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 17))
                    .overlay(alignment: .bottom) {
                        if let progress = job.progress {
                            DownloadProgressBar(progress: progress)
                                .frame(height: 3)
                                .padding(.horizontal, 14)
                                .padding(.bottom, 8)
                        } else {
                            ProgressView().progressViewStyle(.linear)
                                .padding(.horizontal, 14)
                                .padding(.bottom, 8)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
                    .listRowBackground(Color.clear)
                } else if let message = downloadJob?.errorMessage {
                    VStack(alignment: .leading, spacing: 11) {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                        downloadButton(title: "Try Again") { startDownload() }
                    }
                    .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
                    .listRowBackground(Color.clear)
                } else if let queuedIPA = downloadJob?.queuedIPA {
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
                            Label("Update App", systemImage: "arrow.down.app.fill")
                                .fontWeight(.semibold)
                        }
                        .buttonStyle(.plain)
                        .fullWidthListSeparators()
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            if let installedTeamAccount = eligibleAccounts.first(where: {
                                $0.accountIdentifier == app.accountIdentifier &&
                                $0.teamIdentifier == app.teamIdentifier
                            }) {
                                NavigationLink {
                                    SigningAccountDetailView(account: installedTeamAccount, accountStore: accountStore)
                                } label: {
                                    Label("Reconnect the Apple account for this installed team", systemImage: "person.crop.circle.badge.exclamationmark")
                                }
                            } else {
                                NavigationLink {
                                    AccountsView()
                                } label: {
                                    Label("Add the Apple account for the installed team", systemImage: "person.crop.circle.badge.plus")
                                }
                            }
                            Text("The installed app uses team \(app.teamIdentifier). Use Options to choose another team for a separate installation.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                            NavigationLink {
                                InstallAccountSelectionView(
                                    app: queuedIPA,
                                    accounts: eligibleAccounts,
                                    accountStore: accountStore,
                                    ipaStore: environment.ipaImportStore,
                                    isUpdate: true,
                                    onInstalled: { await finishUpdate(queuedIPA) },
                                    onSourceMissing: { await validateDownload() },
                                    currentTeamIdentifier: app.teamIdentifier
                                )
                            } label: {
                                Label("Options", systemImage: "slider.horizontal.3")
                                    .font(.body)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .fullWidthListSeparators()
                } else {
                    downloadButton(title: "Install New IPA") { startDownload() }
                }
            }

            Section("Update Options") {
                if downloadJob?.isDownloading != true {
                    if downloadJob?.queuedIPA != nil {
                        SwiftUI.Button { startDownload() } label: {
                            Label("Download Again", systemImage: "arrow.down.circle")
                        }
                        .fullWidthListSeparators()
                    }
                    SwiftUI.Button { isConfirmingInstalledBuild = true } label: {
                        Label("Already Installed This Build", systemImage: "checkmark.circle")
                    }
                    .fullWidthListSeparators()
                    if selectedCandidate.updateKey == candidate.updateKey {
                        SwiftUI.Button { isConfirmingSkip = true } label: {
                            Label("Skip This Update", systemImage: "forward.end")
                        }
                        .fullWidthListSeparators()
                    }
                }
                NavigationLink {
                    GitHubUpdateSettingsView(app: app)
                } label: {
                    Label("Update Source & Installed Version", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .fullWidthListSeparators()
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("App Update")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await accountStore.reload()
            eligibleAccounts = accountStore.accounts
            account = eligibleAccounts.first {
                $0.hasSavedSession &&
                $0.accountIdentifier == app.accountIdentifier &&
                $0.teamIdentifier == app.teamIdentifier
            }
        }
        .task {
            do {
                let configuration = try await configurationStore.configuration(for: app.id)
                tokenID = configuration?.tokenID
                installedBuildKey = configuration?.effectiveBaselineKey
            } catch { errorMessage = error.localizedDescription }
            isLoadingToken = false
            await validateDownload()
            await loadBuilds()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await validateDownload() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sideKickImportedIPAsDidChange)) { _ in
            Task { await validateDownload() }
        }
        .alert("Already installed this build?", isPresented: $isConfirmingInstalledBuild) {
            SwiftUI.Button("Mark as Installed") { Task { await resolveUpdate(markInstalled: true) } }
            SwiftUI.Button("Cancel", role: .cancel) { }
        } message: {
            Text("Only choose this if you installed this exact GitHub release or build. Matching version names alone do not identify an Actions build.")
        }
        .alert("Skip this update?", isPresented: $isConfirmingSkip) {
            SwiftUI.Button("Skip Update") { Task { await resolveUpdate(markInstalled: false) } }
            SwiftUI.Button("Cancel", role: .cancel) { }
        } message: {
            Text("This build will be hidden. SideKick will still show future updates from this source.")
        }
    }

    @MainActor
    private func loadBuilds(append: Bool = false) async {
        guard !isLoadingBuilds, !isLoadingToken else { return }
        isLoadingBuilds = true
        defer { isLoadingBuilds = false }
        do {
            guard let configuration = try await configurationStore.configuration(for: app.id) else { return }
            let token = try GitHubCredentialStore().load(id: tokenID)
            let page = append ? buildHistoryPage + 1 : 1
            let result = try await GitHubUpdateService().buildHistory(for: configuration, token: token, page: page)
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
                    sourceIdentity: configuration.sourceIdentity,
                    isKnownNewer: configuration.effectiveBaselineKey.map {
                        GitHubTrackingPolicy.compare(build.key, to: $0) == .newer
                    } ?? false
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

    private func downloadButton(title: String, action: @escaping () -> Void) -> some View {
        SwiftUI.Button(action: action) {
            Label(title, systemImage: "arrow.down.circle")
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 17))
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
        .listRowBackground(Color.clear)
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

private struct DownloadProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(Color.sideKickAccentGradient)
                    .frame(width: geometry.size.width * min(max(progress, 0), 1))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Download progress")
        .accessibilityValue("\(Int(progress * 100)) percent")
    }
}
