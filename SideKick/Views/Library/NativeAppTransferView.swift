import SwiftUI
import UniformTypeIdentifiers
import UIKit

enum NativeTransferPage: Int {
    case prepare = 1, export, attach, verify, finish, restore

    static func resume(state: String, hasFolder: Bool, verified: Bool) -> Self {
        switch state {
        case "offloaded": return .finish
        case "recoveryNeeded", "exporting", "offloading", "restoring": return .restore
        case "exported": return hasFolder ? (verified ? .finish : .verify) : .attach
        default: return .prepare
        }
    }

    var title: String {
        switch self {
        case .prepare: "Import the app"
        case .export: "Export your data"
        case .attach: "Select your data folder"
        case .verify: "Test in LiveContainer"
        case .finish: "Finish the move"
        case .restore: "Restore or recover"
        }
    }
}

struct NativeAppTransferView: View {
    let app: InstalledAppSummary
    let accountStore: SigningAccountStore
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var record = NativeTransferRecord()
    @State private var page = NativeTransferPage.prepare
    @State private var hasLoaded = false
    @State private var isWorking = false
    @State private var progressTitle = ""
    @State private var errorMessage: String?
    @State private var message: String?
    @State private var showFolderPicker = false
    @State private var showShare = false
    @State private var confirmOffload = false
    @State private var confirmRestore = false
    @State private var guestIPA: URL?

    private var service: NativeAppTransferService { NativeAppTransferService(app: app, accounts: accountStore) }

