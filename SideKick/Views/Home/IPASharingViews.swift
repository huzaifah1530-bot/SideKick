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
    @State private var ipaAwaitingUpdateChoice: ImportedIPA?
    @State private var didStartIncomingImport = false

    var body: some View {
        List {
            Section {
                TextField("https://…", text: $linkText, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textContentType(.URL)

                Text("Paste a direct HTTPS link to an IPA, or open a SideKick share link. Some file hosts provide a web page rather than a direct download; SideKick will tell you if the response isn’t an IPA.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("IPA Link")
            }

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
                } else if let importedApp {
                    Label(
                        importedAsUpdate ? "Update queued for \(importedApp.name)" : "\(importedApp.name) is ready to install",
                        systemImage: "checkmark.circle.fill"
                    )
                        .foregroundStyle(.green)
                    NavigationLink {
                        AppManagementView(importedApp: importedApp)
                    } label: {
                        Label(importedAsUpdate ? "Review update" : "Review \(importedApp.name)", systemImage: "app")
                    }
                } else {
                    SwiftUI.Button {
                        Task { await download() }
                    } label: {
                        Label("Download IPA", systemImage: "arrow.down.circle")
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

            Section {
                Text("Only download apps you trust. SideKick points to the original file or download link. If it’s moved, deleted, or expires, choose it again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Import from URL")
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            "\(ipaAwaitingUpdateChoice?.name ?? "This app") is already installed",
            isPresented: Binding(
                get: { ipaAwaitingUpdateChoice != nil },
                set: { if !$0 { ipaAwaitingUpdateChoice = nil } }
            )
        ) {
            SwiftUI.Button("Queue for Update") { Task { await queuePendingUpdate() } }
            SwiftUI.Button("Cancel", role: .cancel) { ipaAwaitingUpdateChoice = nil }
        } message: {
            Text("Queue this IPA as the update for the installed app?")
        }
        .onAppear {
            guard let initialURL else { return }
            if linkText.isEmpty { linkText = initialURL.absoluteString }
            guard !didStartIncomingImport else { return }
            didStartIncomingImport = true
            Task { await download() }
        }
    }

    @MainActor
    private func download() async {
        isDownloading = true
        downloadProgress = nil
        errorMessage = nil
        defer { isDownloading = false }

        do {
            guard let pastedURL = URL(string: linkText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
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
            let (downloadedURL, response) = try await BuzzheavierClient().download(from: sourceURL) { progress in
                Task { @MainActor in downloadProgress = progress }
            }
            defer { try? FileManager.default.removeItem(at: downloadedURL) }
            if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
                throw AppSharingError.downloadFailed(response.statusCode)
            }

            let app = try await environment.ipaImportStore.prepareIPA(from: downloadedURL, remoteSourceURL: sourceURL)
            let installedApps = await SideStoreOperationService(
                accountStore: SigningAccountStore(),
                ipaStore: environment.ipaImportStore
            ).installedApps()
            let installedIDs = Set(installedApps.flatMap { [$0.bundleIdentifier, $0.resignedBundleIdentifier] }.map { $0.lowercased() })
            if installedIDs.contains(app.bundleIdentifier.lowercased()) {
                ipaAwaitingUpdateChoice = app
            } else {
                try await savePreparedIPA(app, asUpdate: false)
            }
        } catch let error as IPAImportError {
            switch error {
            case .invalidArchive, .missingAppBundle, .missingBundleIdentifier, .notAnIPA:
                errorMessage = "That link returned a web page or a file that isn’t a valid IPA. Use a direct IPA download link."
            case .inaccessibleFile, .sourceFileMissing, .sourceBookmarkUnavailable, .bundleIdentifierMismatch:
                errorMessage = error.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func queuePendingUpdate() async {
        guard let app = ipaAwaitingUpdateChoice else { return }
        ipaAwaitingUpdateChoice = nil
        do { try await savePreparedIPA(app, asUpdate: true) }
        catch { errorMessage = error.localizedDescription }
    }

    @MainActor
    private func savePreparedIPA(_ app: ImportedIPA, asUpdate: Bool) async throws {
        try await environment.ipaImportStore.saveImportedIPA(app)
        importedApp = app
        importedAsUpdate = asUpdate
        await onImported(app)
    }

}
