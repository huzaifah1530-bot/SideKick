import SwiftUI

struct AppOffloadView: View {
    let app: InstalledAppSummary
    let accountStore: SigningAccountStore
    @Environment(AppEnvironment.self) private var environment
    @State private var offloaded = false
    @State private var working = false
    @State private var loaded = false
    @State private var errorMessage: String?
    @State private var confirmOffload = false
    @State private var offerLiveContainer = false
    @State private var ipa: ImportedIPA?
    private var service: AppOffloadService { AppOffloadService(app: app, accounts: accountStore) }

    var body: some View {
        Form {
            Section {
                Text(app.name).font(.headline)
                if working { ProgressView("Follow the prompts in the app…") }
                if AppOffloadService.needsLegacyRecovery(app.id) {
                    Text("An earlier transfer needs recovery. Reinstall the original app first. Any exported SideKickData folders are kept; this action does not import their files.")
                    SwiftUI.Button("Recover Original App") { run(restoring: true) }
                } else if offloaded {
                    Label("App offloaded", systemImage: "checkmark.circle")
                    Text("Its SideStore backup is kept for restoring the native app.")
                    SwiftUI.Button("Restore App") { run(restoring: true) }
                    SwiftUI.Button("Get IPA for LiveContainer") { prepareIPA() }
                } else if AppOffloadService.blocksNativeOperations(app.id) {
                    Text("The previous operation did not finish. Recover the native app before trying again.")
                    SwiftUI.Button("Recover App") { run(restoring: true) }
                } else {
                    Text("Back up this app and remove its native installation to free an app slot. You can restore it later.")
                    SwiftUI.Button("Offload App", role: .destructive) { confirmOffload = true }
                }
            }
        }
        .disabled(working || !loaded)
        .navigationTitle("Offload App")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(working)
        .interactiveDismissDisabled(working)
        .task {
            do { offloaded = try await service.isOffloaded(); loaded = true }
            catch { errorMessage = error.localizedDescription; loaded = true }
        }
        .confirmationDialog("Offload \(app.name)?", isPresented: $confirmOffload, titleVisibility: .visible) {
            SwiftUI.Button("Back Up and Offload", role: .destructive) { run(restoring: false) }
            SwiftUI.Button("Cancel", role: .cancel) { }
        } message: { Text("Keep LocalDevVPN connected. SideStore will back up the app before removing it.") }
        .confirmationDialog("App offloaded. Get its IPA for LiveContainer?", isPresented: $offerLiveContainer, titleVisibility: .visible) {
            SwiftUI.Button("Get IPA for LiveContainer") { prepareIPA() }
            SwiftUI.Button("Not Now", role: .cancel) { }
        } message: { Text("You can open or save the IPA. This is a separate LiveContainer installation; its data is not migrated. The native backup is kept.") }
        .navigationDestination(item: $ipa) { LiveContainerImportView(app: $0, opensOnArrival: true) }
        .alert("App action failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            SwiftUI.Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func run(restoring: Bool) {
        guard !working else { return }
        working = true
        Task { @MainActor in
            defer { working = false }
            do {
                try await service.perform(restoring: restoring)
                offloaded = try await service.isOffloaded()
                await environment.reloadLocalCatalogues()
                if !restoring && offloaded { offerLiveContainer = true }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func prepareIPA() {
        guard !working else { return }
        working = true
        Task { @MainActor in
            defer { working = false }
            do { ipa = try await service.prepareIPA(store: environment.ipaImportStore) }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
