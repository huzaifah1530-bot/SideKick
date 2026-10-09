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
                Text("SideKick uploads this IPA to Buzzheavier and creates a link that opens in SideKick. Anyone who gets the link can download the file.")
                Text("Buzzheavier’s free uploads are temporary and may expire. SideKick can’t delete an anonymous upload after it’s created.")
                Text("The SideKick link conceals the provider URL for convenience; it is not encryption or access control.")
                    .foregroundStyle(.secondary)
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
    @State private var errorMessage: String?
    @State private var importedApp: ImportedIPA?

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
                    HStack {
                        ProgressView()
                        Text("Downloading and checking IPA…")
                    }
                } else if let importedApp {
                    Label("\(importedApp.name) is ready to install", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    NavigationLink {
                        AppManagementView(importedApp: importedApp)
                    } label: {
                        Label("Review \(importedApp.name)", systemImage: "app")
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
                Text("Only download apps you trust. Downloaded IPAs are saved in SideKick before you choose whether to install them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Import from URL")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let initialURL, linkText.isEmpty { linkText = initialURL.absoluteString }
        }
    }

    @MainActor
    private func download() async {
        isDownloading = true
        errorMessage = nil
        defer { isDownloading = false }

        do {
            guard let pastedURL = URL(string: linkText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw AppSharingError.invalidShareLink
            }
            let resolvedURL: URL
            if pastedURL.scheme?.lowercased() == "sidekick" {
                guard let sharedURL = SideKickShareLink.downloadURL(from: pastedURL) else {
                    throw AppSharingError.invalidShareLink
                }
                resolvedURL = sharedURL
            } else {
                guard pastedURL.scheme?.lowercased() == "https" else {
                    throw AppSharingError.insecureURL
                }
                resolvedURL = buzzheavierDirectURL(for: pastedURL)
            }
            let (downloadedURL, response) = try await URLSession.shared.download(from: resolvedURL)
            if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
                throw AppSharingError.downloadFailed(response.statusCode)
            }

            let ipaURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("ipa")
            defer { try? FileManager.default.removeItem(at: ipaURL) }
            try FileManager.default.copyItem(at: downloadedURL, to: ipaURL)
            let app = try await environment.ipaImportStore.importIPA(from: ipaURL)
            importedApp = app
            await onImported(app)
        } catch let error as IPAImportError {
            switch error {
            case .invalidArchive, .missingAppBundle, .missingBundleIdentifier, .notAnIPA:
                errorMessage = "That link returned a web page or a file that isn’t a valid IPA. Use a direct IPA download link."
            case .inaccessibleFile:
                errorMessage = error.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func buzzheavierDirectURL(for url: URL) -> URL {
        guard
            let host = url.host?.lowercased(),
            host == "buzzheavier.com" || host == "www.buzzheavier.com",
            !url.path.hasPrefix("/d/"),
            url.pathComponents.count == 2
        else { return url }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = "/d\(url.path)"
        return components?.url ?? url
    }
}
