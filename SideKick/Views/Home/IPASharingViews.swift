import SwiftUI
import UIKit

struct ShareIPAView: View {
    let app: ImportedIPA

    @Environment(AppEnvironment.self) private var environment
    @State private var isUploading = false
    @State private var errorMessage: String?
    @State private var shareLink: URL?

    var body: some View {
        List {
            Section {
                LabeledContent("App", value: app.name)
                LabeledContent("Version", value: app.version)
            }

            Section {
                Text("This IPA is uploaded to a third-party site. Anyone with the link can download it.")
                Text("Links are temporary and may expire.")
            } header: {
                Text("Before you share")
            }

            Section {
                if isUploading {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Uploading \(app.name)…")
                    }
                } else if let shareLink {
                    ShareLink(item: shareLink) {
                        Label("Share Link", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    SwiftUI.Button {
                        UIPasteboard.general.url = shareLink
                    } label: {
                        Label("Copy SideKick Link", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(shareLink.absoluteString)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    SwiftUI.Button {
                        Task { await upload() }
                    } label: {
                        Label("Upload and Create Link", systemImage: "arrow.up.doc")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(isUploading)
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Share \(app.name)")
        .navigationBarTitleDisplayMode(.inline)
    }

    @MainActor
    private func upload() async {
        isUploading = true
        errorMessage = nil
        defer { isUploading = false }
        do {
            let fileURL = try await environment.ipaImportStore.fileURL(for: app)
            defer { try? FileManager.default.removeItem(at: fileURL) }
            let providerURL = try await BuzzheavierClient().upload(
                ipaURL: fileURL,
                fileName: "\(app.name)-\(app.version).ipa"
            )
            guard let link = SideKickShareLink.make(for: providerURL) else {
                throw AppSharingError.invalidShareLink
            }
            shareLink = link
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct URLImportView: View {
    let initialURL: URL?
    let onImported: (ImportedIPA) async -> Void

    @Environment(AppEnvironment.self) private var environment
    @State private var linkText = ""
    @State private var isDownloading = false
    @State private var downloadProgress: GitHubDownloadProgress?
    @State private var errorMessage: String?
    @State private var importedApp: ImportedIPA?
    @State private var importedAsUpdate = false
    @State private var pendingPreparedIPA: ImportedIPA?
    @State private var isQueueingSelectedIPA = false
    @State private var directDownloadTask: Task<Void, Never>?
    @State private var directDownloadID: UUID?
    @State private var matchingInstallations: [InstalledAppSummary] = []
    @State private var ipaAwaitingUpdateChoice: ImportedIPA?
    @State private var githubRepositoryURL: URL?
    @State private var showingGitHubRepository = false
    @State private var didStartIncomingImport = false
    @State private var importJobID: UUID?

    var body: some View {
        List {
            Section {
                TextField("https://…", text: $linkText, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textContentType(.URL)

                Text("Paste a GitHub repository URL, a direct HTTPS link to an IPA, or a SideKick share link. Some file hosts provide a web page rather than a direct download; SideKick will tell you if the response isn’t an IPA.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("IPA Link")
            }

            if let importJobID, environment.importDownloads.jobs[importJobID] != nil {
                Section {
                    ImportDownloadPanel(jobID: importJobID)
                    SwiftUI.Button("Download Another") { self.importJobID = nil; linkText = "" }
                }
            } else {
            Section {
                if isDownloading {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Downloading IPA…")
                            Spacer()
                            if let fraction = downloadProgress?.fractionCompleted {
                                Text(fraction > 0 && fraction < 0.01 ? "<1%" : "\(Int(fraction * 100))%")
                                    .monospacedDigit()
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        }
                        if let downloadProgress {
                            ProgressView(value: downloadProgress.fractionCompleted)
                            if downloadProgress.bytesWritten > 0 {
                                Text("Downloaded \(ByteCountFormatter.string(fromByteCount: downloadProgress.bytesWritten, countStyle: .file))")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        } else {
                            ProgressView()
                        }
                        Text("Checking the downloaded IPA after transfer…")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    SwiftUI.Button("Cancel Download", role: .cancel) { cancelDirectDownload() }
                        .font(.body.weight(.semibold))
                } else if let importedApp {
                    Label(
                        importedAsUpdate ? "Update queued for \(importedApp.name)" : "\(importedApp.name) is ready to install",
                        systemImage: "checkmark.circle.fill"
                    )
                        .foregroundStyle(.green)
                    NavigationLink {
                        if importedApp.isUpdateQueued {
                            AppManagementView(queuedUpdate: importedApp)
                        } else {
                            AppManagementView(importedApp: importedApp)
                        }
                    } label: {
                        Label(importedAsUpdate ? "Review update" : "Review \(importedApp.name)", systemImage: "app")
                    }
                    SwiftUI.Button(role: .destructive) {
                        Task { await deleteImportedApp(importedApp) }
                    } label: {
                        Label("Delete IPA", systemImage: "trash")
                    }
                } else {
                    SwiftUI.Button {
                        startDirectDownload()
                    } label: {
                        Label("Continue", systemImage: "arrow.down.circle")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(isDownloading || linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            }
            Section {
                Text("Only download apps you trust. IPA links are saved in SideKick after import. Files imports use the bookmarked file, so SideKick needs continued access to it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationDestination(isPresented: $showingGitHubRepository) {
            if let githubRepositoryURL {
                GitHubRepositoryImportView(repositoryURL: githubRepositoryURL) { app in
                    showingGitHubRepository = false
                    replacePendingPreparedIPA(with: app)
                    do {
                        try await acceptPreparedIPA(app)
                    } catch {
                        await discardFailedPreparedIPA(app)
                        errorMessage = error.localizedDescription
                        throw error
                    }
                }
            }
        }
        .trackVisibleImportDownload(importJobID)
        .navigationTitle("Import from URL")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "\(ipaAwaitingUpdateChoice?.name ?? "This app") is already installed",
            isPresented: Binding(
                get: { ipaAwaitingUpdateChoice != nil },
                set: {
                    if !$0 {
                        if !isQueueingSelectedIPA, let app = ipaAwaitingUpdateChoice {
                            discardPendingPreparedIPA(app)
                        }
                        ipaAwaitingUpdateChoice = nil
                    }
                }
            )
        ) {
            ForEach(matchingInstallations) { installation in
                SwiftUI.Button("Queue for \(installation.name) \(installation.accountEmail) (\(installation.teamIdentifier))") {
                    guard let app = ipaAwaitingUpdateChoice else { return }
                    isQueueingSelectedIPA = true
                    Task { await queuePendingUpdate(app, for: installation.id) }
                }
            }
            SwiftUI.Button("Cancel", role: .cancel) {
                if let app = ipaAwaitingUpdateChoice { discardPendingPreparedIPA(app) }
                ipaAwaitingUpdateChoice = nil
            }
        } message: {
            Text("Queue this IPA as the update for the installed app?")
        }
        .onAppear {
            guard let initialURL else { return }
            if linkText.isEmpty { linkText = initialURL.absoluteString }
            guard !didStartIncomingImport else { return }
            didStartIncomingImport = true
            startDirectDownload()
        }
        .onDisappear {
            directDownloadID = nil
            directDownloadTask?.cancel()
            directDownloadTask = nil
            isDownloading = false
            guard let app = pendingPreparedIPA else { return }
            pendingPreparedIPA = nil
            Task { await environment.ipaImportStore.discardPreparedIPA(app) }
        }
    }

    @MainActor
    private func cancelDirectDownload() {
        directDownloadID = nil
        directDownloadTask?.cancel()
        directDownloadTask = nil
        isDownloading = false
        downloadProgress = nil
        if let app = pendingPreparedIPA { discardPendingPreparedIPA(app) }
    }

    @MainActor
    private func deleteImportedApp(_ app: ImportedIPA) async {
        do {
            try await environment.ipaImportStore.delete(app)
            importedApp = nil
            importedAsUpdate = false
            await onImported(app)
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor
    private func startDirectDownload() {
        guard directDownloadTask == nil else { return }
        let id = UUID()
        directDownloadID = id
        directDownloadTask = Task { await download(generation: id) }
    }

    @MainActor
    private func download(generation: UUID) async {
        guard isCurrentDirectDownload(generation) else { return }
        isDownloading = true
        downloadProgress = nil
        errorMessage = nil
        var preparedIPA: ImportedIPA?
        defer {
            if directDownloadID == generation {
                isDownloading = false
                directDownloadID = nil
                directDownloadTask = nil
            }
        }

        do {
            let input = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = input.lowercased().hasPrefix("github.com/") || input.lowercased().hasPrefix("www.github.com/") ? "https://" + input : input
            guard let pastedURL = URL(string: normalized) else {
                throw AppSharingError.invalidShareLink
            }
            let sourceURL: URL
            if pastedURL.scheme?.lowercased() == "sidekick" {
                guard let sharedURL = SideKickShareLink.downloadURL(from: pastedURL) else {
                    throw AppSharingError.invalidShareLink
                }
                sourceURL = sharedURL
            } else {
                guard pastedURL.scheme?.lowercased() == "https" else {
                    throw AppSharingError.insecureURL
                }
                sourceURL = pastedURL
            }
            if ["github.com", "www.github.com"].contains(sourceURL.host?.lowercased() ?? ""),
               sourceURL.path.split(separator: "/").count >= 2,
               !sourceURL.path.lowercased().hasSuffix(".ipa") {
                githubRepositoryURL = sourceURL
                showingGitHubRepository = true
                return
            }
            // Direct links download in the background store so they survive leaving this page.
            importJobID = environment.importDownloads.start(.url(sourceURL))
            return
            let (downloadedURL, response) = try await BuzzheavierClient().download(from: sourceURL) { progress in
                Task { @MainActor in
                    guard directDownloadID == generation else { return }
                    downloadProgress = progress
                }
            }
            defer { try? FileManager.default.removeItem(at: downloadedURL) }
            guard isCurrentDirectDownload(generation) else { return }
            if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
                throw AppSharingError.downloadFailed(response.statusCode)
            }

            let app = try await environment.ipaImportStore.prepareIPA(from: downloadedURL, remoteSourceURL: sourceURL)
            preparedIPA = app
            guard isCurrentDirectDownload(generation) else {
                await environment.ipaImportStore.discardPreparedIPA(app)
                return
            }
            replacePendingPreparedIPA(with: app)
            try await acceptPreparedIPA(app)
        } catch let error as IPAImportError {
            await discardFailedPreparedIPA(preparedIPA)
            guard isCurrentDirectDownload(generation) else { return }
            switch error {
            case .invalidArchive, .missingAppBundle, .ambiguousAppBundles, .missingBundleIdentifier, .notAnIPA:
                errorMessage = "That link returned a web page or a file that isn’t a valid IPA. Use a direct IPA download link."
            case .inaccessibleFile, .sourceFileMissing, .sourceBookmarkUnavailable, .bundleIdentifierMismatch, .sourceChanged:
                errorMessage = error.localizedDescription
            }
        } catch {
            await discardFailedPreparedIPA(preparedIPA)
            guard isCurrentDirectDownload(generation) else { return }
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func isCurrentDirectDownload(_ generation: UUID) -> Bool {
        directDownloadID == generation && !Task.isCancelled
    }

    @MainActor
    private func discardFailedPreparedIPA(_ app: ImportedIPA?) async {
        guard let app else { return }
        if pendingPreparedIPA == app { pendingPreparedIPA = nil }
        await environment.ipaImportStore.discardPreparedIPA(app)
    }

    @MainActor
    private func acceptPreparedIPA(_ app: ImportedIPA) async throws {
        let service = SideStoreOperationService(accountStore: SigningAccountStore(), ipaStore: environment.ipaImportStore)
        let installedApps = try await service.loadInstalledApps()
        guard pendingPreparedIPA == app else {
            await environment.ipaImportStore.discardPreparedIPA(app)
            return
        }
        let installedIDs = Set(installedApps.flatMap(\.updateMatchingBundleIdentifiers))
        if installedIDs.contains(app.bundleIdentifier.lowercased()) {
            matchingInstallations = installedApps.filter { $0.updateMatchingBundleIdentifiers.contains(app.bundleIdentifier.lowercased()) }
            ipaAwaitingUpdateChoice = app
        } else {
            try await savePreparedIPA(app, asUpdate: false)
        }
    }

    @MainActor
    private func queuePendingUpdate(_ app: ImportedIPA, for targetID: String) async {
        defer { isQueueingSelectedIPA = false }
        if ipaAwaitingUpdateChoice == app { ipaAwaitingUpdateChoice = nil }
        do { try await savePreparedIPA(app, asUpdate: true, targetID: targetID) }
        catch {
            discardPendingPreparedIPA(app)
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func savePreparedIPA(_ app: ImportedIPA, asUpdate: Bool, targetID: String? = nil) async throws {
        var savedApp = app
        savedApp.isQueuedForUpdate = asUpdate
        savedApp.queuedForInstalledAppID = targetID
        try await environment.ipaImportStore.saveImportedIPA(savedApp)
        if pendingPreparedIPA == app { pendingPreparedIPA = nil }
        importedApp = savedApp
        importedAsUpdate = asUpdate
        await onImported(savedApp)
    }

    @MainActor
    private func discardPendingPreparedIPA(_ app: ImportedIPA) {
        if pendingPreparedIPA == app { pendingPreparedIPA = nil }
        Task { await environment.ipaImportStore.discardPreparedIPA(app) }
    }

    @MainActor
    private func replacePendingPreparedIPA(with app: ImportedIPA) {
        let previous = pendingPreparedIPA
        pendingPreparedIPA = app
        guard let previous, previous != app else { return }
        if ipaAwaitingUpdateChoice == previous { ipaAwaitingUpdateChoice = nil }
        Task { await environment.ipaImportStore.discardPreparedIPA(previous) }
    }

}
