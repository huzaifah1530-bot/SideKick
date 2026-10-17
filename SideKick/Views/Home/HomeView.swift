import SwiftUI
import UniformTypeIdentifiers
import UIKit

private enum HomeContextRoute: Hashable {
    case update(String), updateSource(String), resign(String), offload(String)
    case install(String), liveContainer(String), share(String)
}

private struct QueuedManualUpdate: Identifiable {
    let ipa: ImportedIPA
    let installedApp: InstalledAppSummary

    var id: String { installedApp.id }
}

struct HomeView: View {
    @State var viewModel: HomeViewModel
    @State private var showingImporter = false
    @State private var showingURLImport = false
    @State private var incomingShareURL: URL?
    @State private var ipaAwaitingUpdateChoice: ImportedIPA?
    @State private var isQueueingSelectedIPA = false
    @State private var matchingInstallationsForUpdateChoice: [InstalledAppSummary] = []
    @State private var accountStore = SigningAccountStore()
    @State private var isRefreshingAll = false
    @State private var refreshAllProgress: (completed: Int, total: Int)?
    @State private var refreshAllOutcome: QuietRefreshOutcome?
    @State private var showingRefreshAllResults = false
    @State private var isRetryingRefreshFailures = false
    @State private var retryRefreshProgress: (completed: Int, total: Int)?
    @State private var appRefreshErrorMessage: String?
    @State private var refreshingAppID: String?
    @State private var managementApp: InstalledAppSummary?
    @State private var showingManagementApp = false
    @State private var managementImportedApp: ImportedIPA?
    @State private var showingImportedManagement = false
    @State private var notificationNavigationPath: [GitHubUpdateNotificationRoute] = []
    @State private var isRoutingUpdateNotification = false
    @State private var expirationClock = Date.now
    @State private var ipaPendingRemoval: ImportedIPA?
    @State private var contextRoute: HomeContextRoute?
    @State private var selectedGuestID: String?
    @State private var sourceGuestID: String?
    @State private var liveContainerError: String?
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase

    private var installedApps: [InstalledAppSummary] { environment.installedApps }
    private var guestApps: [LiveContainerGuest] { environment.liveContainerState.apps }
    private var githubChecks: [GitHubCheckResult] { environment.githubChecks }
    private var githubUpdates: [GitHubUpdateCandidate] { environment.githubUpdates }
    private var hasLoadedLocalApps: Bool { environment.hasLoadedLocalApps }
    private var isLoadingLocalApps: Bool { environment.isLoadingLocalApps }
    private var localLoadError: String? { environment.localLoadError }
    private var hasUpdateSources: Bool {
        !environment.githubConfigurations.isEmpty || !githubChecks.isEmpty || environment.githubConfigurationError != nil
            || !queuedManualUpdates.isEmpty || !unresolvedQueuedManualUpdates.isEmpty
    }
    private var isImportReviewActive: Bool {
        viewModel.isImporting || ipaAwaitingUpdateChoice != nil || isQueueingSelectedIPA
    }

    private var installedBundleIdentifiers: Set<String> {
        Set(installedApps.flatMap(\.updateMatchingBundleIdentifiers))
    }

    private var filteredImportedApps: [ImportedIPA] {
        let queuedManualIPAIDs = Set(queuedManualUpdates.map(\.ipa.id) + unresolvedQueuedManualUpdates.map(\.id))
        return viewModel.importedApps.filter {
            !queuedManualIPAIDs.contains($0.id) &&
            $0.queuedForInstalledAppID?.hasPrefix("livecontainer:") != true &&
            !installedBundleIdentifiers.contains($0.bundleIdentifier.lowercased())
        }
    }

    private var manualQueuedIPAs: [ImportedIPA] {
        viewModel.importedApps.filter { ipa in
            ipa.isUpdateQueued && ipa.githubUpdateKey == nil &&
            ipa.fileName?.hasPrefix("github-update-") != true &&
            ipa.queuedForInstalledAppID?.hasPrefix("livecontainer:") != true
        }
    }

    private var queuedManualUpdates: [QueuedManualUpdate] {
        manualQueuedIPAs.compactMap { ipa in
            guard let installedApp = installedApps.first(where: {
                      if let targetID = ipa.queuedForInstalledAppID { return $0.id == targetID }
                      return $0.updateMatchingBundleIdentifiers.contains(ipa.bundleIdentifier.lowercased()) && installedApps.filter { $0.updateMatchingBundleIdentifiers.contains(ipa.bundleIdentifier.lowercased()) }.count == 1
                  }) else { return nil }
            return QueuedManualUpdate(ipa: ipa, installedApp: installedApp)
        }
    }

