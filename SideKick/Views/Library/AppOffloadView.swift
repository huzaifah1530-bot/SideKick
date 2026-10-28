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

    private var state: (symbol: String, tone: StatusTone, title: String, message: String) {
        if AppOffloadService.needsLegacyRecovery(app.id) {
            return ("exclamationmark.arrow.circlepath", .warning, "Recovery Needed",
                    "An earlier transfer didn’t finish. Reinstall the original app first. Exported SideKickData folders are kept.")
        }
        if offloaded && !AppOffloadService.blocksNativeOperations(app.id) {
            return ("arrow.clockwise", .warning, "Saved App Needs Recovery",
                    "The app was recorded as inactive after an interrupted installation. Restore its retained app to repair the saved status.")
        }
        if offloaded {
            return ("icloud.and.arrow.down", .accent, "Offloaded",
                    "\(app.name) is backed up and removed from this iPhone. Restore it any time.")
        }
        if AppOffloadService.blocksNativeOperations(app.id) {
            return ("exclamationmark.arrow.circlepath", .warning, "Recovery Needed",
                    "The previous operation didn’t finish. Recover the app before trying again.")
        }
        return ("arrow.down.app", .neutral, "Offload \(app.name)",
                "Backs up the app, then removes it to free an App ID slot. You can restore it later.")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.m) {
                StatusSymbol(systemImage: state.symbol, tone: state.tone)
                Text(state.title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(state.message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if working { ProgressView("Preparing IPA…").padding(.top, Spacing.xs) }
            }
            .frame(maxWidth: SideKickLayout.readableWidth)
            .padding(.horizontal, Spacing.l)
            .padding(.top, Spacing.xxl)
            .frame(maxWidth: .infinity)
        }
        .background(Color.sideKickCanvas)
        .safeAreaInset(edge: .bottom) {
            BottomActionBar {
                if AppOffloadService.needsLegacyRecovery(app.id) {
                    SwiftUI.Button { consoleAction = .restore } label: { ActionLabel("Recover Original App") }
                        .primaryActionStyle()
                } else if offloaded {
                    SwiftUI.Button { consoleAction = .restore } label: { ActionLabel("Restore App", systemImage: "arrow.down.circle") }
                        .primaryActionStyle()
                    SwiftUI.Button("Get IPA for LiveContainer") { prepareIPA() }
                        .font(.body.weight(.semibold))
                        .frame(minHeight: 44)
                } else if AppOffloadService.blocksNativeOperations(app.id) {
                    SwiftUI.Button { consoleAction = .restore } label: { ActionLabel("Recover App") }
                        .primaryActionStyle()
                } else {
                    SwiftUI.Button { confirmOffload = true } label: { ActionLabel("Offload App") }
                        .primaryActionStyle()
                }
            }
        }
        .disabled(working || !loaded)
        .navigationTitle("Offload")
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
        .messageAlert("Couldn’t Continue", message: $errorMessage)
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
        OperationStatusView(title: isRestoring ? "Restore" : "Offload",
            appName: app.name, stageSummary: summary, progress: progress, isRunning: running,
            failure: failure, lines: lines, account: nil, accountStore: nil,
            onRetry: {
                guard !running else { return }
                running = true
                recovering = AppOffloadService.blocksNativeOperations(app.id)
                Task { await run() }
            }, onClose: { onClose(failure == nil) },
            stages: isRestoring ? ["Prepare", "Sign", "Restore", "Done"] : ["Back Up", "Verify", "Remove", "Done"])
        .task {
            guard !started else { return }
            started = true
            await run()
        }
    }

    private var isRestoring: Bool { action == .restore || recovering }

    @MainActor private func run() async {
        running = true; failure = nil; progress = 0; lastPercent = -5
        let id = UUID(); runID = id
        let restoring = action == .restore || recovering
        summary = restoring ? "Restoring \(app.name)" : "Offloading \(app.name)"
        append(restoring ? "Starting native app recovery or restore" : "Starting app offload")
        do {
            let service = AppOffloadService(app: app, accounts: accountStore)
            try await service.perform(restoring: restoring, stageHandler: { message in
                guard running, runID == id else { return }
                append(message)
            }, progressHandler: { value in
                guard running, runID == id else { return }
                progress = min(max(value, 0), 1)
            })
            progress = 1
            summary = restoring ? "\(app.name) is restored" : "\(app.name) is offloaded"
            append(restoring ? "Native app restored" : "App offloaded; native backup kept")
        } catch {
            failure = error.localizedDescription
            summary = restoring ? "Couldn’t restore \(app.name)" : "Couldn’t offload \(app.name)"
            append("ERROR · " + error.localizedDescription)
        }
        running = false
    }

    private func append(_ message: String) {
        lines.append("[\(Date.now.formatted(date: .omitted, time: .standard))] \(message)")
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
    }
}
