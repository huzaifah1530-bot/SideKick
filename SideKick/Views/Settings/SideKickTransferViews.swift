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
                    store: environment.ipaImportStore)
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

    var body: some View {
        List {
            Section {
                SwiftUI.Button { isPickingExportFolder = true } label: {
                    Label("Export Data…", systemImage: "square.and.arrow.up")
                }
                .disabled(isWorking)
                if let exportedFolderName {
                    Label("Saved “\(exportedFolderName)”", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            } header: {
                Text("From This SideKick")
            } footer: {
                Text("Choose a folder in Files. SideKick saves your apps, imported IPAs, GitHub update sources and appearance there. Apple sign-ins, GitHub tokens and certificates stay behind; add them again in the new copy.")
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
                    if !importResult.skipped.isEmpty {
                        DisclosureGroup("Skipped (\(importResult.skipped.count))") {
                            ForEach(importResult.skipped, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
                        }
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
                    Text("Install your apps from the library first if you’d like to compare. Apps the old copy installed keep working until they expire.")
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
            Task { await importData(from: folder) }
        }
        .confirmationDialog("Delete the old SideKick?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            SwiftUI.Button("Delete Old SideKick", role: .destructive) { Task { await deleteOldCopy() } }
            SwiftUI.Button("Cancel", role: .cancel) { }
        } message: {
            Text("Its data, sign-ins and certificates are removed from this iPhone. This can’t be undone.")
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

    @MainActor private func export(to parent: URL) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let folder = try await SideKickTransferService.export(to: parent, ipaStore: environment.ipaImportStore) { status = $0 }
            exportedFolderName = folder.lastPathComponent
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor private func importData(from folder: URL) async {
        isWorking = true
        defer { isWorking = false }
        do {
            importResult = try await SideKickTransferService.importTransfer(from: folder, ipaStore: environment.ipaImportStore) { status = $0 }
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
