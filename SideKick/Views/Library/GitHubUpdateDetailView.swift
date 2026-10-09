import SwiftUI
import UIKit

struct GitHubUpdateRow: View {
    let candidate: GitHubUpdateCandidate
    let app: InstalledAppSummary

    var body: some View {
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
                Text("Update available · \(candidate.newVersion)")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text("UPDATE")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.blue)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
    }
}

struct GitHubUpdateDetailView: View {
    let candidate: GitHubUpdateCandidate
    let app: InstalledAppSummary

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var accountStore = SigningAccountStore()
    @State private var queuedIPA: ImportedIPA?
    @State private var isDownloading = false
    @State private var errorMessage: String?
    @State private var account: SigningAccountSummary?

    private let configurationStore = GitHubUpdateConfigurationStore()

    var body: some View {
        List {
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
                        Text("\(app.version)  →  \(queuedIPA?.version ?? candidate.newVersion)")
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
                if isDownloading {
                    HStack(spacing: 12) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Downloading IPA…").font(.body.weight(.medium))
                            Text("The update is checked before it’s queued.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 5)
                } else if let queuedIPA {
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
                    SwiftUI.Button {
                        Task { await downloadUpdate() }
                    } label: {
                        Label("Install New IPA", systemImage: "arrow.down.circle")
                            .fontWeight(.semibold)
                    }
                    .disabled(isDownloading)
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
        .alert("Couldn’t get update", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            SwiftUI.Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    @MainActor
    private func downloadUpdate() async {
        isDownloading = true
        defer { isDownloading = false }
        var temporaryURL: URL?
        do {
            let token = try GitHubCredentialStore().load()
            let downloaded = try await GitHubUpdateService().downloadIPA(for: candidate, token: token)
            temporaryURL = downloaded
            let queued = try await environment.ipaImportStore.importManagedIPA(
                from: downloaded,
                expectedBundleIdentifier: app.bundleIdentifier
            )
            queuedIPA = queued
        } catch {
            errorMessage = error.localizedDescription
        }
        if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
    }

    @MainActor
    private func finishUpdate(_ ipa: ImportedIPA) async {
        do {
            var configuration = try await configurationStore.configuration(for: app.bundleIdentifier)
            configuration?.lastInstalledUpdateKey = candidate.updateKey
            if let configuration { try await configurationStore.save(configuration) }
            try await environment.ipaImportStore.delete(ipa)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