    private var unresolvedQueuedManualUpdates: [ImportedIPA] {
        manualQueuedIPAs.filter { ipa in
            if let targetID = ipa.queuedForInstalledAppID {
                return !installedApps.contains(where: { $0.id == targetID })
            }
            let matchingCount = installedApps.filter {
                $0.updateMatchingBundleIdentifiers.contains(ipa.bundleIdentifier.lowercased())
            }.count
            if matchingCount > 1 { return true }
            // Old records without persisted queue state remain ordinary imports when
            // no installed app matches; an explicit queue must stay visible.
            return matchingCount == 0 && ipa.isQueuedForUpdate == true
        }
    }

    private var filteredInstalledApps: [InstalledAppSummary] {
        var seenBundleIDs = Set<String>()
        return installedApps.filter { app in
            guard seenBundleIDs.insert(app.id.lowercased()).inserted else { return false }
            return app.isActive
        }
    }

    var body: some View {
        NavigationStack(path: $notificationNavigationPath) {
            List {
                if viewModel.isImporting {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Reading IPA…")
                            .font(.subheadline.weight(.medium))
                    }
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }
                if hasLoadedLocalApps, !filteredInstalledApps.isEmpty {
                    Section {
                        SigningStatusRow(
                            apps: filteredInstalledApps,
                            now: expirationClock,
                            isRefreshing: isRefreshingAll,
                            progress: refreshAllProgress,
                            isDisabled: isRefreshingAll || refreshingAppID != nil,
                            refreshAll: { Task { await refreshAllApps() } }
                        )
                        if hasUpdateSources {
                            NavigationLink {
                                GitHubUpdatesView(queuedIPAs: queuedManualUpdates.map(\.ipa) + unresolvedQueuedManualUpdates)
                            } label: {
                                GitHubUpdatesSummaryRow(queuedCount: queuedManualUpdates.count + unresolvedQueuedManualUpdates.count)
                            }
                        }
                    }
                } else if hasUpdateSources {
                    Section {
                        NavigationLink {
                            GitHubUpdatesView(queuedIPAs: queuedManualUpdates.map(\.ipa) + unresolvedQueuedManualUpdates)
                        } label: {
                            GitHubUpdatesSummaryRow(queuedCount: queuedManualUpdates.count + unresolvedQueuedManualUpdates.count)
                        }
                    }
                }

                if let localLoadError {
                    Section {
                        Label("Couldn’t Load Your Apps", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(localLoadError).font(.footnote).foregroundStyle(.secondary)
                        SwiftUI.Button("Try Again") { Task { await load() } }
                            .disabled(isLoadingLocalApps)
                    }
                } else if !hasLoadedLocalApps {
                    HStack {
                        Spacer()
                        ProgressView("Loading your apps…")
                        Spacer()
                    }
                    .padding(.vertical, 24)
                    .listRowBackground(Color.clear)
                } else if installedApps.isEmpty && filteredImportedApps.isEmpty && guestApps.isEmpty && queuedManualUpdates.isEmpty && unresolvedQueuedManualUpdates.isEmpty {
                    ContentUnavailableView {
                        Label("No Apps Yet", systemImage: "app.badge.checkmark")
                    } description: {
                        Text("Import an IPA to sign and install it on this iPhone.")
                    } actions: {
                        SwiftUI.Button { showingImporter = true } label: {
                            Text("Import from Files").font(.headline).padding(.horizontal, Spacing.m)
                        }
                        .primaryActionStyle()
                        SwiftUI.Button("Import from URL") {
                            incomingShareURL = nil
                            showingURLImport = true
                        }
                        .font(.body.weight(.semibold))
                    }
                    .listRowBackground(Color.clear)
                }

                if !filteredInstalledApps.isEmpty {
                    SwiftUI.Section {
                        ForEach(filteredInstalledApps) { app in
                            NavigationLink {
                                AppManagementView(installedApp: app)
                            } label: {
                                installedAppRow(app)
                            }
                            .contextMenu { installedAppMenu(app) }
                            .swipeActions(edge: .leading) {
                                SwiftUI.Button {
                                    Task { await refreshInstalledApp(app) }
                                } label: {
                                    Label("Refresh", systemImage: "arrow.clockwise")
                                }
                                .tint(.sideKickAccent)
                                .disabled(isRefreshingAll || refreshingAppID != nil)
                            }
                        }
                    } header: {
                        Text("Installed")
                    }
                }

                if installedApps.contains(where: { !$0.isActive }) {
                    SwiftUI.Section("Offloaded") {
                        ForEach(installedApps.filter { !$0.isActive }) { app in
                            NavigationLink { AppManagementView(installedApp: app) } label: {
                                SideKickLibraryAppRow(
                                    name: app.name,
                                    versionText: app.version,
                                    iconData: app.iconData,
                                    metadata: { EmptyView() },
                                    status: { Image(systemName: "icloud.and.arrow.down").foregroundStyle(.secondary).accessibilityLabel("Offloaded") }
                                )
                            }
                            .contextMenu {
                                SwiftUI.Button { contextRoute = .offload(app.id) } label: {
                                    Label("Restore App", systemImage: "arrow.down.circle")
                                }
                                copyMenuItem("Copy Bundle ID", value: app.bundleIdentifier)
                            }
                        }
                    }
                }

                if !environment.liveContainerState.connections.isEmpty || !guestApps.isEmpty {
                    LiveContainerLibrarySection(
                        selectedGuestID: $selectedGuestID,
                        sourceGuestID: $sourceGuestID,
                        actionError: $liveContainerError
                    )
                }

                if !filteredImportedApps.isEmpty {
                    SwiftUI.Section("Ready to Install") {
                        ForEach(filteredImportedApps) { app in
                            NavigationLink {
                                AppManagementView(importedApp: app) {
                                    await viewModel.delete(app)
                                }
                            } label: {
                                ImportedIPARow(app: app)
                            }
                            .contextMenu {
                                SwiftUI.Button { contextRoute = .install(app.id) } label: {
                                    Label("Install…", systemImage: "arrow.down.circle")
                                }
                                .disabled(accountStore.accounts.isEmpty)
                                SwiftUI.Button { contextRoute = .liveContainer(app.id) } label: {
                                    Label("Install in LiveContainer…", systemImage: "square.stack.3d.up")
                                }
                                SwiftUI.Button { contextRoute = .share(app.id) } label: {
                                    Label("Share IPA…", systemImage: "square.and.arrow.up")
                                }
                                copyMenuItem("Copy Bundle ID", value: app.bundleIdentifier)
                                Divider()
                                SwiftUI.Button(role: .destructive) {
                                    ipaPendingRemoval = app
                                } label: {
                                    Label("Remove IPA", systemImage: "trash")
                                }
                            }
                            .swipeActions {
                                SwiftUI.Button(role: .destructive) {
                                    ipaPendingRemoval = app
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("My Apps")
            .navigationDestination(item: $contextRoute) { route in
                contextDestination(route)
            }
            .navigationDestination(item: $selectedGuestID) { id in
                LiveContainerGuestDetailView(guestID: id)
            }
            .navigationDestination(item: $sourceGuestID) { id in
                if let guest = guestApps.first(where: { $0.id == id }) {
                    GitHubUpdateSettingsView(target: guest.updateTarget)
                }
            }
            .messageAlert("LiveContainer", message: $liveContainerError)
            .confirmationDialog(
                "Remove \(ipaPendingRemoval?.name ?? "IPA")?",
                isPresented: Binding(get: { ipaPendingRemoval != nil }, set: { if !$0 { ipaPendingRemoval = nil } }),
                titleVisibility: .visible
            ) {
                SwiftUI.Button("Remove IPA", role: .destructive) {
                    guard let app = ipaPendingRemoval else { return }
                    ipaPendingRemoval = nil
                    Task { await viewModel.delete(app) }
                }
            } message: {
                Text("This removes the imported IPA from SideKick.")
            }
            .navigationDestination(for: GitHubUpdateNotificationRoute.self) { route in
                notificationUpdateDestination(for: route)
            }
            .task {
                environment.rescanLiveContainerApps()
                await environment.reloadLocalCatalogues()
            }
            .task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) }
                    catch { return }
                    expirationClock = .now
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        SwiftUI.Button {
                            showingImporter = true
                        } label: {
                            Label("From Files", systemImage: "folder")
                        }
                        SwiftUI.Button {
                            incomingShareURL = nil
                            showingURLImport = true
                        } label: {
                            Label("From URL", systemImage: "link")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Import App")
                    .disabled(isImportReviewActive)
                }
            }
            .navigationDestination(isPresented: $showingURLImport) {
                URLImportView(initialURL: incomingShareURL) { _ in
                    await load()
                }
            }
            .navigationDestination(isPresented: $showingManagementApp) {
                if let managementApp {
                    AppManagementView(installedApp: managementApp)
                } else {
                    EmptyView()
                }
            }
            .navigationDestination(isPresented: $showingImportedManagement) {
                if let managementImportedApp {
                    AppManagementView(importedApp: managementImportedApp) {
                        await viewModel.delete(managementImportedApp)
                    }
                } else {
                    EmptyView()
                }
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    Task { await prepareImport(from: url) }
                case .failure(let error):
                    viewModel.errorMessage = error.localizedDescription
                }
            }
            .task { await viewModel.load() }
            .task { await openPendingUpdateNotification() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await openPendingUpdateNotification() }
                }
            }
            .task {
                if let url = SideKickShareLink.consumePendingURL() {
                    incomingShareURL = url
                    showingURLImport = true
                }
                await importPendingIPA()
            }
            .onReceive(NotificationCenter.default.publisher(for: SideKickShareLink.importNotification)) { notification in
                guard let url = SideKickShareLink.consumePendingURL()
                    ?? (notification.userInfo?[SideKickShareLink.urlKey] as? URL) else { return }
                incomingShareURL = url
                showingURLImport = true
            }
            .onReceive(NotificationCenter.default.publisher(for: SideKickIncomingIPA.importNotification)) { _ in
                Task { await importPendingIPA() }
            }
            .onChange(of: isImportReviewActive) { _, active in
                if !active { Task { await importPendingIPA() } }
            }
            .onReceive(NotificationCenter.default.publisher(for: GitHubUpdateNotificationRouteStore.tappedNotification)) { _ in
                Task { await openPendingUpdateNotification() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .sideKickImportedIPAsDidChange)) { _ in
                Task {
                    await viewModel.load()
                    await environment.githubUpdateDownloads.validateQueuedFiles(ipaImportStore: environment.ipaImportStore)
                }
            }
            .refreshable {
                await load()
                await environment.awaitPendingGitHubChecks()
            }
            .confirmationDialog(
                "\(ipaAwaitingUpdateChoice?.name ?? "This app") is already installed",
                isPresented: Binding(
                    get: { ipaAwaitingUpdateChoice != nil },
                    set: {
                        if !$0 {
                            if !isQueueingSelectedIPA, let app = ipaAwaitingUpdateChoice {
                                Task { await environment.ipaImportStore.discardPreparedIPA(app) }
                                matchingInstallationsForUpdateChoice = []
                            }
                            ipaAwaitingUpdateChoice = nil
                        }
                    }
                )
            ) {
                ForEach(matchingInstallationsForUpdateChoice) { installation in
                    SwiftUI.Button("Queue for \(installation.name) · \(installation.accountEmail) (\(installation.teamIdentifier))") {
                        guard let app = ipaAwaitingUpdateChoice else { return }
                        isQueueingSelectedIPA = true
                        Task { await queuePendingUpdate(app, for: installation.id) }
                    }
                }
                SwiftUI.Button("Cancel", role: .cancel) {
                    if let app = ipaAwaitingUpdateChoice {
                        ipaAwaitingUpdateChoice = nil
                        matchingInstallationsForUpdateChoice = []
                        Task { await environment.ipaImportStore.discardPreparedIPA(app) }
                    }
                }
            } message: {
                Text("Queue this IPA as the update for the installed app?")
            }
            .alert(appRefreshErrorMessage != nil ? "Couldn’t refresh app"
                : (viewModel.errorMessage == nil ? "IPA imported" : "Couldn’t import IPA"), isPresented: Binding(
                get: { appRefreshErrorMessage != nil || viewModel.errorMessage != nil || viewModel.noticeMessage != nil },
                set: {
                    if !$0 {
                        appRefreshErrorMessage = nil
                        viewModel.errorMessage = nil
                        viewModel.noticeMessage = nil
                    }
                }
            )) {
                SwiftUI.Button("OK", role: .cancel) { }
            } message: {
                Text(appRefreshErrorMessage ?? viewModel.errorMessage ?? viewModel.noticeMessage ?? "")
            }
            .sheet(isPresented: $showingRefreshAllResults, onDismiss: { refreshAllOutcome = nil }) {
                NavigationStack {
                    if let refreshAllOutcome {
                        RefreshAllResultsView(
                            outcome: refreshAllOutcome,
                            accountStore: accountStore,
                            isRetrying: isRetryingRefreshFailures || isRefreshingAll,
                            progress: retryRefreshProgress ?? refreshAllProgress,
                            retry: { Task { await retryRefreshFailuresOrAll() } }
                        )
                    } else {
                        ContentUnavailableView("No Refresh Results", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
    }

    // MARK: Long-press menus

    @ViewBuilder
    private func installedAppMenu(_ app: InstalledAppSummary) -> some View {
        let candidate = githubUpdates.first { $0.bundleIdentifier == app.id && $0.targetKind != .liveContainer }
        let queued = queuedManualUpdates.first { $0.installedApp.id == app.id }
        let hasSource = environment.githubConfigurations.contains { $0.id == app.id }
        let isBusy = isRefreshingAll || refreshingAppID != nil

        Section {
            SwiftUI.Button {
                UIApplication.shared.open(InstalledApp.openAppURL(targetBundleIdentifier: app.resignedBundleIdentifier))
            } label: {
                Label("Open", systemImage: "arrow.up.forward.app")
            }
            SwiftUI.Button {
                Task { await refreshInstalledApp(app) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(isBusy)
            if queued != nil || candidate != nil {
                SwiftUI.Button { contextRoute = .update(app.id) } label: {
                    Label(queued.map { "Update to \($0.ipa.version)" } ?? "Review Update", systemImage: "arrow.down.circle")
                }
            }
        }
        Section {
            if hasSource {
                SwiftUI.Button {
                    environment.requestGitHubUpdateCheck(force: true)
                } label: {
                    Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(environment.isCheckingGitHubUpdates)
            }
            SwiftUI.Button { contextRoute = .updateSource(app.id) } label: {
                Label(hasSource ? "Update Source…" : "Track GitHub Updates…", systemImage: "arrow.down.app")
            }
        }
        Section {
            SwiftUI.Button { contextRoute = .resign(app.id) } label: {
                Label("Re-sign…", systemImage: "signature")
            }
            SwiftUI.Button { contextRoute = .offload(app.id) } label: {
                Label("Offload…", systemImage: "icloud.and.arrow.up")
            }
            .disabled(isBusy)
            copyMenuItem("Copy Bundle ID", value: app.bundleIdentifier)
        }
    }

    private func copyMenuItem(_ title: String, value: String) -> some View {
        SwiftUI.Button {
            UIPasteboard.general.string = value
        } label: {
            Label(title, systemImage: "doc.on.doc")
        }
    }

    @ViewBuilder
    private func contextDestination(_ route: HomeContextRoute) -> some View {
        switch route {
        case .update(let id):
            if let queued = queuedManualUpdates.first(where: { $0.installedApp.id == id }) {
                AppManagementView(installedApp: queued.installedApp)
            } else if let app = installedApps.first(where: { $0.id == id }),
                      let candidate = githubUpdates.first(where: { $0.bundleIdentifier == id }) {
                GitHubUpdateDetailView(candidate: candidate, app: app)
            } else {
                ContentUnavailableView("Update Unavailable", systemImage: "arrow.down.circle")
            }
        case .updateSource(let id):
            if let app = installedApps.first(where: { $0.id == id }) { GitHubUpdateSettingsView(app: app) }
        case .resign(let id):
            if let app = installedApps.first(where: { $0.id == id }) {
                ResignOptionsView(app: app, accountStore: accountStore)
            }
        case .offload(let id):
            if let app = installedApps.first(where: { $0.id == id }) {
                AppOffloadView(app: app, accountStore: accountStore)
            }
        case .install(let id):
            if let ipa = viewModel.importedApps.first(where: { $0.id == id }) {
                InstallAccountSelectionView(app: ipa, accountStore: accountStore, ipaStore: environment.ipaImportStore, isUpdate: false, onInstalled: nil)
            }
        case .liveContainer(let id):
            if let ipa = viewModel.importedApps.first(where: { $0.id == id }) { LiveContainerImportView(app: ipa) }
        case .share(let id):
            if let ipa = viewModel.importedApps.first(where: { $0.id == id }) { ShareIPAView(app: ipa) }
        }
    }

    @ViewBuilder
    private func installedAppRow(_ app: InstalledAppSummary) -> some View {
        let daysRemaining = SigningExpiry.daysRemaining(until: app.expirationDate, now: expirationClock)
        SideKickLibraryAppRow(
            name: app.name,
            versionText: app.version,
            iconData: app.iconData,
            metadata: { EmptyView() },
            status: {
                if refreshingAppID == app.id {
                    ProgressView().accessibilityLabel("Refreshing")
                } else if app.expirationDate <= expirationClock {
                    StatusBadge(title: "Expired", systemImage: "xmark.circle.fill", tone: .critical)
                } else if daysRemaining <= 2 {
                    StatusBadge(
                        title: SigningExpiry.description(until: app.expirationDate, now: expirationClock).capitalizedFirst,
                        systemImage: "exclamationmark.circle.fill",
                        tone: .warning
                    )
                }
            }
        )
    }

    private func load() async {
        await environment.reloadLocalCatalogues(checkForUpdates: true)
        await viewModel.load()
        expirationClock = .now
        environment.scheduleMaintenance()
        environment.rescanLiveContainerApps()
    }

    private func openPendingUpdateNotification() async {
        guard scenePhase == .active,
              !isRoutingUpdateNotification,
              let route = GitHubUpdateNotificationRouteStore.pendingRoute() else { return }
        isRoutingUpdateNotification = true
        defer { isRoutingUpdateNotification = false }

        await environment.reloadLocalCatalogues()
        guard scenePhase == .active else { return }
        await environment.rescanLiveContainerAppsAndWait()
        environment.requestGitHubUpdateCheck(force: true)
        await environment.awaitPendingGitHubChecks()
        guard !Task.isCancelled else { return }

        notificationNavigationPath = [route]
        GitHubUpdateNotificationRouteStore.clearPendingRoute(route)
    }

    @ViewBuilder
    private func notificationUpdateDestination(for route: GitHubUpdateNotificationRoute) -> some View {
        if let check = githubChecks.first(where: { $0.targetID == route.bundleIdentifier }),
           check.state == .updateAvailable,
           githubUpdates.contains(where: {
               notificationCandidate($0, matches: route)
           }),
           route.targetKind == .liveContainer,
           let guest = guestApps.first(where: { $0.id == route.bundleIdentifier }),
           guest.isAvailable, guest.warning == nil,
           environment.liveContainerState.connections.contains(where: {
               $0.id == guest.connectionID && $0.isConnected && $0.storageKind != .snapshot && $0.error == nil
           }) {
            LiveContainerGuestDetailView(guestID: guest.id)
        } else if let check = githubChecks.first(where: { $0.targetID == route.bundleIdentifier }),
                  check.state == .updateAvailable,
                  let candidate = githubUpdates.first(where: {
                      notificationCandidate($0, matches: route)
                  }),
                  route.targetKind == .installed,
                  let app = installedApps.first(where: { $0.id == route.bundleIdentifier }) {
            GitHubUpdateDetailView(candidate: candidate, app: app)
        } else {
            ContentUnavailableView(
                "This update can’t be opened",
                systemImage: "checkmark.circle",
                description: Text("SideKick couldn’t confirm that this build is still available. The app may have been updated, removed, or its GitHub source may have changed. Return to My Apps and check again.")
            )
        }
    }

    private func notificationCandidate(_ candidate: GitHubUpdateCandidate, matches route: GitHubUpdateNotificationRoute) -> Bool {
        guard candidate.bundleIdentifier == route.bundleIdentifier,
              candidate.targetKind == route.targetKind else { return false }
        if let sourceIdentity = route.sourceIdentity {
            return candidate.sourceIdentity == sourceIdentity
        }
        // Notifications delivered by an earlier build lacked sourceIdentity;
        // only route those when the exact notified build remains current.
        return candidate.updateKey == route.updateKey
    }

    private func refreshAllApps() async {
        guard !isRefreshingAll, refreshingAppID == nil else { return }
        viewModel.errorMessage = nil
        viewModel.noticeMessage = nil
        isRefreshingAll = true
        refreshAllProgress = nil
        environment.refreshActivity = RefreshActivity(title: "Refreshing apps", completed: 0, total: filteredInstalledApps.count)
        defer {
            isRefreshingAll = false
            refreshAllProgress = nil
            environment.refreshActivity = nil
        }
        let service = SideStoreOperationService(accountStore: accountStore, ipaStore: environment.ipaImportStore)
        let result = await service.refreshAllManagedAppsQuietly { completed, total in
            refreshAllProgress = (completed, total)
            environment.refreshActivity = RefreshActivity(title: "Refreshing apps", completed: completed, total: total)
        }
        await load()
        refreshAllOutcome = result
        if result.succeeded != result.attempted || result.attempted == 0 {
            showingRefreshAllResults = true
        }
    }

    private func retryRefreshFailuresOrAll() async {
        guard !isRetryingRefreshFailures, !isRefreshingAll, refreshingAppID == nil,
              let current = refreshAllOutcome else { return }
        let failures = current.appResults.filter { !$0.succeeded }
        if failures.isEmpty {
            await refreshAllApps()
            return
        }
        isRetryingRefreshFailures = true
        retryRefreshProgress = nil
        environment.refreshActivity = RefreshActivity(title: "Retrying failed apps", completed: 0, total: failures.count)
        defer {
            isRetryingRefreshFailures = false
            retryRefreshProgress = nil
            environment.refreshActivity = nil
        }
        let retried = await SideStoreOperationService(accountStore: accountStore, ipaStore: environment.ipaImportStore)
            .retryFailedManagedApps(failures) { completed, total in
                retryRefreshProgress = (completed, total)
                environment.refreshActivity = RefreshActivity(title: "Retrying failed apps", completed: completed, total: total)
            }
        var updated = current
        let retriedByID = Dictionary(uniqueKeysWithValues: retried.map { ($0.id, $0) })
        updated.appResults = current.appResults.map { retriedByID[$0.id] ?? $0 }
        updated.succeeded = updated.appResults.filter(\.succeeded).count
        updated.attempted = updated.appResults.count
        updated.failure = updated.succeeded == updated.attempted ? nil : .appRefreshFailed
        updated.failureMessage = nil
        refreshAllOutcome = updated
        await load()
    }

    private func refreshInstalledApp(_ app: InstalledAppSummary) async {
        guard !isRefreshingAll, refreshingAppID == nil else { return }
        appRefreshErrorMessage = nil
        refreshingAppID = app.id
        defer { refreshingAppID = nil }
        do {
            try await SideStoreOperationService(accountStore: accountStore, ipaStore: environment.ipaImportStore)
                .refresh(bundleIdentifier: app.id)
        } catch {
            appRefreshErrorMessage = "Couldn’t refresh \(app.name). \(error.localizedDescription)"
        }
        await load()
    }

    private func importPendingIPA() async {
        guard !isImportReviewActive else { return }
        if let error = SideKickIncomingIPA.consumePendingError() {
            viewModel.errorMessage = error
            return
        }
        guard let bookmark = SideKickIncomingIPA.consumePendingBookmark() else { return }
        viewModel.isImporting = true
        defer { viewModel.isImporting = false }
        do {
            let app = try await environment.ipaImportStore.prepareIPA(bookmarkData: bookmark)
            await handlePreparedIPA(app)
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
        await load()
    }

    private func prepareImport(from url: URL) async {
        guard !isImportReviewActive else { return }
        viewModel.isImporting = true
        defer { viewModel.isImporting = false }
        do {
            let app = try await environment.ipaImportStore.prepareIPA(from: url)
            await handlePreparedIPA(app)
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }

    private func handlePreparedIPA(_ app: ImportedIPA) async {
        let service = SideStoreOperationService(accountStore: accountStore, ipaStore: environment.ipaImportStore)
        let currentInstallations: [InstalledAppSummary]
        do {
            currentInstallations = try await service.loadInstalledApps(loadIcons: false)
        } catch {
            matchingInstallationsForUpdateChoice = []
            await environment.ipaImportStore.discardPreparedIPA(app)
            viewModel.errorMessage = "SideKick couldn’t check installed apps before importing this IPA. Try again. \(error.localizedDescription)"
            return
        }

        let matchingInstallations = currentInstallations.filter {
            $0.updateMatchingBundleIdentifiers.contains(app.bundleIdentifier.lowercased())
        }
        guard !matchingInstallations.isEmpty else {
            matchingInstallationsForUpdateChoice = []
            await savePreparedIPA(app, update: false)
            return
        }
        matchingInstallationsForUpdateChoice = matchingInstallations
        ipaAwaitingUpdateChoice = app
    }

    private func queuePendingUpdate(_ app: ImportedIPA, for targetID: String) async {
        defer { isQueueingSelectedIPA = false }
        if ipaAwaitingUpdateChoice == app { ipaAwaitingUpdateChoice = nil }
        matchingInstallationsForUpdateChoice = []
        await savePreparedIPA(app, update: true, targetID: targetID)
    }

    private func savePreparedIPA(_ app: ImportedIPA, update: Bool, targetID: String? = nil) async {
        do {
            var savedApp = app
            savedApp.isQueuedForUpdate = update
            savedApp.queuedForInstalledAppID = targetID
            try await environment.ipaImportStore.saveImportedIPA(savedApp)
            await viewModel.load()
            viewModel.noticeMessage = update ? "\(app.name) is queued as an update." : "\(app.name) is ready to install."
        } catch {
            await environment.ipaImportStore.discardPreparedIPA(app)
            viewModel.errorMessage = error.localizedDescription
        }
    }
}

private struct RefreshAllResultsView: View {
    let outcome: QuietRefreshOutcome
    let accountStore: SigningAccountStore
    let isRetrying: Bool
    let progress: (completed: Int, total: Int)?
    let retry: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var failedResults: [ManagedAppRefreshResult] {
        outcome.appResults.filter { !$0.succeeded }
    }

    private var canRetry: Bool {
        if !failedResults.isEmpty { return true }
        if outcome.attempted == 0, case .noEligibleApps? = outcome.failure { return false }
        return outcome.failure != nil
    }

    private var summary: String {
        guard outcome.attempted > 0 else {
            switch outcome.failure {
            case .some(.noEligibleApps): return "No installed apps were available to refresh."
            case .some(.appListUnavailable): return "SideKick couldn’t load the installed apps."
            case .some(.operationUnavailable): return "Refresh couldn’t start."
            case .some(.connectionUnavailable): return "SideKick couldn’t connect to refresh the apps."
            case .some(.appRefreshFailed): return "No apps were refreshed."
            case .none: return "No apps were attempted."
            }
        }
        if outcome.succeeded == outcome.attempted {
            return "All \(outcome.attempted) apps refreshed successfully."
        }
        if outcome.succeeded == 0 {
            return "None of the \(outcome.attempted) apps refreshed successfully."
        }
        return "\(outcome.succeeded) of \(outcome.attempted) apps refreshed. Review the failures below."
    }

    var body: some View {
        List {
            Section {
                Text(summary)
                if outcome.appResults.isEmpty, let failureMessage = outcome.failureMessage {
                    Text(failureMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if isRetrying {
                    if let progress {
                        ProgressView("Retrying \(progress.completed) of \(progress.total)…")
                    } else {
                        ProgressView("Retrying failed apps…")
                    }
                }
            }

            if !outcome.appResults.isEmpty {
                Section("App Results") {
                    ForEach(outcome.appResults) { result in
                        VStack(alignment: .leading, spacing: 8) {
                            Label(result.appName,
                                systemImage: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(result.succeeded ? .green : .orange)
                            if let failureMessage = result.failureMessage, !result.succeeded {
                                Text(failureMessage)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                Text("Apple Account \(result.accountEmail) · Team \(result.teamIdentifier)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                accountRecovery(for: result)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }

            if canRetry {
                Section {
                    SwiftUI.Button {
                        retry()
                    } label: {
                        if isRetrying {
                            HStack {
                                Text("Retrying…")
                                Spacer()
                                ProgressView()
                            }
                        } else {
                            Label(failedResults.isEmpty ? "Try Again" : "Retry Failed (\(failedResults.count))",
                                systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(isRetrying)
                } footer: {
                    if !failedResults.isEmpty {
                        Text("Only the apps that failed will be retried.")
                    }
                }
            }
        }
        .navigationTitle("Refresh Results")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                SwiftUI.Button("Done") { dismiss() }
            }
        }
        .task { await accountStore.reload() }
    }

    @ViewBuilder
    private func accountRecovery(for result: ManagedAppRefreshResult) -> some View {
        if result.recovery == .localConnection {
            NavigationLink {
                LocalConnectionSettingsView()
            } label: {
                Label("Open Local Connection Settings", systemImage: "network")
            }
            .font(.footnote)
        } else if result.recovery == .account,
                  let account = accountStore.accounts.first(where: {
            $0.accountIdentifier == result.accountIdentifier && $0.teamIdentifier == result.teamIdentifier
        }) {
            NavigationLink {
                SigningAccountDetailView(account: account, accountStore: accountStore)
            } label: {
                Label(!account.hasSavedSession || account.rawTeamType == nil
                    ? "Reconnect Apple Account"
                    : "Account & Team Details", systemImage: "person.crop.circle.badge.exclamationmark")
            }
            .font(.footnote)
        } else if result.recovery == .account {
            NavigationLink {
                AccountsView()
            } label: {
                Label("Manage Apple Accounts", systemImage: "person.crop.circle.badge.plus")
            }
            .font(.footnote)
        }
    }
}

/// Answers "is anything about to expire?" and offers the one action that fixes it.
private struct SigningStatusRow: View {
    let apps: [InstalledAppSummary]
    let now: Date
    let isRefreshing: Bool
    let progress: (completed: Int, total: Int)?
    let isDisabled: Bool
    let refreshAll: () -> Void

    private var soonest: InstalledAppSummary? { apps.min { $0.expirationDate < $1.expirationDate } }
    private var soonestDays: Int { soonest.map { SigningExpiry.daysRemaining(until: $0.expirationDate, now: now) } ?? 7 }
    private var hasExpired: Bool { soonest.map { $0.expirationDate <= now } ?? false }

    private var tone: StatusTone {
        if hasExpired { return .critical }
        return soonestDays <= 2 ? .warning : .success
    }

    private var title: String {
        if isRefreshing {
            if let progress { return "Refreshing \(progress.completed) of \(progress.total)" }
            return "Refreshing apps"
        }
        if hasExpired { return "An app has expired" }
        return soonestDays <= 2 ? "An app expires soon" : "All apps signed"
    }

    private var subtitle: String {
        guard let soonest else { return "" }
        if isRefreshing { return "Keep SideKick open until this finishes" }
        if hasExpired { return "Refresh \(soonest.name) to use it again" }
        return "\(soonest.name) expires \(SigningExpiry.description(until: soonest.expirationDate, now: now))"
    }

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: tone == .success ? "checkmark.seal.fill" : "exclamationmark.circle.fill")
                .font(.title3)
                .foregroundStyle(isRefreshing ? Color.sideKickAccent : tone.color)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: Spacing.xs)
            SwiftUI.Button(action: refreshAll) {
                if isRefreshing {
                    ProgressView()
                } else {
                    Text("Refresh All").font(.subheadline.weight(.semibold))
                }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(.sideKickAccent)
            .disabled(isDisabled)
            .accessibilityLabel("Refresh All Apps")
        }
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .contain)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
