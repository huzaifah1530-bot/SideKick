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

    private let configurationStore = GitHubUpdateConfigurationStore.shared

    private var expectedUpdateBundleIdentifiers: Set<String> {
        app.updateMatchingBundleIdentifiers
    }

    private var downloadJob: GitHubUpdateDownloadJob? { environment.githubUpdateDownloads.jobs[candidate.id] }

    var body: some View {
        List {
            if !candidate.isKnownNewer {
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
                            : "\(app.version) (\(app.buildVersion))  →  \(downloadJob?.queuedIPA?.version ?? candidate.newVersion) (\(downloadJob?.queuedIPA?.buildVersion ?? "unknown build"))")
                            .foregroundStyle(.secondary)
                        if candidate.source == .actionsArtifact {
                            Text(candidate.newVersion)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 5)
            }

            Section("Update") {
                LabeledContent("Source", value: candidate.source.title)
                LabeledContent("GitHub", value: candidate.title).lineLimit(2)
                LabeledContent("Download", value: candidate.assetName).lineLimit(2)
                LabeledContent("Signing account", value: account?.email ?? app.accountEmail)
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
                            if account.teamIdentifier != app.teamIdentifier {
                                SeparateInstallReviewView(source: queuedIPA, account: account, accountStore: accountStore, originalName: app.name)
                            } else {
                                InstallConsoleView(
                                    app: queuedIPA,
                                    account: account,
                                    accountStore: accountStore,
                                    ipaStore: environment.ipaImportStore,
                                    isUpdate: true,
                                    onInstalled: { await finishUpdate(queuedIPA) },
                                    onSourceMissing: { await validateDownload() }
                                )
                            }
                        } label: {
                            Label("Update App", systemImage: "arrow.down.app.fill")
                                .fontWeight(.semibold)
                        }
                        .buttonStyle(.plain)
                        .fullWidthListSeparators()
                    } else {
                        Text(eligibleAccounts.isEmpty
                            ? "Add the Apple account that originally installed this app in Accounts to update it."
                            : "Choose a saved Apple account on the app’s signing team to update it.")
                            .font(.footnote).foregroundStyle(.secondary)
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
                    SwiftUI.Button { isConfirmingSkip = true } label: {
                        Label("Skip This Update", systemImage: "forward.end")
                    }
                    .fullWidthListSeparators()
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
            account = eligibleAccounts.filter(\.hasSavedSession).first {
                $0.accountIdentifier == app.accountIdentifier
            } ?? eligibleAccounts.first(where: \.hasSavedSession)
        }
        .task {
            do {
                tokenID = try await configurationStore.configuration(for: app.id)?.tokenID
            } catch { errorMessage = error.localizedDescription }
            isLoadingToken = false
            await validateDownload()
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
    private func startDownload() {
        guard !isLoadingToken else { return }
        do {
            let token = try GitHubCredentialStore().load(id: tokenID)
            environment.githubUpdateDownloads.start(
                candidate: candidate,
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
        do {
            guard let configuration = try await configurationStore.configuration(for: app.id) else { return }
            guard configuration.sourceIdentity == candidate.sourceIdentity else {
                environment.githubUpdateDownloads.removeJob(for: candidate)
                dismiss()
                return
            }
            let imports = try await environment.ipaImportStore.importedApps()
            if let ipa = downloadJob?.queuedIPA ?? imports.first(where: {
                $0.queuedForInstalledAppID == candidate.bundleIdentifier && $0.githubUpdateKey == candidate.updateKey && $0.githubRepositoryURL == candidate.repositoryURL
            }) {
                try await environment.ipaImportStore.delete(ipa)
            }
            environment.githubUpdateDownloads.removeJob(for: candidate)
            if let source = candidate.sourceIdentity {
                if markInstalled {
                    let apps = await SideStoreOperationService(accountStore: accountStore, ipaStore: environment.ipaImportStore).installedApps()
                    guard let fresh = apps.first(where: { $0.id == app.id }) else { return }
                    _ = try await configurationStore.recordInstalled(key: candidate.updateKey, for: fresh.updateTarget, expectedSource: source)
                } else {
                    _ = try await configurationStore.skip(key: candidate.updateKey, targetID: app.id, expectedSource: source)
                }
            }
            dismiss()
        } catch { errorMessage = error.localizedDescription }
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
            environment.githubUpdateDownloads.removeJob(for: candidate)
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
