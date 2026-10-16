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
    @State private var consoleAction: AppOffloadAction?
    private var service: AppOffloadService { AppOffloadService(app: app, accounts: accountStore) }

    var body: some View {
        Form {
            Section {
                Text(app.name).font(.headline)
                if working { ProgressView("Preparing IPA…") }
                if AppOffloadService.needsLegacyRecovery(app.id) {
                    Text("An earlier transfer needs recovery. Reinstall the original app first. Any exported SideKickData folders are kept; this action does not import their files.")
                    SwiftUI.Button("Recover Original App") { consoleAction = .restore }
                } else if offloaded {
                    Label("App offloaded", systemImage: "checkmark.circle")
                    Text("Its native backup is kept for restoring the app.")
                    SwiftUI.Button("Restore App") { consoleAction = .restore }
                    SwiftUI.Button("Get IPA for LiveContainer") { prepareIPA() }
                } else if AppOffloadService.blocksNativeOperations(app.id) {
                    Text("The previous operation did not finish. Recover the native app before trying again.")
                    SwiftUI.Button("Recover App") { consoleAction = .restore }
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
            SwiftUI.Button("Back Up and Offload", role: .destructive) { consoleAction = .offload }
            SwiftUI.Button("Cancel", role: .cancel) { }
        } message: { Text("Keep LocalDevVPN connected. SideKick will back up the app before removing it.") }
        .confirmationDialog("App offloaded. Get its IPA for LiveContainer?", isPresented: $offerLiveContainer, titleVisibility: .visible) {
            SwiftUI.Button("Get IPA for LiveContainer") { prepareIPA() }
            SwiftUI.Button("Not Now", role: .cancel) { }
        } message: { Text("You can open or save the IPA. This is a separate LiveContainer installation; its data is not migrated. The native backup is kept.") }
        .navigationDestination(item: $ipa) { LiveContainerImportView(app: $0, opensOnArrival: true) }
        .navigationDestination(item: $consoleAction) { action in
            AppOffloadConsoleView(app: app, accountStore: accountStore, action: action) { succeeded in
                consoleAction = nil
                Task { @MainActor in
                    do {
                        offloaded = try await service.isOffloaded()
                        await environment.reloadLocalCatalogues()
                        if succeeded && offloaded { offerLiveContainer = true }
                    } catch { errorMessage = error.localizedDescription }
                }
            }
        }
        .alert("App action failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            SwiftUI.Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
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

enum AppOffloadAction: String, Identifiable {
    case offload, restore
    var id: String { rawValue }
}

private struct AppOffloadConsoleView: View {
    let app: InstalledAppSummary
    let accountStore: SigningAccountStore
    let action: AppOffloadAction
    let onClose: (Bool) -> Void
    @State private var running = true
    @State private var started = false
    @State private var recovering = false
    @State private var progress = 0.0
    @State private var summary = "Preparing your app"
    @State private var lines: [String] = []
    @State private var failure: String?
    @State private var runID = UUID()
    @State private var lastPercent = -5

    var body: some View {
        OperationStatusView(title: action == .restore || recovering ? "Restore Status" : "Offload Status",
            appName: app.name, stageSummary: summary, progress: progress, isRunning: running,
            failure: failure, lines: lines, account: nil, accountStore: nil,
            onRetry: {
                guard !running else { return }
                running = true
                recovering = AppOffloadService.blocksNativeOperations(app.id)
                Task { await run() }
            }, onClose: { onClose(failure == nil) }, expandActivityInitially: true)
        .task {
            guard !started else { return }
            started = true
            await run()
        }
    }

    @MainActor private func run() async {
        running = true; failure = nil; progress = 0; lastPercent = -5
        let id = UUID(); runID = id
        let restoring = action == .restore || recovering
        append(restoring ? "Starting native app recovery or restore" : "Starting app offload")
        do {
            let service = AppOffloadService(app: app, accounts: accountStore)
            try await service.perform(restoring: restoring, stageHandler: { message in
                guard running, runID == id else { return }
                summary = message; append(message)
            }, progressHandler: { value in
                guard running, runID == id else { return }
                progress = min(max(value, 0), 1)
                let percent = Int(progress * 100)
                if percent >= lastPercent + 5 {
                    lastPercent = percent; append("Pipeline progress · \(percent)%")
                }
            })
            progress = 1
            summary = restoring ? "Native app restored." : "App offloaded. Its native backup is kept."
            append(summary)
        } catch {
            failure = error.localizedDescription
            summary = "SideKick couldn’t finish this operation."
            append("ERROR · " + error.localizedDescription)
        }
        running = false
    }

    private func append(_ message: String) {
        lines.append("[\(Date.now.formatted(date: .omitted, time: .standard))] \(message)")
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
    }
}
