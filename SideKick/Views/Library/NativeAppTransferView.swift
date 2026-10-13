import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct NativeAppTransferView: View {
    let app: InstalledAppSummary
    let accountStore: SigningAccountStore
    @Environment(AppEnvironment.self) private var environment
    @State private var record = NativeTransferRecord()
    @State private var isWorking = false
    @State private var message: String?
    @State private var showFolderPicker = false
    @State private var confirmOffload = false
    @State private var confirmRestore = false
    @State private var guestIPA: URL?

    private var service: NativeAppTransferService { NativeAppTransferService(app: app, accounts: accountStore) }

    var body: some View {
        Form {
            Section {
                Text("Run this app in stock LiveContainer, then bring its files back to the installed app.")
                Text("Transfers Documents and Library, including settings and saves. Keychain logins and App Groups are not transferred. Apps needing native extensions may not work in LiveContainer.")
                    .font(.footnote).foregroundStyle(.secondary)
                LabeledContent("Version to keep", value: "\(app.version) (\(app.buildVersion))")
                LabeledContent("Transfer state", value: stateLabel)
            }

            Section("1. Prepare the guest") {
                SwiftUI.Button("Create LiveContainer IPA") {
                    work {
                        guestIPA = try await service.prepareGuestIPA()
                    }
                }
                if let guestIPA {
                    ShareLink(item: guestIPA) {
                        Label("Save or Open IPA in LiveContainer", systemImage: "square.and.arrow.up")
                    }
                }
                Text("Use this IPA so the guest keeps the native settings identity. LiveContainer patches its own copy; SideKick retains the original for restoration.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("2. Export and attach app data") {
                SwiftUI.Button("Export Native App Files") { run(.export) }
                Text("A helper temporarily replaces this app. In its Files picker, choose a local destination outside the app’s own folder. It creates a new SideKickData folder, then reinstalls the original app. Keep the folder as a recovery copy.")
                    .font(.footnote).foregroundStyle(.secondary)
                SwiftUI.Button("Select Exported SideKickData Folder") { showFolderPicker = true }
                Text("In LiveContainer, open the guest’s settings and add that same folder as external data storage. Select it as the active/default container. Launch the guest and verify your saves and settings.")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("I verified this guest with my data", isOn: Binding(
                    get: { record.guestVerified },
                    set: { value in
                        record.guestVerified = value
                        service.record = record
                    }
                ))
                .disabled(record.dataBookmark == nil)
            }

            Section("3. Free the native app slot") {
                SwiftUI.Button("Move to LiveContainer", role: .destructive) { confirmOffload = true }
                    .disabled(!record.guestVerified || record.dataBookmark == nil || record.state == "offloaded")
                Text("Only continue after testing the guest. SideKick makes another native backup through Files before removing the native app. Choose a separate backup destination; keep the existing guest folder unchanged.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Restore as an installed app") {
                SwiftUI.Button("Restore Latest Guest Files") { confirmRestore = true }
                Text("Fully close the guest and return to LiveContainer’s app list so preferences are saved. Keep the guest on the version shown above. The helper asks you to select its current SideKickData folder, restores those files, then reinstalls the native app. Keep the guest folder until you verify the restored app.")
                    .font(.footnote).foregroundStyle(.secondary)
                SwiftUI.Button("Recover Original App Binary") { run(.recover) }
                Text("Use recovery if a failed or cancelled transfer left the helper installed. It reinstalls the original app without importing data. Previously exported Files folders are kept.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if isWorking {
                Section { ProgressView("Follow the transfer helper in the target app…") }
            }
            if let message { Section { Text(message).textSelection(.enabled) } }
        }
        .disabled(isWorking)
        .navigationTitle("Move to LiveContainer")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { record = service.record }
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
            do {
                try service.retainDataFolder(result.get())
                record = service.record
                message = "Data folder linked. Attach this same folder to the guest in LiveContainer."
            } catch { message = error.localizedDescription }
        }
        .confirmationDialog("Remove the native app after backing up?", isPresented: $confirmOffload, titleVisibility: .visible) {
            SwiftUI.Button("Back Up and Free Native Slot", role: .destructive) { run(.offload) }
        } message: {
            Text("Make sure the guest works with your data. This removes the native installation after a new backup. SideKick retains its source and record for restoration.")
        }
        .confirmationDialog("Replace native files with the guest’s latest files?", isPresented: $confirmRestore, titleVisibility: .visible) {
            SwiftUI.Button("Restore Guest Files") { run(.restore) }
        } message: {
            Text("Close every instance of this guest first. Files deleted in the guest will also be absent after restoration. Keychain credentials are not copied.")
        }
    }

    private var stateLabel: String {
        switch record.state {
        case "exported": "Files exported"
        case "offloaded": "Running in LiveContainer"
        case "restored": "Native app restored"
        case "binaryRecovered": "Native binary recovered; guest files not imported"
        case "recoveryNeeded": "Recovery needed"
        case "exporting", "offloading", "restoring": "Interrupted or in progress"
        default: "Not started"
        }
    }

    private func run(_ action: NativeTransferAction) {
        work {
            try await service.perform(action)
            record = service.record
            await environment.reloadLocalCatalogues()
            message = action == .offload
                ? "Native slot released. Keep the guest data folder and backup."
                : action == .export
                    ? "Files exported and native app reinstalled. Select the exported SideKickData folder next."
                    : "Native app reinstalled. Open it to verify its data before deleting any guest files."
        }
    }

    private func work(_ operation: @escaping @MainActor () async throws -> Void) {
        isWorking = true
        message = nil
        Task { @MainActor in
            defer { isWorking = false; record = service.record }
            do { try await operation() }
            catch { message = error.localizedDescription }
        }
    }
}
