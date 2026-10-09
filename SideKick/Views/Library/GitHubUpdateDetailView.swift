import SwiftUI
import UIKit

struct GitHubUpdateRow: View {
    let candidate: GitHubUpdateCandidate
    let app: InstalledAppSummary
    @Environment(AppEnvironment.self) private var environment

    private var downloadJob: GitHubUpdateDownloadJob? { environment.githubUpdateDownloads.jobs[candidate.id] }

    var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 12) {
                if let data = app.iconData, let image = UIImage(data: data) {
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
                Text(downloadJob?.isDownloading == true ? "DOWNLOADING" : "UPDATE")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(downloadJob?.isDownloading == true ? Color.sideKickAccent : .blue)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            if let progress = downloadJob?.progress, downloadJob?.isDownloading == true {
                DownloadProgressBar(progress: progress).frame(height: 3)
            }
        }
        .padding(.vertical, 5)
    }

    private var updateStatus: String {
        guard let job = downloadJob else { return "Update available · \(candidate.newVersion)" }
        if job.isDownloading {
            return job.progress.map { "Downloading · \(Int($0 * 100))%" } ?? "Downloading…"
        }
        if job.queuedIPA != nil { return "Downloaded · Ready to update" }
        if job.errorMessage != nil { return "Download failed · Tap to retry" }
        return "Update available · \(candidate.newVersion)"
    }
}

struct GitHubUpdateDetailView: View {
    let candidate: GitHubUpdateCandidate
    let app: InstalledAppSummary

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var accountStore = SigningAccountStore()
    @State private var errorMessage: String?
    @State private var account: SigningAccountSummary?

    private let configurationStore = GitHubUpdateConfigurationStore()

    private var downloadJob: GitHubUpdateDownloadJob? { environment.githubUpdateDownloads.jobs[candidate.id] }

    var body: some View {
        List {
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
                        Text("\(app.version)  →  \(downloadJob?.queuedIPA?.version ?? candidate.newVersion)")
                            .foregroundStyle(.secondary)
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
                            if let progress = job.progress { Text("\(Int(progress * 100))%") }
                            else { ProgressView().controlSize(.small) }
                        }
                        Text("You can leave this page; the download will continue.")
                            .font(.footnote).foregroundStyle(.secondary)
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
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
                    .listRowBackground(Color.clear)
                } else if let message = job?.errorMessage {
                    VStack(alignment: .leading, spacing: 11) {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                        downloadButton(title: "Try Again") { startDownload() }
                    }
                    .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
                    .listRowBackground(Color.clear)
                } else if let queuedIPA = job?.queuedIPA {
                    if let account {
                        NavigationLink {
                            InstallConsoleView(
                                app: queuedIPA,
                                account: account,
                                accountStore: accountStore,
                                ipaStore: environment.ipaImportStore,
                                isUpdate: true,
                                onInstalled: { await finishUpdate(queuedIPA) }
                            )
                        } label: {
                            Label("Update App", systemImage: "arrow.down.app.fill")
                                .fontWeight(.semibold)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                    } else {
                        Text("Add back the Apple account that originally installed this app to update it.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    downloadButton(title: "Install New IPA") { startDownload() }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("App Update")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await accountStore.reload()
            account = accountStore.accounts.first {
                $0.accountIdentifier == app.accountIdentifier
                    && $0.teamIdentifier == app.teamIdentifier
                    && $0.hasSavedSession
            }
        }
    }

    @MainActor
    private func startDownload() {
        let token = try? GitHubCredentialStore().load()
        environment.githubUpdateDownloads.start(
            candidate: candidate,
            expectedBundleIdentifiers: [app.bundleIdentifier, app.resignedBundleIdentifier],
            ipaImportStore: environment.ipaImportStore,
            token: token
        )
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
            var configuration = try await configurationStore.configuration(for: app.bundleIdentifier)
            configuration?.lastInstalledUpdateKey = candidate.updateKey
            if let configuration { try await configurationStore.save(configuration) }
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
