import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct AppManagementView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var expirationClock = Date.now
    @State private var accountStore = SigningAccountStore()
    @State private var isShowingRefreshConsole = false
    @State private var isFindingShareIPA = false
    @State private var shareIPA: ImportedIPA?
    @State private var pendingUpdateIPA: ImportedIPA?
    @State private var errorMessage: String?
    @State private var isConfirmingQueuedUpdateRemoval = false
    @State private var isResolvingQueuedTarget: Bool
    @State private var isQueuedTargetUnavailable = false
    @State private var queuedTargetLoadError: String?
    @State private var isResolvingQueuedIPA = false
    @State private var queuedIPAReadError: String?

    private let importedApp: ImportedIPA?
    private let requiredQueuedIPA: ImportedIPA?
    @State private var installedApp: InstalledAppSummary?
    private let onDelete: (() async -> Void)?

    init(importedApp: ImportedIPA, onDelete: (() async -> Void)? = nil) {
        self.importedApp = importedApp
        self.requiredQueuedIPA = nil
        _installedApp = State(initialValue: nil)
        _isResolvingQueuedTarget = State(initialValue: false)
        _isResolvingQueuedIPA = State(initialValue: false)
        self.onDelete = onDelete
    }

    init(installedApp: InstalledAppSummary) {
        self.importedApp = nil
        self.requiredQueuedIPA = nil
        _installedApp = State(initialValue: installedApp)
        _isResolvingQueuedTarget = State(initialValue: false)
        _isResolvingQueuedIPA = State(initialValue: true)
        self.onDelete = nil
    }

    init(queuedUpdate: ImportedIPA) {
        self.importedApp = nil
        self.requiredQueuedIPA = queuedUpdate
        _installedApp = State(initialValue: nil)
        _isResolvingQueuedTarget = State(initialValue: true)
        _isResolvingQueuedIPA = State(initialValue: true)
        self.onDelete = nil
    }

    private var appName: String { importedApp?.name ?? installedApp?.name ?? requiredQueuedIPA?.name ?? "App" }
    private var bundleIdentifier: String { importedApp?.bundleIdentifier ?? installedApp?.bundleIdentifier ?? requiredQueuedIPA?.bundleIdentifier ?? "" }
    private var isQueueStateUnresolved: Bool {
        isResolvingQueuedIPA || queuedIPAReadError != nil ||
            (requiredQueuedIPA != nil && (isResolvingQueuedTarget || queuedTargetLoadError != nil))
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    appIcon
                        .frame(width: 76, height: 76)
                        .clipShape(.rect(cornerRadius: 17))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(appName)
                            .font(.title3.weight(.bold))
                        Text(importedApp.map { "Version \($0.version)" } ?? installedApp.map { "Version \($0.version)" } ?? requiredQueuedIPA.map { "Version \($0.version)" } ?? "Installed")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
            }

            if requiredQueuedIPA != nil && isResolvingQueuedTarget {
                Section("Queued Update") {
                    ProgressView("Finding the installed app this update targets…")
                }
            } else if requiredQueuedIPA != nil, let queuedTargetLoadError {
                Section("Queued Update") {
                    Text("SideKick couldn’t check which installed app this update targets. The queued IPA was kept.")
                        .foregroundStyle(.secondary)
                    Text(queuedTargetLoadError)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    SwiftUI.Button("Retry") { retryQueuedTargetResolution() }
                }
            } else if let queuedIPAReadError {
                Section("Queued Update") {
                    Text("SideKick couldn’t check whether an update is still queued. The last known state is preserved, and update actions are disabled until the library can be checked.")
                        .foregroundStyle(.secondary)
                    Text(queuedIPAReadError)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    SwiftUI.Button("Retry") { retryQueuedTargetResolution() }
                }
            } else if isResolvingQueuedIPA {
                Section("Queued Update") {
                    ProgressView("Checking saved IPA queue…")
                }
            } else if let requiredQueuedIPA, isQueuedTargetUnavailable {
                Section("Queued Update") {
                    Text(pendingUpdateIPA == nil
                         ? "The installed app this IPA targeted is no longer available, and the IPA is no longer queued."
                         : "The installed app this IPA was queued for is no longer available. SideKick kept the queued IPA and won’t install it as a new app.")
                    .foregroundStyle(.secondary)
                    if pendingUpdateIPA != nil {
                        SwiftUI.Button("Remove Queued IPA", role: .destructive) {
                            Task { await removeQueuedUpdate(requiredQueuedIPA) }
                        }
                    }
                }
            }

            if let importedApp {
                Section("Install") {
                    if !accountStore.accounts.isEmpty {
                        NavigationLink {
                            InstallAccountSelectionView(
                                app: importedApp,
                                accountStore: accountStore,
                                ipaStore: environment.ipaImportStore,
                                isUpdate: false,
                                onInstalled: nil
                            )
                        } label: {
                            Label("Install", systemImage: "arrow.down.circle")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .fullWidthListSeparators()
                        .disabled(accountStore.isWorking)
                    } else {
                        NavigationLink { AccountsView() } label: {
                            Label("Add Apple Account to Install", systemImage: "person.crop.circle.badge.plus")
                        }
                    }
                }
            } else if let installedApp, !isQueuedTargetUnavailable, installedApp.isActive {
                Section(isQueueStateUnresolved ? "Queued Update" : pendingUpdateIPA == nil ? "Open" : "Update") {
                    if isQueueStateUnresolved {
                        Text("The queued update status is still being checked. You can open the app; update actions stay unavailable until the library can be checked.")
                            .foregroundStyle(.secondary)
                        openInstalledAppButton(installedApp)
                    } else if let pendingUpdateIPA {
                        if requiredQueuedIPA == nil || (!isResolvingQueuedTarget && queuedTargetLoadError == nil && !isQueuedTargetUnavailable) {
                            queuedUpdateActions(ipa: pendingUpdateIPA, installedApp: installedApp)
                        } else {
                            Text("Retry the installed-app lookup before updating.")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        openInstalledAppButton(installedApp)
                    }
                }

                Section("Refresh") {
                    if AppOffloadService.blocksNativeOperations(installedApp.id) {
                        NavigationLink {
                            AppOffloadView(app: installedApp, accountStore: accountStore)
                        } label: {
                            Label("Restore or Recover Native App", systemImage: "arrow.uturn.backward")
                        }
                    }
                    SwiftUI.Button {
                        isShowingRefreshConsole = true
                    } label: {
                        Text("Refresh")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .disabled(AppOffloadService.blocksNativeOperations(installedApp.id))
                    .fullWidthListSeparators()

                    NavigationLink {
                        RefreshOptionsView(app: installedApp, accountStore: accountStore)
                    } label: {
                        Label("Options", systemImage: "slider.horizontal.3")
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .fullWidthListSeparators()
                }
            }

            if let installedApp, !installedApp.isActive {
                Section("Offloaded") {
                    NavigationLink("Restore App") { AppOffloadView(app: installedApp, accountStore: accountStore) }
                }
            }

            if let ipa = importedApp ?? pendingUpdateIPA ?? requiredQueuedIPA {
                Section("LiveContainer") {
                    NavigationLink {
                        LiveContainerImportView(app: ipa)
                    } label: {
                        Label("Install in LiveContainer", systemImage: "arrow.up.forward.app")
                    }
                }
            }

            Section("Details") {
                LabeledContent("Bundle ID", value: bundleIdentifier)
                    .lineLimit(2)
                    .textSelection(.enabled)
                if let importedApp {
                    LabeledContent("Imported", value: importedApp.formattedImportDate)
                }
                if let installedApp, !isQueuedTargetUnavailable {
                    LabeledContent("Signing account", value: installedApp.accountEmail)
                    LabeledContent("Team", value: installedApp.teamIdentifier)
                    LabeledContent(
                        "Signing expires",
                        value: "\(SigningExpiry.description(until: installedApp.expirationDate, now: expirationClock)) · \(installedApp.expirationDate.formatted(date: .abbreviated, time: .shortened))"
                    )
                }
                if let pendingUpdateIPA {
                    LabeledContent("Queued update", value: "Version \(pendingUpdateIPA.version)")
                }
            }

            if !isQueuedTargetUnavailable && (importedApp != nil || installedApp != nil) {
                Section("App Settings") {
                    if let installedApp, !isQueuedTargetUnavailable {
                        NavigationLink {
                            GitHubUpdateSettingsView(app: installedApp)
                        } label: {
                            Label("GitHub Update Source", systemImage: "chevron.left.forwardslash.chevron.right")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .fullWidthListSeparators()

                        SwiftUI.Button {
                            Task { await findIPAForSharing(installedApp) }
                        } label: {
                            HStack {
                                Label("Share IPA", systemImage: "square.and.arrow.up")
                                Spacer()
                                if isFindingShareIPA { ProgressView() }
                            }
                        }
                        .disabled(isFindingShareIPA)
                        .fullWidthListSeparators()

                        NavigationLink {
                            ResignOptionsView(app: installedApp, accountStore: accountStore)
                        } label: {
                            Label("Re-sign", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .fullWidthListSeparators()

                        NavigationLink {
                            AppOffloadView(app: installedApp, accountStore: accountStore)
                        } label: {
                            Label("Offload / Restore App", systemImage: "arrow.left.arrow.right")
                        }
                        .fullWidthListSeparators()

                        NavigationLink {
                            JITEnableView(app: installedApp)
                        } label: {
                            Label("Enable JIT", systemImage: "bolt.fill")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .fullWidthListSeparators()
                    } else if let importedApp {
                        NavigationLink {
                            ShareIPAView(app: importedApp)
                        } label: {
                            Label("Share IPA", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .fullWidthListSeparators()

                        if onDelete != nil {
                            SwiftUI.Button(role: .destructive) {
                                Task {
                                    await onDelete?()
                                    dismiss()
                                }
                            } label: {
                                Label("Remove Imported IPA", systemImage: "trash")
                            }
                            .fullWidthListSeparators()
                        }
                    }
                }
                .font(.body)
            }
        }
        .listStyle(.insetGrouped)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(appName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $shareIPA) { ipa in
            ShareIPAView(app: ipa)
        }
        .navigationDestination(isPresented: $isShowingRefreshConsole) {
            if let installedApp {
                RefreshConsoleView(app: installedApp, accountStore: accountStore)
            }
        }
        .onAppear { Task { await reloadManagementState() } }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await reloadManagementState() }
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) }
                catch { return }
                expirationClock = .now
            }
        }
        .alert("App action failed", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            SwiftUI.Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder
    private func queuedUpdateActions(ipa: ImportedIPA, installedApp: InstalledAppSummary) -> some View {
        let updateAccounts = accountStore.accounts
        let installedTeamAccount = updateAccounts.first(where: {
            $0.accountIdentifier == installedApp.accountIdentifier &&
            $0.teamIdentifier == installedApp.teamIdentifier
        })
        if let account = installedTeamAccount, account.hasSavedSession {
            NavigationLink {
                InstallConsoleView(
                    app: ipa,
                    account: account,
                    accountStore: accountStore,
                    ipaStore: environment.ipaImportStore,
                    isUpdate: true,
                    onInstalled: { await finishQueuedUpdate(ipa) }
                )
            } label: {
                Label("Update", systemImage: "arrow.down.app")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .fullWidthListSeparators()

        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let installedTeamAccount {
                    NavigationLink {
                        SigningAccountDetailView(account: installedTeamAccount, accountStore: accountStore)
                    } label: {
                        Label("Reconnect the Apple account for this installed team", systemImage: "person.crop.circle.badge.exclamationmark")
                    }
                } else {
                    NavigationLink {
                        AccountsView()
                    } label: {
                        Label("Add the Apple account for the installed team", systemImage: "person.crop.circle.badge.plus")
                    }
                }
                Text("The installed app uses team \(installedApp.teamIdentifier). Use Options to choose another team for a separate installation.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
                NavigationLink {
                    InstallAccountSelectionView(
                        app: ipa,
                        accountStore: accountStore,
                        ipaStore: environment.ipaImportStore,
                        isUpdate: true,
                        onInstalled: { await finishQueuedUpdate(ipa) },
                        currentTeamIdentifier: installedApp.teamIdentifier
                    )
                } label: {
                    Label("Options", systemImage: "slider.horizontal.3")
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .fullWidthListSeparators()
        SwiftUI.Button(role: .destructive) {
            isConfirmingQueuedUpdateRemoval = true
        } label: {
            Label("Remove Queued IPA", systemImage: "trash")
        }
        .fullWidthListSeparators()
        .alert("Remove queued update?", isPresented: $isConfirmingQueuedUpdateRemoval) {
            SwiftUI.Button("Remove IPA", role: .destructive) { Task { await removeQueuedUpdate() } }
            SwiftUI.Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the queued IPA from SideKick. The installed app will remain on your device.")
        }
    }

    @MainActor
    private func finishQueuedUpdate(_ ipa: ImportedIPA) async {
        do {
            try await environment.ipaImportStore.delete(ipa)
            pendingUpdateIPA = nil
            await reloadManagementState()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        if let data = importedApp?.iconData ?? installedApp?.iconData ?? requiredQueuedIPA?.iconData, let icon = UIImage(data: data) {
            Image(uiImage: icon).resizable().scaledToFit()
        } else {
            Image(systemName: "app.fill")
                .font(.system(size: 34))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.blue.gradient)
        }
    }

    @MainActor
    private func reloadManagementState() async {
        expirationClock = .now
        if importedApp == nil && (requiredQueuedIPA != nil || installedApp != nil) {
            isResolvingQueuedIPA = true
            queuedIPAReadError = nil
        }
        var availableInstallations: [InstalledAppSummary] = []
        if requiredQueuedIPA != nil || installedApp != nil {
            let service = SideStoreOperationService(accountStore: accountStore, ipaStore: environment.ipaImportStore)
            let apps: [InstalledAppSummary]
            if requiredQueuedIPA != nil {
                do {
                    apps = try await service.loadInstalledApps()
                    queuedTargetLoadError = nil
                } catch {
                    isResolvingQueuedTarget = false
                    isResolvingQueuedIPA = false
                    queuedTargetLoadError = error.localizedDescription
                    await accountStore.reload()
                    return
                }
            } else {
                apps = await service.installedApps()
            }
            availableInstallations = apps
            if let requiredQueuedIPA {
                let target: InstalledAppSummary?
                if let targetID = requiredQueuedIPA.queuedForInstalledAppID {
                    target = apps.first(where: { $0.id == targetID })
                } else {
                    let matching = apps.filter { $0.updateMatchingBundleIdentifiers.contains(requiredQueuedIPA.bundleIdentifier.lowercased()) }
                    target = matching.count == 1 ? matching.first : nil
                }
                isResolvingQueuedTarget = false
                guard let target else {
                    installedApp = nil
                    isQueuedTargetUnavailable = false
                    do {
                        let imports = try await environment.ipaImportStore.importedApps()
                        pendingUpdateIPA = imports.first(where: {
                            $0.id == requiredQueuedIPA.id && $0.importedAt == requiredQueuedIPA.importedAt
                        })
                        queuedIPAReadError = nil
                        isQueuedTargetUnavailable = true
                    } catch {
                        queuedIPAReadError = error.localizedDescription
                    }
                    isResolvingQueuedIPA = false
                    await accountStore.reload()
                    return
                }
                installedApp = target
                isQueuedTargetUnavailable = false
            } else if let current = installedApp {
                if let latest = apps.first(where: { $0.id == current.id }) {
                    installedApp = latest
                    isQueuedTargetUnavailable = false
                }
            }
        }
        if let installedApp {
            let matchingBundleIDs = installedApp.updateMatchingBundleIdentifiers
            do {
                let imports = try await environment.ipaImportStore.importedApps()
                pendingUpdateIPA = imports.first { ipa in
                    ipa.isUpdateQueued && (ipa.queuedForInstalledAppID == installedApp.id || (ipa.queuedForInstalledAppID == nil && matchingBundleIDs.contains(ipa.bundleIdentifier.lowercased()) && availableInstallations.filter { app in app.updateMatchingBundleIdentifiers.contains(ipa.bundleIdentifier.lowercased()) }.count == 1))
                }
                queuedIPAReadError = nil
            } catch {
                queuedIPAReadError = error.localizedDescription
            }
            isResolvingQueuedIPA = false
        } else if importedApp == nil && requiredQueuedIPA == nil {
            isResolvingQueuedIPA = false
        }
        await accountStore.reload()
    }

    @MainActor
    private func retryQueuedTargetResolution() {
        isResolvingQueuedIPA = true
        queuedIPAReadError = nil
        if requiredQueuedIPA != nil {
            isResolvingQueuedTarget = true
            isQueuedTargetUnavailable = false
            queuedTargetLoadError = nil
        }
        Task { await reloadManagementState() }
    }

    private func openInstalledAppButton(_ app: InstalledAppSummary) -> some View {
        SwiftUI.Button {
            UIApplication.shared.open(InstalledApp.openAppURL(targetBundleIdentifier: app.resignedBundleIdentifier))
        } label: {
            Text("Open")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .fullWidthListSeparators()
    }

    @MainActor
    private func removeQueuedUpdate(_ requestedIPA: ImportedIPA? = nil) async {
        guard let pendingUpdateIPA = requestedIPA ?? pendingUpdateIPA else { return }
        do {
            try await environment.ipaImportStore.delete(pendingUpdateIPA)
            self.pendingUpdateIPA = nil
            if requiredQueuedIPA != nil {
                dismiss()
                return
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func findIPAForSharing(_ app: InstalledAppSummary) async {
        isFindingShareIPA = true
        defer { isFindingShareIPA = false }
        do {
            let imported = try await environment.ipaImportStore.importedApps()
            guard let sourceIPA = imported.first(where: { $0.bundleIdentifier == app.bundleIdentifier }) else {
                errorMessage = "SideKick can’t extract an IPA from an installed app. Import its original IPA into SideKick first, then share it here."
                return
            }
            shareIPA = sourceIPA
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private enum AppSigningOperation: Equatable {
    case refresh
    case resign

    var statusTitle: String { self == .refresh ? "Refresh Status" : "Re-sign Status" }
}

private enum AppSigningError: LocalizedError {
    case accountRequired

    var errorDescription: String? {
        "Choose a saved Apple ID before re-signing this app."
    }
}

struct OperationStatusView: View {
    let title: String
    let appName: String
    let stageSummary: String
    let progress: Double
    let isRunning: Bool
    let failure: String?
    let lines: [String]
    let account: SigningAccountSummary?
    let accountStore: SigningAccountStore?
    let onRetry: () -> Void
    let onClose: () -> Void
    var expandActivityInitially = false

    @State private var isActivityExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.largeTitle.bold())
                Text(appName)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                ProgressView(value: progress)
                    .tint(failure == nil ? .accentColor : .red)
                Text(stageSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if isRunning {
                    Text("\(Int(progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            DisclosureGroup("Activity Log", isExpanded: $isActivityExpanded) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 9) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(.footnote, design: .monospaced))
                                    .foregroundStyle(line.contains("ERROR") ? .red : .primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(index)
                            }
                        }
                        .padding(14)
                    }
                    .frame(maxHeight: 280)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
                    .onChange(of: lines.count) { _, count in
                        if isActivityExpanded, count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                    }
                    .onChange(of: isActivityExpanded) { _, expanded in
                        if expanded, !lines.isEmpty { proxy.scrollTo(lines.count - 1, anchor: .bottom) }
                    }
                }
            }

            if !isRunning {
                if failure != nil {
                    SwiftUI.Button(action: onRetry) {
                        Label("Try Again", systemImage: "arrow.clockwise")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)

                    if shouldOfferReconnect, let account, let accountStore {
                        NavigationLink {
                            SigningAccountDetailView(account: account, accountStore: accountStore, forceReconnect: true)
                        } label: {
                            Label("Reconnect Apple ID", systemImage: "person.crop.circle.badge.exclamationmark")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                    }
                }

                if failure == nil {
                    SwiftUI.Button("Done", action: onClose)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                } else {
                    SwiftUI.Button("Close", action: onClose)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                }
            }
        }
        .padding()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(isRunning ? .hidden : .visible, for: .navigationBar)
        .interactiveDismissDisabled(isRunning)
        .onAppear { if expandActivityInitially { isActivityExpanded = true } }
    }

    private var shouldOfferReconnect: Bool {
        guard let failure else { return false }
        let message = failure.localizedLowercase
        return ["account", "apple id", "session", "credential", "sign in", "authentication", "certificate", "keychain", "provision"]
            .contains { message.localizedCaseInsensitiveContains($0) }
    }
}

private struct RefreshConsoleView: View {
    let app: InstalledAppSummary
    let accountStore: SigningAccountStore
    var selectedAccount: SigningAccountSummary? = nil
    var operation: AppSigningOperation = .refresh

    @Environment(AppEnvironment.self) private var environment
    @State private var progress = 0.0
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [String] = []
    @State private var isRunning = true
    @State private var didStart = false
    @State private var failure: String?
    @State private var lastLoggedPercent = -5
    @State private var stageSummary = "Preparing your app"

    var body: some View {
        OperationStatusView(
            title: operation.statusTitle,
            appName: app.name,
            stageSummary: stageSummary,
            progress: progress,
            isRunning: isRunning,
            failure: failure,
            lines: lines,
            account: reconnectAccount,
            accountStore: accountStore,
            onRetry: retry,
            onClose: { dismiss() }
        )
        .task {
            guard !didStart else { return }
            didStart = true
            await runRefresh()
        }
    }

    @MainActor
    private func runRefresh() async {
        failure = nil
        stageSummary = "Preparing your app for \(operation == .refresh ? "refresh" : "re-signing")"
        append("Starting \(operation == .refresh ? "refresh" : "re-sign") · \(Date.now.formatted(date: .omitted, time: .standard))")
        append("Account selected · \(selectedAccount?.email ?? app.accountEmail)")
        append(operation == .refresh ? "Preparing signing refresh" : "Preparing app re-sign")
        do {
            let service = SideStoreOperationService(accountStore: accountStore, ipaStore: environment.ipaImportStore)
            if operation == .resign {
                guard let selectedAccount else {
                    throw AppSigningError.accountRequired
                }
                try await service.resign(bundleIdentifier: app.id, using: selectedAccount) { value in
                    updateProgress(value)
                }
            } else {
                try await service.refresh(bundleIdentifier: app.id, using: selectedAccount) { value in
                    updateProgress(value)
                }
            }
            progress = 1
            stageSummary = operation == .refresh ? "Your app was refreshed." : "Your app was re-signed."
            append(operation == .refresh ? "Refresh completed successfully" : "Re-sign completed successfully")
            await ExpirationNotificationScheduler.update()
        } catch {
            failure = error.localizedDescription
            stageSummary = operation == .refresh ? "SideKick couldn’t refresh this app." : "SideKick couldn’t re-sign this app."
            append("ERROR · \(error.localizedDescription)")
        }
        isRunning = false
    }

    @MainActor
    private func updateProgress(_ value: Double) {
        progress = min(max(value, 0), 1)
        if value > 0 {
            stageSummary = operation == .refresh ? "Signing and refreshing your app." : "Signing your app."
            let percent = Int(value * 100)
            if percent >= lastLoggedPercent + 5 || percent == 100 {
                lastLoggedPercent = percent
                append("\(operation == .refresh ? "Refresh" : "Re-sign") pipeline progress · \(percent)%")
            }
        }
    }

    @MainActor
    private func append(_ message: String) {
        lines.append("[\(Date.now.formatted(date: .omitted, time: .standard))] \(message)")
    }

    private var reconnectAccount: SigningAccountSummary? {
        selectedAccount ?? accountStore.accounts.first {
            $0.accountIdentifier == app.accountIdentifier && $0.teamIdentifier == app.teamIdentifier
        }
    }

    @MainActor
    private func retry() {
        progress = 0
        lastLoggedPercent = -5
        stageSummary = "Preparing your app"
        isRunning = true
        Task { await runRefresh() }
    }
}

private struct ResignOptionsView: View {
    let app: InstalledAppSummary
    let accountStore: SigningAccountStore

    private var eligibleAccounts: [SigningAccountSummary] {
        accountStore.accounts
    }

    var body: some View {
        List {
            if eligibleAccounts.isEmpty {
                Section {
                    Text("Add a saved Apple ID on this app’s signing team in Accounts to re-sign it.")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Signing Account")
                } footer: {
                    Text("Re-signing keeps the app on its current team and replaces its signing certificate. A different team requires installing the app again.")
                }
            } else {
                Section {
                    ForEach(eligibleAccounts) { account in
                        NavigationLink {
                            if !account.hasSavedSession {
                                SigningAccountDetailView(account: account, accountStore: accountStore)
                            } else if account.teamIdentifier != app.teamIdentifier {
                                OtherTeamSourceView(app: app, account: account, accountStore: accountStore)
                            } else {
                                RefreshConsoleView(
                                    app: app,
                                    accountStore: accountStore,
                                    selectedAccount: account,
                                    operation: .resign
                                )
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(account.email)
                                    .font(.body.weight(.medium))
                                Text(account.hasSavedSession ? "\(account.teamName) · \(account.teamType)" : "Reconnect this account")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 5)
                        }
                        .fullWidthListSeparators()
                    }
                } header: {
                    Text("Signing Account")
                } footer: {
                    Text("Choose any saved Apple ID. Accounts on this signing team can re-sign the current app. Another team requires a separate installation from an IPA, with separate app data.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Re-sign App")
        .navigationBarTitleDisplayMode(.inline)
        .task { await accountStore.reload() }
    }
}

private struct RefreshOptionsView: View {
    let app: InstalledAppSummary
    let accountStore: SigningAccountStore

    private var eligibleAccounts: [SigningAccountSummary] {
        accountStore.accounts
    }

    var body: some View {
        List {
            if eligibleAccounts.isEmpty {
                Section {
                    Text("Add or reconnect an Apple ID in Accounts to continue.")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Signing Account")
                } footer: {
                    Text("Refreshing keeps the app on its current signing team. To change teams, install or update from an IPA using the other account.")
                }
            } else {
                Section {
                    ForEach(eligibleAccounts) { account in
                        NavigationLink {
                            if !account.hasSavedSession {
                                SigningAccountDetailView(account: account, accountStore: accountStore)
                            } else if account.teamIdentifier != app.teamIdentifier {
                                OtherTeamSourceView(app: app, account: account, accountStore: accountStore)
                            } else {
                                RefreshConsoleView(
                                    app: app,
                                    accountStore: accountStore,
                                    selectedAccount: account
                                )
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(account.email)
                                    .font(.body.weight(.medium))
                                Text(account.hasSavedSession ? "\(account.teamName) · \(account.teamType)" : "Reconnect this account")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 5)
                        }
                        .fullWidthListSeparators()
                    }
                } header: {
                    Text("Signing Account")
                } footer: {
                    Text("Choose the saved Apple ID session SideKick should use for this refresh. The installed app’s signing team must stay the same.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Refresh Options")
        .navigationBarTitleDisplayMode(.inline)
        .task { await accountStore.reload() }
    }
}

private struct JITEnableView: View {
    let app: InstalledAppSummary

    @Environment(AppEnvironment.self) private var environment
    @State private var accountStore = SigningAccountStore()
    @State private var isWorking = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Label("Open \(app.name) first, then return here and enable JIT. Keep the app open in the background while SideKick connects.", systemImage: "info.circle")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)

                if #available(iOS 17, *) {
                    NavigationLink {
                        SideJITServerConfigView()
                    } label: {
                        Label("JIT Server Setup", systemImage: "desktopcomputer")
                    }
                    Text("On iOS 17 and later, JIT may need SideJITServer running on a paired computer on the same network. SideKick can connect to it, but cannot run that computer-side service itself.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("JIT uses the device pairing connection. Keep the pairing file valid and the local device connection available.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Before You Enable JIT")
            }

            Section {
                SwiftUI.Button {
                    Task { await enableJIT() }
                } label: {
                    HStack {
                        if isWorking { ProgressView() }
                        Text(isWorking ? "Connecting…" : "Enable JIT for \(app.name)")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(isWorking)

                if let statusMessage {
                    Label(statusMessage, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("JIT Connection")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Enable JIT")
        .navigationBarTitleDisplayMode(.inline)
    }

    @MainActor
    private func enableJIT() async {
        isWorking = true
        statusMessage = nil
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await SideStoreOperationService(accountStore: accountStore, ipaStore: environment.ipaImportStore)
                .enableJIT(bundleIdentifier: app.id)
            statusMessage = "JIT was enabled for \(app.name)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct InstallAccountSelectionView: View {
    let app: ImportedIPA
    let accountStore: SigningAccountStore
    let ipaStore: IPAImportStore
    let isUpdate: Bool
    let onInstalled: (() async -> Void)?
    var onSourceMissing: (() async -> Void)? = nil
    var currentTeamIdentifier: String? = nil

    private var accounts: [SigningAccountSummary] { accountStore.accounts }

    var body: some View {
        List {
            Section {
                if accounts.isEmpty {
                    Text("Add an Apple ID in Accounts to continue.").foregroundStyle(.secondary)
                    NavigationLink("Accounts") { AccountsView() }
                }
                ForEach(accounts) { account in
                    NavigationLink {
                        if !account.hasSavedSession {
                            SigningAccountDetailView(account: account, accountStore: accountStore)
                        } else if let currentTeamIdentifier, currentTeamIdentifier != account.teamIdentifier {
                            SeparateInstallReviewView(source: app, account: account, accountStore: accountStore, originalName: app.name)
                        } else {
                            InstallConsoleView(app: app, account: account, accountStore: accountStore, ipaStore: ipaStore, isUpdate: isUpdate, onInstalled: onInstalled, onSourceMissing: onSourceMissing)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(account.email).font(.body.weight(.medium))
                            Text(account.hasSavedSession ? "\(account.teamName) · \(account.teamType)" : "Reconnect this account")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 5)
                    }
                }
            } header: {
                Text("Apple Account")
            } footer: {
                Text("Choose the account that will sign \(app.name). Updating the existing app keeps its team. A different team offers a separate installation with separate data.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Choose Account")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { Task { await accountStore.reload() } }
        .onReceive(NotificationCenter.default.publisher(for: .sideKickSigningAccountsDidChange)) { _ in
            Task { await accountStore.reload() }
        }
    }
}

enum InstallStartState: Equatable {
    case awaitingConfirmation, ready, running, finished

    init(requiresConfirmation: Bool) {
        self = requiresConfirmation ? .awaitingConfirmation : .ready
    }

    mutating func confirm() {
        if self == .awaitingConfirmation { self = .ready }
    }

    mutating func begin() -> Bool {
        guard self == .ready else { return false }
        self = .running
        return true
    }
}

struct InstallConsoleView: View {
    let app: ImportedIPA
    let account: SigningAccountSummary
    let accountStore: SigningAccountStore
    let ipaStore: IPAImportStore
    let isUpdate: Bool
    let onInstalled: (() async -> Void)?
    var onSourceMissing: (() async -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var lines: [String] = []
    @State private var progress = 0.0
    @State private var startState = InstallStartState(requiresConfirmation: UserDefaults.standard.isInstallConfirmationEnabled)
    @State private var failure: String?
    @State private var lastLoggedPercent = -5
    @State private var stageSummary = "Preparing your app"

    private var isRunning: Bool { startState != .finished }

    var body: some View {
        Group {
            if startState == .awaitingConfirmation {
                VStack(alignment: .leading, spacing: 20) {
                    Text(isUpdate ? "Ready to Update" : "Ready to Install").font(.largeTitle.bold())
                    Text(app.name).font(.title3)
                    Text("Version \(app.version) will be signed using \(account.email).")
                        .foregroundStyle(.secondary)
                    SwiftUI.Button(isUpdate ? "Update" : "Install") { startState.confirm() }
                        .buttonStyle(.borderedProminent)
                    SwiftUI.Button("Cancel", role: .cancel) { dismiss() }
                }
                .padding(24)
                .frame(maxWidth: 640, alignment: .leading)
            } else {
                statusView
            }
        }
        .task(id: startState == .awaitingConfirmation) {
            await runInstall()
        }
    }

    private var statusView: some View {
        OperationStatusView(
            title: isUpdate ? "Update Status" : "Install Status",
            appName: app.name,
            stageSummary: stageSummary,
            progress: progress,
            isRunning: isRunning,
            failure: failure,
            lines: lines,
            account: account,
            accountStore: accountStore,
            onRetry: retry,
            onClose: { dismiss() }
        )
    }

    @MainActor
    private func runInstall() async {
        guard startState.begin() else { return }
        failure = nil
        stageSummary = isUpdate ? "Preparing your app update." : "Preparing your app for installation."
        append("Starting install · \(Date.now.formatted(date: .omitted, time: .standard))")
        append("Account selected · \(account.email)")
        append(isUpdate ? "Preparing update IPA" : "Preparing imported IPA")
        do {
            try await SideStoreOperationService(accountStore: accountStore, ipaStore: ipaStore)
                .install(
                    app,
                    using: account,
                    recoveryHandler: {
                        append("Revoked custom certificate found · switching to the selected Apple ID certificate and retrying")
                    }
                ) { fraction in
                    let clamped = min(max(fraction, 0), 1)
                    progress = clamped
                    if clamped > 0 {
                        stageSummary = "Signing and installing your app."
                        let percent = Int(clamped * 100)
                        if percent >= lastLoggedPercent + 5 || percent == 100 {
                            lastLoggedPercent = percent
                            append("Install pipeline progress · \(percent)%")
                        }
                    }
                }
            progress = 1
            stageSummary = isUpdate ? "Your app was updated." : "Your app was installed."
            append(isUpdate ? "Update completed successfully" : "Install completed successfully")
            await onInstalled?()
        } catch {
            failure = error.localizedDescription
            stageSummary = isUpdate ? "SideKick couldn’t update this app." : "SideKick couldn’t install this app."
            append("ERROR · \(error.localizedDescription)")
            if let importError = error as? IPAImportError, case .sourceFileMissing = importError {
                await onSourceMissing?()
            }
        }
        startState = .finished
    }

    @MainActor
    private func append(_ message: String) {
        lines.append("[\(Date.now.formatted(date: .omitted, time: .standard))] \(message)")
    }

    @MainActor
    private func retry() {
        progress = 0
        lastLoggedPercent = -5
        stageSummary = "Preparing your app"
        startState = .ready
        Task { await runInstall() }
    }
}
