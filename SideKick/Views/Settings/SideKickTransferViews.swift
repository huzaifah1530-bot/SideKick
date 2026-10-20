import SwiftUI
import UniformTypeIdentifiers

/// Re-sign → SideKick with an imported certificate from another team.
/// iOS can't upgrade an app across teams, so this installs a second SideKick.
struct SeparateSideKickCopyView: View {
    let account: SigningAccountSummary
    let accountStore: SigningAccountStore
    let certificate: ImportedCertificateRecord
    @Environment(AppEnvironment.self) private var environment
    @State private var copy: ImportedIPA?
    @State private var errorMessage: String?

    private var teamIdentifier: String? { certificate.profile?.teamIdentifier }
    private var removesVPN: Bool {
        SideKickTransferService.includesBuiltInVPN && !SideKickTransferService.profileAllowsVPN(certificate.profile?.uuid)
    }

    var body: some View {
        List {
            Section {
                Text("iOS can’t move an installed app to another signing team, so SideKick installs a second copy signed with “\(certificate.name)”. This copy stays until you delete it.")
                if let teamIdentifier {
                    LabeledContent("New Bundle ID", value: SideKickTransferService.separateCopyBundleIdentifier(teamIdentifier: teamIdentifier))
                }
            } footer: {
                Text("Next, open Settings → Advanced → Move to Another SideKick here to export your data, then import it in the new copy.")
            }

            if removesVPN {
                Section {
                    Label("The new copy won’t include SideKick’s built-in VPN. This certificate’s profile doesn’t allow VPN extensions. Install LocalDevVPN from the App Store and use it for the local connection.", systemImage: "network.slash")
                }
            }

            Section {
                if let copy {
                    NavigationLink {
                        InstallConsoleView(app: copy, account: account, accountStore: accountStore,
                            ipaStore: environment.ipaImportStore, isUpdate: false,
                            onInstalled: { try? await environment.ipaImportStore.delete(copy) })
                    } label: {
                        Label("Install New SideKick", systemImage: "square.on.square")
                    }
                } else if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                } else {
                    HStack(spacing: Spacing.s) {
                        ProgressView()
                        Text("Preparing SideKick…")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Install Second Copy")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard copy == nil else { return }
            guard let teamIdentifier else {
                errorMessage = ImportedCertificateError.profileRequired(certificateName: certificate.name).localizedDescription
                return
            }
            do {
                copy = try await SideKickTransferService.prepareSeparateCopy(teamIdentifier: teamIdentifier,
                    removeVPN: removesVPN, store: environment.ipaImportStore)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Settings → Advanced → Move to Another SideKick.
struct SideKickTransferView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var isPickingExportFolder = false
    @State private var isPickingImportFolder = false
    @State private var status: String?
    @State private var isWorking = false
    @State private var exportedFolderName: String?
    @State private var importResult: SideKickTransferImportResult?
    @State private var isConfirmingDelete = false
    @State private var deletedOldCopy = false
    @State private var errorMessage: String?
    @State private var includesCertificates = true
    @State private var exportPassword = ""
    @State private var pendingImportFolder: URL?
    @State private var importPassword = ""
    @State private var isAskingImportPassword = false

    var body: some View {
        List {
            Section {
                Toggle("Include Apple Certificates", isOn: $includesCertificates)
                if includesCertificates {
                    SecureField("Password for the certificates", text: $exportPassword)
                        .textContentType(.newPassword)
                }
                SwiftUI.Button { isPickingExportFolder = true } label: {
                    Label("Export Data…", systemImage: "square.and.arrow.up")
                }
                .disabled(isWorking || (includesCertificates && exportPassword.count < 6))
                if let exportedFolderName {
                    Label("Saved “\(exportedFolderName)”", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            } header: {
                Text("From This SideKick")
            } footer: {
                Text("Choose a folder in Files. SideKick saves your apps, imported IPAs, GitHub update sources and appearance there. With Apple certificates included, the new copy reuses them instead of making new ones, which could stop apps signed by this copy from opening. They’re locked with your password (6+ characters). Apple sign-ins and GitHub tokens stay behind.")
            }

            Section {
                SwiftUI.Button { isPickingImportFolder = true } label: {
                    Label("Import Data…", systemImage: "square.and.arrow.down")
                }
                .disabled(isWorking)
            } header: {
                Text("Into This SideKick")
            } footer: {
                Text("Choose the “SideKick Transfer” folder. Apps appear in your library ready to install, with their GitHub updates attached, so nothing downloads again.")
            }

            if isWorking, let status {
                Section {
                    HStack(spacing: Spacing.s) {
                        ProgressView()
                        Text(status)
                    }
                }
            }

            if let importResult {
                Section("Imported") {
                    LabeledContent("Apps", value: "\(importResult.importedApps.count)")
                    LabeledContent("Library IPAs", value: "\(importResult.importedLibraryIPAs)")
                    if importResult.restoredSources > 0 {
                        LabeledContent("LiveContainer Sources", value: "\(importResult.restoredSources)")
                    }
                    if importResult.restoredCertificates > 0 {
                        LabeledContent("Apple Certificates", value: "\(importResult.restoredCertificates)")
                    }
                    if importResult.certificatesNeedPassword {
                        Text("Apple certificates were skipped because no password was entered. Import again to add them.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if !importResult.skipped.isEmpty {
                        // Keep the full reasons available without crowding the summary.
                        DisclosureGroup("Skipped (\(importResult.skipped.count))") {
                            ForEach(importResult.skipped, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
                        }
                    }
                }

                if !importResult.appsWithoutData.isEmpty {
                    Section {
                        ForEach(importResult.appsWithoutData, id: \.self) { Text($0) }
                    } header: {
                        Text("Install as New Copies")
                    } footer: {
                        Text("These were signed with your Apple account, so iOS keeps them separate from copies signed here. Installing creates a new app with empty data; the original keeps its data until you delete it.")
                    }
                }

                Section {
                    if deletedOldCopy {
                        Label("Old SideKick deleted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        SwiftUI.Button("Delete Old SideKick", role: .destructive) { isConfirmingDelete = true }
                            .disabled(isWorking)
                    }
                } footer: {
                    Text("Until you delete the old copy, both send expiry reminders and links like sidekick:// may open either one. Install your apps from the library first if you’d like to compare.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Move to Another SideKick")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $isPickingExportFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let parent) = result else { return }
            Task { await export(to: parent) }
        }
        .fileImporter(isPresented: $isPickingImportFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let folder) = result else { return }
            if SideKickTransferService.transferHasCertificates(folder) {
                pendingImportFolder = folder
                importPassword = ""
                isAskingImportPassword = true
            } else {
                Task { await importData(from: folder, password: nil) }
            }
        }
        .alert("Certificate Password", isPresented: $isAskingImportPassword) {
            SecureField("Password", text: $importPassword)
            SwiftUI.Button("Skip Certificates", role: .cancel) {
                if let folder = pendingImportFolder { Task { await importData(from: folder, password: nil) } }
            }
            SwiftUI.Button("Import") {
                if let folder = pendingImportFolder { Task { await importData(from: folder, password: importPassword) } }
            }
        } message: {
            Text("Enter the password you chose when exporting, so this copy can reuse your Apple certificates.")
        }
        .confirmationDialog("Delete the old SideKick?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            SwiftUI.Button("Delete Old SideKick", role: .destructive) { Task { await deleteOldCopy() } }
            SwiftUI.Button("Cancel", role: .cancel) { }
        } message: {
            Text(deleteMessage)
        }
        .alert("Move to Another SideKick", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            SwiftUI.Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var deleteMessage: String {
        var text = "Its data, sign-ins and certificates are removed from this iPhone. This can’t be undone."
        if let offloaded = importResult?.offloadedApps, !offloaded.isEmpty {
            text += " Offloaded apps can’t be restored afterward: \(offloaded.joined(separator: ", "))."
        }
        text += " Keep another way to sideload in case this copy’s certificate is revoked."
        return text
    }

    @MainActor private func export(to parent: URL) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let folder = try await SideKickTransferService.export(to: parent, ipaStore: environment.ipaImportStore,
                certificatePassword: includesCertificates ? exportPassword : nil) { status = $0 }
            exportedFolderName = folder.lastPathComponent
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor private func importData(from folder: URL, password: String?) async {
        isWorking = true
        defer { isWorking = false }
        do {
            importResult = try await SideKickTransferService.importTransfer(from: folder, ipaStore: environment.ipaImportStore,
                certificatePassword: password) { status = $0 }
            await environment.gitHubSettingsChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor private func deleteOldCopy() async {
        guard let source = importResult?.sourceBundleIdentifier else { return }
        isWorking = true
        status = "Deleting old SideKick"
        defer { isWorking = false }
        do {
            try await SideKickTransferService.deleteOldCopy(bundleIdentifier: source)
            deletedOldCopy = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