    var body: some View {
        Form {
            Section {
                Text(app.name).font(.headline)
                if page != .restore {
                    Text("Step \(page.rawValue) of 5").font(.subheadline).foregroundStyle(.secondary)
                }
                Text(page.title).font(.title2.bold())
                if isWorking { ProgressView(progressTitle) }
                if let message { Text(message).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            pageContent
        }
        .disabled(isWorking)
        .navigationTitle("Move to LiveContainer")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isWorking)
        .interactiveDismissDisabled(isWorking)
        .toolbar {
            if !isWorking, let previousPage {
                ToolbarItem(placement: .topBarTrailing) {
                    SwiftUI.Button("Previous Step") { go(previousPage) }
                }
            }
        }
        .onAppear {
            guard !hasLoaded else { return }
            hasLoaded = true
            record = service.record
            page = .resume(state: record.state, hasFolder: record.dataBookmark != nil, verified: record.guestVerified)
        }
        .sheet(isPresented: $showShare) {
            if let guestIPA { LiveContainerIPAActivity(url: guestIPA) }
        }
        .alert("Transfer could not finish", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            SwiftUI.Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "Please try again.") }
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                work("Checking app data…", stage: .appDataTransfer) {
                    try await service.retainDataFolder(url)
                    record = service.record
                    go(.verify)
                }
            case .failure(let error):
                if !(error is CancellationError) { errorMessage = error.localizedDescription }
            }
        }
        .confirmationDialog("Back up and remove the native app?", isPresented: $confirmOffload, titleVisibility: .visible) {
            SwiftUI.Button("Back Up and Free Native Slot", role: .destructive) { run(.offload) }
        } message: {
            Text("Choose a separate backup destination. Keep the folder used by LiveContainer unchanged. SideKick retains the original app for restoration.")
        }
        .confirmationDialog("Replace native files with the guest’s latest files?", isPresented: $confirmRestore, titleVisibility: .visible) {
            SwiftUI.Button("Restore Guest Files") { run(.restore) }
        } message: {
            Text("Close every instance of this guest first. Files deleted in the guest will also be absent after restoration. Keychain credentials are not copied.")
        }
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .prepare:
            Section {
                Text("Create a copy of this app, then import it into LiveContainer. Your installed app stays in place.")
                if guestIPA == nil {
                    SwiftUI.Button("Create LiveContainer IPA") {
                        work("Creating IPA…", stage: .guestIPA) {
                            guestIPA = try await service.prepareGuestIPA()
                            showShare = true
                        }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    SwiftUI.Button("Open or Save IPA") { showShare = true }
                    Text("In the share sheet, open the IPA in LiveContainer, or save it to Files and import it there.")
                    SwiftUI.Button("I’ve Imported the App — Continue") { go(.export) }
                        .buttonStyle(.borderedProminent)
                }
            }
            Section {
                Text("The next steps transfer Documents, Library and App Group files. Keychain logins aren’t copied, and native widgets/extensions may not work in LiveContainer.")
                    .font(.footnote).foregroundStyle(.secondary)
                SwiftUI.Button("Restore or Recover an Earlier Transfer") { go(.restore) }
            }
        case .export:
            Section {
                Text("Keep LocalDevVPN connected. SideKick will temporarily replace the native app with a file-transfer helper.")
                Text("Close related apps that share this app’s data before continuing.")
                Text("When asked, open the target app and choose a local folder outside its own folder. The helper creates a SideKickData folder, then SideKick reinstalls the original app.")
                SwiftUI.Button("Export Native App Files") { run(.export) }
                    .buttonStyle(.borderedProminent)
                Text("Keep the exported folder as a recovery copy.").font(.footnote).foregroundStyle(.secondary)
            }
        case .attach:
            Section {
                Text("Choose the SideKickData folder just created by the helper. Select that folder itself, rather than its parent or Documents subfolder.")
                SwiftUI.Button("Select SideKickData Folder") { showFolderPicker = true }
                    .buttonStyle(.borderedProminent)
                Text("SideKick checks that the folder belongs to this app and version.").font(.footnote).foregroundStyle(.secondary)
            }
        case .verify:
            Section {
                Text("In LiveContainer, open this app’s settings. Add the same SideKickData folder as external data storage and make it the active/default container.")
                Text("For this container, turn on Isolate App Group. Shared files are included in the folder and need that setting to be used. Keep it on while using this transfer.")
                Text("Launch the app there and check your saves and settings. Return here once they work.")
                Toggle("My saves and settings work", isOn: Binding(
                    get: { record.guestVerified },
                    set: { value in
                        record.guestVerified = value
                        service.record = record
                    }
                ))
                .disabled(record.dataBookmark == nil)
                SwiftUI.Button("Continue") { go(.finish) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!record.guestVerified || record.dataBookmark == nil)
            }
        case .finish:
            Section {
                if record.state == "offloaded" {
                    Label("Native app slot freed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Keep your guest data folder and backup. Open the app through LiveContainer.")
                    SwiftUI.Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
                } else {
                    Text("You can now free the native app slot. SideKick makes another backup before removing the native installation.")
                    Text("Choose a different backup destination so the data folder used by LiveContainer stays unchanged.")
                    SwiftUI.Button("Free Native App Slot", role: .destructive) { confirmOffload = true }
                        .disabled(!record.guestVerified || record.dataBookmark == nil)
                    SwiftUI.Button("Keep Both for Now") { dismiss() }
                }
                SwiftUI.Button("Restore or Recover Native App") { go(.restore) }
            }
        case .restore:
            Section {
                Text("To bring your data back, close the app in LiveContainer first. Keep it on version \(app.version) (\(app.buildVersion)).")
                Text("Close related native apps too. The helper asks for the current SideKickData folder, restores its app and App Group files, then reinstalls the native app. Keep that folder until you verify the result.")
                SwiftUI.Button("Restore Latest Guest Files") { confirmRestore = true }
                    .buttonStyle(.borderedProminent)
            }
            Section("If a transfer was interrupted") {
                Text("If the helper was left installed, recover the original app first. This reinstalls its binary without importing guest files.")
                SwiftUI.Button("Recover Original App Binary") { run(.recover) }
            }
        }
    }

    private var previousPage: NativeTransferPage? {
        switch page {
        case .prepare: nil
        case .export: .prepare
        case .attach: .export
        case .verify: .attach
        case .finish: record.state == "offloaded" ? nil : .verify
        case .restore: NativeTransferPage.resume(state: record.state, hasFolder: record.dataBookmark != nil, verified: record.guestVerified) == .restore ? nil : .prepare
        }
    }

    private func go(_ next: NativeTransferPage) {
        message = nil
        page = next
    }

    private func run(_ action: NativeTransferAction) {
        work("Follow the helper in the target app…", stage: .appDataTransfer) {
            try await service.perform(action)
            record = service.record
            await environment.reloadLocalCatalogues()
            switch action {
            case .export: go(.attach)
            case .offload: go(.finish)
            case .restore, .recover:
                message = "Native app reinstalled. Open it and check its data before deleting any exported files."
            }
        }
    }

    private func work(_ title: String, stage: DiagnosticsStore.Stage,
                      operation: @escaping @MainActor () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        progressTitle = title
        message = nil
        Task { @MainActor in
            defer { isWorking = false; record = service.record }
            do { try await DiagnosticsStore.perform(.transfer, stage: stage, body: operation) }
            catch {
                if service.record.state == "recoveryNeeded" { page = .restore }
                errorMessage = error.localizedDescription
            }
        }
    }
}
