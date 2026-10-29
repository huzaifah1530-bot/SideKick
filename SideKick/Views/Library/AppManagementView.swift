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

    private enum Route: Hashable {
        case refreshAccount, resign, offload, jit, liveContainer, install, addAccount
    }

    @State private var route: Route?
    @State private var isConfirmingImportedRemoval = false

    private var iconData: Data? { importedApp?.iconData ?? installedApp?.iconData ?? requiredQueuedIPA?.iconData }
    private var versionText: String {
        importedApp?.version ?? installedApp?.version ?? requiredQueuedIPA?.version ?? ""
    }
    private var canActOnInstalledApp: Bool {
        guard let installedApp else { return false }
        return !isQueuedTargetUnavailable && installedApp.isActive
    }

    var body: some View {
        List {
            Section {
                DetailHeader(iconData: iconData, title: appName, subtitle: versionText) {
                    headerBadge
                }
                primaryActions
                    .padding(.top, Spacing.xs)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: Spacing.xs, leading: Spacing.m, bottom: Spacing.xs, trailing: Spacing.m))
            .listRowSeparator(.hidden)

            queuedUpdateStatus

            if let installedApp, canActOnInstalledApp, let pendingUpdateIPA, !isQueueStateUnresolved {
                Section {
                    queuedUpdateActions(ipa: pendingUpdateIPA, installedApp: installedApp)
                } header: {
                    Text("Update")
                }
            }

            if let installedApp, !isQueuedTargetUnavailable {
                Section {
                    NavigationLink { GitHubUpdateSettingsView(app: installedApp) } label: {
                        Label("GitHub Updates", systemImage: "arrow.down.app")
                    }
                } footer: {
                    Text("Track a GitHub repository for new builds of this app.")
                }
            }

            if let importedApp {
                Section {
                    LabeledContent("Version", value: importedApp.buildVersion.map { $0 == importedApp.version ? importedApp.version : "\(importedApp.version) (\($0))" } ?? importedApp.version)
                    LabeledContent("Bundle ID", value: bundleIdentifier).lineLimit(1).textSelection(.enabled)
                    if let repository = importedApp.githubRepositoryURL, let url = URL(string: repository) {
                        LabeledContent("Source", value: url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                    }
                    LabeledContent("Imported", value: importedApp.formattedImportDate)
                } header: {
                    Text("Details")
                } footer: {
                    if importedApp.githubImportConfiguration != nil {
                        Text("After you install it, SideKick checks this GitHub source for updates.")
                    }
                }
            }

            if importedApp == nil {
            Section {
                DisclosureGroup("Details") {
                    LabeledContent("Bundle ID", value: bundleIdentifier)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    if let importedApp {
                        LabeledContent("Imported", value: importedApp.formattedImportDate)
                    }
                    if let installedApp, !isQueuedTargetUnavailable {
                        if let certificate = installedApp.importedCertificate {
                            LabeledContent("Signed With", value: certificate.name)
                            if let profile = certificate.profile {
                                LabeledContent("Signing Team", value: profile.teamName.isEmpty ? profile.teamIdentifier : profile.teamName)
                            }
                        } else {
                            LabeledContent("Apple Account", value: installedApp.accountEmail)
                            LabeledContent("Team", value: installedApp.teamIdentifier)
                        }
                        LabeledContent("Expires", value: installedApp.expirationDate.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let pendingUpdateIPA {
                        LabeledContent("Downloaded update", value: pendingUpdateIPA.version)
                    }
                }
            }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(appName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .navigationDestination(item: $shareIPA) { ipa in
            ShareIPAView(app: ipa)
        }
        .navigationDestination(isPresented: $isShowingRefreshConsole) {
            if let installedApp {
                RefreshConsoleView(app: installedApp, accountStore: accountStore)
            }
        }
        .navigationDestination(item: $route) { route in
            destination(for: route)
        }
        .confirmationDialog("Remove \(appName)?", isPresented: $isConfirmingImportedRemoval, titleVisibility: .visible) {
            SwiftUI.Button("Remove IPA", role: .destructive) {
                Task {
                    await onDelete?()
                    dismiss()
                }
            }
        } message: {
            Text("This removes the imported IPA from SideKick. Installed apps aren’t affected.")
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
        .messageAlert("Couldn’t Continue", message: $errorMessage)
    }

    // MARK: Header

    @ViewBuilder
    private var headerBadge: some View {
        if let installedApp, !installedApp.isActive {
            StatusBadge(title: "Offloaded", systemImage: "icloud.and.arrow.down", tone: .neutral)
        } else if pendingUpdateIPA != nil {
            StatusBadge(title: "Update ready", systemImage: "arrow.down.circle.fill", tone: .accent)
        } else if let installedApp, !isQueuedTargetUnavailable, installedApp.expirationDate <= expirationClock {
            StatusBadge(title: "Expired", systemImage: "xmark.circle.fill", tone: .critical)
        } else if let installedApp, !isQueuedTargetUnavailable {
            let days = SigningExpiry.daysRemaining(until: installedApp.expirationDate, now: expirationClock)
            StatusBadge(
                title: "Expires \(SigningExpiry.description(until: installedApp.expirationDate, now: expirationClock))",
                systemImage: days <= 2 ? "exclamationmark.circle.fill" : "checkmark.seal.fill",
                tone: days <= 2 ? .warning : .success
            )
        } else if importedApp != nil {
            StatusBadge(title: "Not installed", systemImage: "arrow.down.circle", tone: .neutral)
        }
    }

    // MARK: Primary actions

    @ViewBuilder
    private var primaryActions: some View {
        if importedApp != nil {
            // Buttons, not NavigationLinks: a link inside a List row renders as a plain row
            // with a chevron and ignores the button style.
            HStack(spacing: Spacing.s) {
                SwiftUI.Button { route = !accountStore.hasSigningIdentities ? .addAccount : .install } label: {
                    ActionLabel(!accountStore.hasSigningIdentities ? "Add Account" : "Install")
                }
                .primaryActionStyle()
                .disabled(accountStore.isWorking)

                SwiftUI.Button { route = .liveContainer } label: {
                    ActionLabel("LiveContainer", systemImage: "square.stack.3d.up")
                }
                .secondaryActionStyle()
                .tint(.sideKickAccent)
            }
        } else if let installedApp, !isQueuedTargetUnavailable {
            if !installedApp.isActive || AppOffloadService.blocksNativeOperations(installedApp.id) {
                SwiftUI.Button { route = .offload } label: {
                    ActionLabel(installedApp.isActive ? "Recover App" : "Restore App", systemImage: "arrow.down.circle")
                }
                .primaryActionStyle()
            } else {
                HStack(spacing: Spacing.s) {
                    SwiftUI.Button { openInstalledApp(installedApp) } label: {
                        ActionLabel("Open")
                    }
                    .primaryActionStyle()

                    SwiftUI.Button { isShowingRefreshConsole = true } label: {
                        ActionLabel("Refresh", systemImage: "arrow.clockwise")
                    }
                    .secondaryActionStyle()
                    .tint(.sideKickAccent)
                }
            }
        }
    }

    // MARK: Queued update status

    @ViewBuilder
    private var queuedUpdateStatus: some View {
        if requiredQueuedIPA != nil && isResolvingQueuedTarget {
            Section { ProgressView("Finding the app this update is for…") }
        } else if requiredQueuedIPA != nil, let queuedTargetLoadError {
            Section {
                Label("Couldn’t match this update to an installed app", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(queuedTargetLoadError).font(.footnote).foregroundStyle(.secondary)
                SwiftUI.Button("Try Again") { retryQueuedTargetResolution() }
            } footer: {
                Text("The downloaded IPA was kept.")
            }
        } else if let queuedIPAReadError {
            Section {
                Label("Couldn’t check for a downloaded update", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(queuedIPAReadError).font(.footnote).foregroundStyle(.secondary)
                SwiftUI.Button("Try Again") { retryQueuedTargetResolution() }
            } footer: {
                Text("Update actions are paused until SideKick can read its library.")
            }
        } else if isResolvingQueuedIPA && installedApp == nil {
            Section { ProgressView("Checking downloaded updates…") }
        } else if let requiredQueuedIPA, isQueuedTargetUnavailable {
            Section {
                Text(pendingUpdateIPA == nil
                     ? "The app this IPA was for is no longer installed, and the IPA is no longer queued."
                     : "The app this IPA was for is no longer installed. SideKick won’t install it as a new app.")
                .foregroundStyle(.secondary)
                if pendingUpdateIPA != nil {
                    SwiftUI.Button("Remove Downloaded IPA", role: .destructive) {
                        Task { await removeQueuedUpdate(requiredQueuedIPA) }
                    }
                }
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if let importedApp {
                NavigationLink { ShareIPAView(app: importedApp) } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share IPA")
            } else if let installedApp, canActOnInstalledApp {
                SwiftUI.Button { Task { await findIPAForSharing(installedApp) } } label: {
                    if isFindingShareIPA { ProgressView() } else { Image(systemName: "square.and.arrow.up") }
                }
                .disabled(isFindingShareIPA)
                .accessibilityLabel("Share IPA")
            }

            if hasMoreActions {
                Menu {
                    moreMenuItems
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        }
    }

    private var hasMoreActions: Bool {
        canActOnInstalledApp || importedApp != nil || pendingUpdateIPA != nil || requiredQueuedIPA != nil
    }

    @ViewBuilder
    private var moreMenuItems: some View {
        if let installedApp, canActOnInstalledApp, !AppOffloadService.blocksNativeOperations(installedApp.id) {
            Section {
                SwiftUI.Button { route = .refreshAccount } label: {
                    Label("Refresh with…", systemImage: "person.crop.circle")
                }
                SwiftUI.Button { route = .resign } label: {
                    Label("Re-sign…", systemImage: "signature")
                }
                SwiftUI.Button { route = .jit } label: {
                    Label("Enable JIT…", systemImage: "bolt")
                }
            }
            Section {
                SwiftUI.Button { route = .offload } label: {
                    Label("Offload…", systemImage: "icloud.and.arrow.up")
                }
            }
        }
        if importedApp == nil, (pendingUpdateIPA ?? requiredQueuedIPA) != nil {
            Section {
                SwiftUI.Button { route = .liveContainer } label: {
                    Label("Install in LiveContainer…", systemImage: "square.stack.3d.up")
                }
            }
        }
        if importedApp != nil, onDelete != nil {
            Section {
                SwiftUI.Button(role: .destructive) { isConfirmingImportedRemoval = true } label: {
                    Label("Remove IPA", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .refreshAccount:
            if let installedApp { RefreshOptionsView(app: installedApp, accountStore: accountStore) }
        case .resign:
            if let installedApp { ResignOptionsView(app: installedApp, accountStore: accountStore) }
        case .offload:
            if let installedApp { AppOffloadView(app: installedApp, accountStore: accountStore) }
        case .jit:
            if let installedApp { JITEnableView(app: installedApp) }
        case .liveContainer:
            if let ipa = importedApp ?? pendingUpdateIPA ?? requiredQueuedIPA { LiveContainerImportView(app: ipa) }
        case .install:
            if let importedApp {
                InstallAccountSelectionView(app: importedApp, accountStore: accountStore,
                    ipaStore: environment.ipaImportStore, isUpdate: false, onInstalled: nil)
            }
        case .addAccount:
            AccountsView()
        }
    }

    private func openInstalledApp(_ app: InstalledAppSummary) {
        UIApplication.shared.open(InstalledApp.openAppURL(targetBundleIdentifier: app.resignedBundleIdentifier))
    }

    @ViewBuilder
    private func queuedUpdateActions(ipa: ImportedIPA, installedApp: InstalledAppSummary) -> some View {
        let updateAccounts = accountStore.accounts
        let installedTeamAccount = updateAccounts.first(where: { installedApp.isSignable(by: $0) })
        if let certificate = installedApp.importedCertificate {
            NavigationLink {
                InstallConsoleView(app: ipa, account: nil, accountStore: accountStore,
                    ipaStore: environment.ipaImportStore, isUpdate: true,
                    onInstalled: { await finishQueuedUpdate(ipa) }, certificate: certificate)
            } label: {
                Label("Update to \(ipa.version)", systemImage: "arrow.down.circle.fill")
            }
        } else if let account = installedTeamAccount, account.hasSavedSession {
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
                HStack {
                    Label("Update to \(ipa.version)", systemImage: "arrow.down.circle.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.sideKickAccent)
                    Spacer()
                }
            }
        } else if let installedTeamAccount {
            NavigationLink {
                SigningAccountDetailView(account: installedTeamAccount, accountStore: accountStore)
            } label: {
                Label("Reconnect Account to Update", systemImage: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(.orange)
            }
        } else {
            NavigationLink {
                AccountsView()
            } label: {
                Label("Add the Account for Team \(installedApp.teamIdentifier)", systemImage: "person.crop.circle.badge.plus")
            }
        }
        NavigationLink {
            InstallAccountSelectionView(
                app: ipa,
                accountStore: accountStore,
                ipaStore: environment.ipaImportStore,
                isUpdate: true,
                onInstalled: { await finishQueuedUpdate(ipa) },
                // A SideKick copy on an imported certificate has no Apple team record.
                currentTeamIdentifier: installedApp.importedCertificate == nil && !installedApp.teamIdentifier.isEmpty
                    ? installedApp.teamIdentifier : nil
            )
        } label: {
            Label("Update with Another Identity…", systemImage: "person.2")
        }
        SwiftUI.Button(role: .destructive) {
            isConfirmingQueuedUpdateRemoval = true
        } label: {
            Label("Remove Downloaded Update", systemImage: "trash")
        }
        .confirmationDialog("Remove downloaded update?", isPresented: $isConfirmingQueuedUpdateRemoval, titleVisibility: .visible) {
            SwiftUI.Button("Remove Update", role: .destructive) { Task { await removeQueuedUpdate() } }
        } message: {
            Text("The installed app stays on your iPhone.")
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

    var statusTitle: String { self == .refresh ? "Refresh" : "Re-sign" }
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

    var stages: [String] = ["Prepare", "Sign", "Install", "Done"]

    @State private var isActivityExpanded = false
    @State private var isTechnicalExpanded = false
    @State private var didCopy = false

    private var explanation: OperationFailureExplanation? {
        failure.map(OperationFailureExplanation.init(message:))
    }

    private var phase: OperationPhase {
        if isRunning { return .running }
        return failure == nil ? .succeeded : .failed
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                hero
                StageTracker(stages: stages, progress: progress, failed: failure != nil)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Progress")
                    .accessibilityValue(isRunning ? "\(Int(progress * 100)) percent" : (failure == nil ? "Complete" : "Stopped"))

                if let explanation {
                    failureCard(explanation)
                }

                if isRunning {
                    Label("Keep SideKick open and your local connection on until this finishes.", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !lines.isEmpty {
                    activity
                }
            }
            .frame(maxWidth: SideKickLayout.readableWidth)
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.l)
            .frame(maxWidth: .infinity)
        }
        .background(Color.sideKickCanvas)
        .safeAreaInset(edge: .bottom) {
            if !isRunning {
                BottomActionBar { actions }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isRunning)
        .interactiveDismissDisabled(isRunning)
        .animation(.smooth, value: phase)
        .sensoryFeedback(trigger: phase) { _, new in
            switch new {
            case .succeeded: .success
            case .failed: .error
            case .running: nil
            }
        }
        .onAppear { if expandActivityInitially { isActivityExpanded = true } }
    }

    private var hero: some View {
        VStack(spacing: Spacing.m) {
            switch phase {
            case .running:
                StatusSymbol(systemImage: "arrow.triangle.2.circlepath", tone: .accent, isAnimating: true)
            case .succeeded:
                StatusSymbol(systemImage: "checkmark", tone: .success)
            case .failed:
                StatusSymbol(systemImage: "xmark", tone: .critical)
            }
            VStack(spacing: Spacing.xs) {
                Text(headline)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(appName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The stage summary reads as the headline ("Signing your app", "Your app was refreshed").
    private var headline: String {
        stageSummary.hasSuffix(".") ? String(stageSummary.dropLast()) : stageSummary
    }

    private func failureCard(_ explanation: OperationFailureExplanation) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(explanation.summary)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if let advice = explanation.advice {
                Text(advice)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if explanation.hasTechnicalDetail {
                DisclosureGroup("Technical Details", isExpanded: $isTechnicalExpanded) {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Text(explanation.technicalDetail)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        copyButton(explanation.technicalDetail)
                    }
                    .padding(.top, Spacing.xs)
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 12, style: .continuous))
    }

    private var activity: some View {
        DisclosureGroup("Activity", isExpanded: $isActivityExpanded) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(line.contains("ERROR") ? Color.red : Color.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                copyButton(lines.joined(separator: "\n"))
            }
            .textSelection(.enabled)
            .padding(.top, Spacing.xs)
        }
        .font(.subheadline.weight(.semibold))
        .tint(.secondary)
    }

    private func copyButton(_ text: String) -> some View {
        SwiftUI.Button {
            UIPasteboard.general.string = text
            didCopy = true
        } label: {
            Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                .font(.footnote.weight(.semibold))
        }
        .buttonStyle(.borderless)
        .tint(.sideKickAccent)
    }

    @ViewBuilder
    private var actions: some View {
        if failure != nil {
            SwiftUI.Button(action: onRetry) {
                ActionLabel("Try Again", systemImage: "arrow.clockwise")
            }
            .primaryActionStyle()

            HStack(spacing: Spacing.l) {
                if explanation?.suggestsReconnect == true, let account, let accountStore {
                    NavigationLink {
                        SigningAccountDetailView(account: account, accountStore: accountStore, forceReconnect: true)
                    } label: {
                        Text("Reconnect Account")
                    }
                }
                SwiftUI.Button("Close", action: onClose)
            }
            .font(.body.weight(.semibold))
            .tint(.sideKickAccent)
            .frame(minHeight: 44)
        } else {
            SwiftUI.Button(action: onClose) {
                ActionLabel("Done")
            }
            .primaryActionStyle()
        }
    }
}

private enum OperationPhase: Equatable { case running, succeeded, failed }

/// Four-segment progress, Blank Street style. Fine-grained percentage stays in the accessibility value.
private struct StageTracker: View {
    let stages: [String]
    let progress: Double
    let failed: Bool

    var body: some View {
        let count = max(stages.count, 1)
        let reached = min(Int((min(max(progress, 0), 1) * Double(count)).rounded(.down)), count)
        HStack(alignment: .top, spacing: Spacing.xs) {
            ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                let isDone = index < reached || progress >= 1
                let isCurrent = index == reached && progress < 1
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color(uiColor: .tertiarySystemFill))
                            Capsule()
                                .fill(failed && isCurrent ? Color.red : Color.sideKickAccent)
                                .frame(width: isDone ? geometry.size.width : (isCurrent ? geometry.size.width * segmentFraction(count: count, index: index) : 0))
                        }
                    }
                    .frame(height: 6)
                    Text(stage)
                        .font(.caption.weight(isCurrent || isDone ? .semibold : .regular))
                        .foregroundStyle(isCurrent || isDone ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .animation(.smooth, value: progress)
    }

    private func segmentFraction(count: Int, index: Int) -> Double {
        let value = min(max(progress, 0), 1) * Double(count) - Double(index)
        return failed ? max(value, 0.15) : min(max(value, 0.08), 1)
    }
}

/// Translates signing-pipeline failures into a plain summary and a next step.
/// The raw message is always preserved as technical detail.
struct OperationFailureExplanation {
    let summary: String
    let advice: String?
    let technicalDetail: String
    let hasTechnicalDetail: Bool
    let suggestsReconnect: Bool

    init(message: String) {
        let lower = message.lowercased()
        technicalDetail = message
        suggestsReconnect = ["apple id", "apple account", "session", "credential", "sign in", "authentication", "password", "two-factor"]
            .contains { lower.contains($0) }

        if lower.contains("placeholder") || lower.contains("required prefix") || lower.contains("mismatched bundle") {
            summary = "This app’s extensions don’t match its new bundle ID."
            advice = "iOS rejected the install because an extension kept its old identifier. Try again; if it repeats, remove the app’s extensions in Install & Signing or install a fresh IPA."
        } else if lower.contains("app group") || lower.contains("shared backup") {
            summary = "This build is missing SideKick’s shared storage permission."
            advice = "Nothing was replaced. Install a SideKick build that keeps App Groups, then try again."
        } else if lower.contains("maximum") && lower.contains("app id") || lower.contains("app id limit") {
            summary = "This Apple Account has no App IDs left."
            advice = "Free accounts allow 10 App IDs per week. Wait for older ones to expire, or use another account."
        } else if lower.contains("certificate") && (lower.contains("revoked") || lower.contains("limit") || lower.contains("maximum")) {
            summary = "The signing certificate isn’t available."
            advice = "Review certificates for this account in Accounts, then try again."
        } else if lower.contains("vpn") || lower.contains("tunnel") || lower.contains("heartbeat") || lower.contains("minimuxer") || lower.contains("connection refused") || lower.contains("pairing") {
            summary = "SideKick couldn’t reach this iPhone."
            advice = "Turn on your local connection and check the pairing file in Settings → Connection, then try again."
        } else if suggestsReconnect {
            summary = "This Apple Account needs to sign in again."
            advice = "Reconnect the account, then try again."
        } else {
            let firstLine = message.split(separator: "\n").first.map(String.init) ?? message
            summary = firstLine.count <= 160 ? firstLine : "Something went wrong while signing this app."
            advice = nil
        }
        hasTechnicalDetail = summary != message
    }
}

private struct RefreshConsoleView: View {
    let app: InstalledAppSummary
    let accountStore: SigningAccountStore
    var selectedAccount: SigningAccountSummary? = nil
    var selectedCertificate: ImportedCertificateRecord? = nil
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
        stageSummary = operation == .refresh ? "Refreshing \(app.name)" : "Re-signing \(app.name)"
        append("Starting \(operation == .refresh ? "refresh" : "re-sign") · \(Date.now.formatted(date: .omitted, time: .standard))")
        append("Signing identity · \(selectedCertificate?.name ?? selectedAccount?.email ?? app.accountEmail)")
        append(operation == .refresh ? "Preparing signing refresh" : "Preparing app re-sign")
        do {
            let service = SideStoreOperationService(accountStore: accountStore, ipaStore: environment.ipaImportStore)
            if operation == .resign {
                if let selectedCertificate {
                    try await service.resign(bundleIdentifier: app.id, using: selectedCertificate) { updateProgress($0) }
                } else if let selectedAccount {
                    try await service.resign(bundleIdentifier: app.id, using: selectedAccount) { updateProgress($0) }
                } else { throw AppSigningError.accountRequired }
            } else {
                try await service.refresh(bundleIdentifier: app.id, using: selectedAccount) { value in
                    updateProgress(value)
                }
            }
            progress = 1
            stageSummary = operation == .refresh ? "\(app.name) is refreshed" : "\(app.name) is re-signed"
            append(operation == .refresh ? "Refresh completed successfully" : "Re-sign completed successfully")
            await ExpirationNotificationScheduler.update()
        } catch {
            failure = AnisetteErrorHint.message(for: error)
            stageSummary = operation == .refresh ? "Couldn’t refresh \(app.name)" : "Couldn’t re-sign \(app.name)"
            append("ERROR · \(error.localizedDescription)")
        }
        isRunning = false
    }

    @MainActor
    private func updateProgress(_ value: Double) {
        progress = min(max(value, 0), 1)
        if value > 0 {
            let summary = progress < 0.75 ? "Signing \(app.name)" : "Installing \(app.name)"
            if summary != stageSummary {
                stageSummary = summary
                append(summary)
            }
        }
    }

    @MainActor
    private func append(_ message: String) {
        lines.append("[\(Date.now.formatted(date: .omitted, time: .standard))] \(message)")
    }

    private var reconnectAccount: SigningAccountSummary? {
        if selectedCertificate != nil || (selectedAccount == nil && app.importedCertificate != nil) { return nil }
        return selectedAccount ?? accountStore.accounts.first {
            $0.accountIdentifier == app.accountIdentifier && $0.teamIdentifier == app.teamIdentifier
        }
    }

    @MainActor
    private func retry() {
        progress = 0
        lastLoggedPercent = -5
        stageSummary = operation == .refresh ? "Refreshing \(app.name)" : "Re-signing \(app.name)"
        isRunning = true
        Task { await runRefresh() }
    }
}

struct ResignOptionsView: View {
    let app: InstalledAppSummary
    let accountStore: SigningAccountStore

    private var eligibleAccounts: [SigningAccountSummary] {
        accountStore.accounts
    }

    var body: some View {
        List {
            if eligibleAccounts.isEmpty {
                Section {
                    Text("Apple Accounts can also sign apps. Certificates are listed below.")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Apple Account")
                } footer: {
                    Text("Re-signing keeps the app’s team and replaces its certificate.")
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
                            AccountChoiceRow(account: account, currentTeamIdentifier: app.teamIdentifier)
                        }
                    }
                } header: {
                    Text("Apple Account")
                } footer: {
                    Text("An account on another team installs a separate copy with its own data.")
                }
            }
            Section("Certificates") {
                ForEach(ImportedCertificateStore.shared.certificates) { certificate in
                    NavigationLink {
                        if certificate.profile == nil {
                            ImportedCertificateDetailView(record: certificate, accountStore: accountStore)
                        } else {
                            RefreshConsoleView(app: app, accountStore: accountStore,
                                selectedCertificate: certificate, operation: .resign)
                        }
                    } label: {
                        ImportedCertificateRow(record: certificate, usageCount: 0)
                    }
                    .disabled(certificate.profile.map { $0.teamIdentifier != app.teamIdentifier } ?? false)
                }
                NavigationLink("Manage Certificates") { ImportedCertificatesView() }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Re-sign")
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
                    Text("No saved Apple Accounts. Certificates are listed below.")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Apple Account")
                } footer: {
                    Text("Refreshing keeps the app’s current team.")
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
                            AccountChoiceRow(account: account, currentTeamIdentifier: app.teamIdentifier)
                        }
                    }
                } header: {
                    Text("Apple Account")
                } footer: {
                    Text("An account on another team installs a separate copy with its own data.")
                }
            }
            if let certificate = app.importedCertificate {
                Section("Certificate") {
                    NavigationLink {
                        RefreshConsoleView(app: app, accountStore: accountStore, selectedCertificate: certificate)
                    } label: {
                        ImportedCertificateRow(record: certificate, usageCount: 0)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Refresh with Signing Identity")
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
                Label("Open \(app.name)", systemImage: "1.circle")
                Label("Come back and tap Enable JIT", systemImage: "2.circle")
                Label("Keep \(app.name) running in the background", systemImage: "3.circle")
            } header: {
                Text("Steps")
            }

            if let statusMessage {
                Section {
                    Label(statusMessage, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            Section {
                NavigationLink {
                    SideJITServerConfigView()
                } label: {
                    Label("JIT Server", systemImage: "desktopcomputer")
                }
            } footer: {
                Text("Some iOS versions need SideJITServer running on a computer on the same network.")
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            BottomActionBar {
                SwiftUI.Button {
                    Task { await enableJIT() }
                } label: {
                    ActionLabel(isWorking ? "Connecting…" : "Enable JIT", systemImage: "bolt.fill", isWorking: isWorking)
                }
                .primaryActionStyle()
                .disabled(isWorking)
            }
        }
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

/// One row design for every account picker: email, team and a clear state when a choice
/// reconnects the account or installs a separate copy.
private struct AccountChoiceRow: View {
    let account: SigningAccountSummary
    let currentTeamIdentifier: String?

    var body: some View {
        HStack(spacing: Spacing.s) {
            AccountAvatar(kind: .apple, id: account.email)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(account.email)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(account.hasSavedSession ? "\(account.teamName) · \(account.teamType)" : "Sign in required")
                    .font(.subheadline)
                    .foregroundStyle(account.hasSavedSession ? Color.secondary : Color.orange)
            }
            Spacer(minLength: 0)
            if account.hasSavedSession, let currentTeamIdentifier, currentTeamIdentifier != account.teamIdentifier {
                StatusBadge(title: "Separate copy", systemImage: "square.on.square", tone: .neutral)
            }
        }
        .padding(.vertical, Spacing.xxs)
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
                    Text("Add an Apple Account or choose a certificate below.").foregroundStyle(.secondary)
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
                        AccountChoiceRow(account: account, currentTeamIdentifier: currentTeamIdentifier)
                    }
                }
            } header: {
                Text("Apple Account")
            } footer: {
                Text("An account on another team installs a separate copy with its own data.")
            }
            Section("Certificates") {
                ForEach(ImportedCertificateStore.shared.certificates) { certificate in
                    NavigationLink {
                        if certificate.profile == nil {
                            ImportedCertificateDetailView(record: certificate, accountStore: accountStore)
                        } else {
                            InstallConsoleView(app: app, account: nil, accountStore: accountStore,
                                ipaStore: ipaStore, isUpdate: isUpdate, onInstalled: onInstalled,
                                onSourceMissing: onSourceMissing, certificate: certificate)
                        }
                    } label: {
                        ImportedCertificateRow(record: certificate, usageCount: 0)
                    }
                    .disabled(currentTeamIdentifier.map { $0 != certificate.profile?.teamIdentifier } ?? false)
                }
                NavigationLink("Import Certificate") { ImportedCertificatesView() }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Choose Signing Identity")
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
    @Environment(AppEnvironment.self) private var environment
    let app: ImportedIPA
    let account: SigningAccountSummary?
    let accountStore: SigningAccountStore
    let ipaStore: IPAImportStore
    let isUpdate: Bool
    let onInstalled: (() async -> Void)?
    var onSourceMissing: (() async -> Void)? = nil
    var certificate: ImportedCertificateRecord? = nil

    private var signerName: String { certificate?.name ?? account?.email ?? "Signing identity" }

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
                ScrollView {
                    DetailHeader(iconData: app.iconData, title: app.name, subtitle: app.version)
                        .padding(.top, Spacing.xl)
                    Text("Signs with \(signerName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, Spacing.xs)
                }
                .frame(maxWidth: .infinity)
                .background(Color.sideKickCanvas)
                .safeAreaInset(edge: .bottom) {
                    BottomActionBar {
                        SwiftUI.Button { startState.confirm() } label: {
                            ActionLabel(isUpdate ? "Update" : "Install")
                        }
                        .primaryActionStyle()
                        SwiftUI.Button("Cancel", role: .cancel) { dismiss() }
                            .font(.body.weight(.semibold))
                            .frame(minHeight: 44)
                    }
                }
                .navigationTitle(isUpdate ? "Update" : "Install")
                .navigationBarTitleDisplayMode(.inline)
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
            title: isUpdate ? "Update" : "Install",
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
        if isUpdate { await recordPendingUpdate() }
        failure = nil
        stageSummary = isUpdate ? "Updating \(app.name)" : "Installing \(app.name)"
        append("Starting install · \(Date.now.formatted(date: .omitted, time: .standard))")
        append("Signing identity · \(signerName)")
        append(isUpdate ? "Preparing update IPA" : "Preparing imported IPA")
        do {
            let service = SideStoreOperationService(accountStore: accountStore, ipaStore: ipaStore)
            let updateProgress: @MainActor @Sendable (Double) -> Void = { fraction in
                progress = min(max(fraction, 0), 1)
                if fraction > 0 {
                    stageSummary = fraction < 0.75 ? "Signing \(app.name)" : "Installing \(app.name)"
                }
            }
            if let certificate {
                try await service.install(app, using: certificate, progressHandler: updateProgress)
            } else if let account {
                try await service.install(app, using: account, recoveryHandler: {
                    append("Retrying with the selected Apple Account")
                }, progressHandler: updateProgress)
            } else { throw AppSigningError.accountRequired }
            progress = 1
            stageSummary = isUpdate ? "\(app.name) is updated" : "\(app.name) is installed"
            append(isUpdate ? "Update completed successfully" : "Install completed successfully")
            await onInstalled?()
        } catch {
            failure = AnisetteErrorHint.message(for: error)
            stageSummary = isUpdate ? "Couldn’t update \(app.name)" : "Couldn’t install \(app.name)"
            if isUpdate { UpdateSuccessRecord.remove(bundleIdentifier: updateTargetBundleID) }
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

    private var installedTarget: InstalledAppSummary? {
        if let id = app.queuedForInstalledAppID, let match = environment.installedApps.first(where: { $0.id == id }) { return match }
        let matches = environment.installedApps.filter { $0.updateMatchingBundleIdentifiers.contains(app.bundleIdentifier.lowercased()) }
        return matches.count == 1 ? matches.first : nil
    }

    private var updateTargetBundleID: String { installedTarget?.id ?? app.bundleIdentifier }

    /// Saves old → new version (and release notes for GitHub releases) so SideKick can show
    /// "Successfully Updated" once the new version is running, even if this update replaced SideKick.
    @MainActor
    private func recordPendingUpdate() async {
        var record = UpdateSuccessRecord(
            bundleIdentifier: updateTargetBundleID,
            appName: app.name,
            oldVersion: installedTarget.map { $0.buildVersion.isEmpty || $0.buildVersion == $0.version ? $0.version : "\($0.version) (\($0.buildVersion))" } ?? "Previous version",
            newVersion: app.version,
            newBuild: app.buildVersion ?? app.version,
            iconData: app.iconData,
            startedAt: .now
        )
        let tokenID = app.githubImportConfiguration?.tokenID
        let token = try? GitHubCredentialStore().load(id: tokenID)
        if let notes = await UpdateSuccessRecord.releaseNotes(updateKey: app.githubUpdateKey, repositoryURL: app.githubRepositoryURL, token: token) {
            record.releaseTitle = notes.title
            record.releaseNotes = notes.body
        }
        record.save()
    }

    @MainActor
    private func retry() {
        progress = 0
        lastLoggedPercent = -5
        stageSummary = isUpdate ? "Updating \(app.name)" : "Installing \(app.name)"
        startState = .ready
        Task { await runInstall() }
    }
}
