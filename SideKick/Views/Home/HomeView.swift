import SwiftUI
import UniformTypeIdentifiers
import UIKit

private struct QueuedManualUpdate: Identifiable {
    let ipa: ImportedIPA
    let installedApp: InstalledAppSummary

    var id: String { installedApp.id }
}

private struct QueuedManualUpdateRow: View {
    let update: QueuedManualUpdate

    var body: some View {
        HStack(spacing: 12) {
            if let data = update.installedApp.iconData, let icon = UIImage(data: data) {
                Image(uiImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 50, height: 50)
                    .clipShape(.rect(cornerRadius: 11))
            } else {
                Image(systemName: "arrow.down.app.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .background(.blue.gradient, in: .rect(cornerRadius: 11))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(update.installedApp.name)
                    .font(.body.weight(.semibold))
                Text("Manual IPA · Version \(update.ipa.version)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text("QUEUED")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.blue)
        }
        .padding(.vertical, 5)
    }
}

private struct UnresolvedQueuedManualUpdateRow: View {
    let ipa: ImportedIPA
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            if let data = ipa.iconData, let icon = UIImage(data: data) {
                Image(uiImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 50, height: 50)
                    .clipShape(.rect(cornerRadius: 11))
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .background(.orange.gradient, in: .rect(cornerRadius: 11))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(ipa.name)
                    .font(.body.weight(.semibold))
                Text("Manual IPA · Version \(ipa.version)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Text("REVIEW")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        }
        .padding(.vertical, 5)
    }
}

private struct GitHubUpdateAttentionDetailView: View {
    let target: GitHubUpdateTarget
    let result: GitHubCheckResult

    var body: some View {
        Form {
            Section(target.name) {
                Text(result.state.message)
            }
            if let detail = result.detail, !detail.isEmpty {
                Section("Technical Details") {
                    Text(detail)
                        .font(.footnote)
                        .textSelection(.enabled)
                }
            }
            Section {
                NavigationLink {
                    GitHubUpdateSettingsView(target: target)
                } label: {
                    Label("Review GitHub Update Settings", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
        }
        .navigationTitle(target.name)
    }
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
    @State private var remainingAppIDs: Int?
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
    @State private var appIDCapacityTask: Task<Void, Never>?
    @State private var capacityGeneration = UUID()
    @State private var expirationClock = Date.now
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase

    private var installedApps: [InstalledAppSummary] { environment.installedApps }
    private var guestApps: [LiveContainerGuest] { environment.liveContainerState.apps }
    private var githubChecks: [GitHubCheckResult] { environment.githubChecks }
    private var githubUpdates: [GitHubUpdateCandidate] { environment.githubUpdates }
    private var isCheckingGitHubUpdates: Bool { environment.isCheckingGitHubUpdates }
    private var configuredGitHubChecks: [GitHubCheckResult] {
        githubChecks.filter { $0.checkedConfiguration != nil || $0.state == .failed }
    }
    private var configuredGitHubAttentionChecks: [GitHubCheckResult] {
        configuredGitHubChecks.filter { $0.state.needsAttention }
    }
    private var hasConfiguredGitHubSources: Bool { !configuredGitHubChecks.isEmpty }
    private var githubUpdateCheckFailed: Bool {
        configuredGitHubChecks.contains { $0.state == .failed }
    }
    private var hasLoadedLocalApps: Bool { environment.hasLoadedLocalApps }
    private var isLoadingLocalApps: Bool { environment.isLoadingLocalApps }
    private var localLoadError: String? { environment.localLoadError }
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

    private func unresolvedQueueDetail(for ipa: ImportedIPA) -> String {
        if ipa.queuedForInstalledAppID != nil {
            let hasBundleMatch = installedApps.contains {
                $0.updateMatchingBundleIdentifiers.contains(ipa.bundleIdentifier.lowercased())
            }
            return hasBundleMatch
                ? "The exact target is unavailable; a different installed copy with this bundle ID remains. SideKick won’t assume it is the queued target."
                : "The installed app this IPA targeted is no longer available."
        }
        let matchingCount = installedApps.filter {
            $0.updateMatchingBundleIdentifiers.contains(ipa.bundleIdentifier.lowercased())
        }.count
        if matchingCount == 0 {
            return "No installed app matches this queued IPA, so SideKick can’t resolve its target."
        }
        return "Multiple installed apps match this older queue entry, so its target is ambiguous."
    }

    private var filteredInstalledApps: [InstalledAppSummary] {
        var seenBundleIDs = Set<String>()
        return installedApps.filter { app in
            guard seenBundleIDs.insert(app.id.lowercased()).inserted else { return false }
            return true
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
                if !githubUpdates.isEmpty || !queuedManualUpdates.isEmpty || !unresolvedQueuedManualUpdates.isEmpty {
                    SwiftUI.Section("Updates") {
                        ForEach(queuedManualUpdates) { queuedUpdate in
                            NavigationLink {
                                AppManagementView(installedApp: queuedUpdate.installedApp)
                            } label: {
                                QueuedManualUpdateRow(update: queuedUpdate)
                            }
                            .fullWidthListSeparators()
                            .sideKickNavigationLinkIndicator()
                        }
                        ForEach(unresolvedQueuedManualUpdates) { ipa in
                            NavigationLink {
                                AppManagementView(queuedUpdate: ipa)
                            } label: {
                                UnresolvedQueuedManualUpdateRow(ipa: ipa, detail: unresolvedQueueDetail(for: ipa))
                            }
                            .fullWidthListSeparators()
                            .sideKickNavigationLinkIndicator()
                        }
                        ForEach(githubUpdates) { update in
                            if update.targetKind == .liveContainer {
                                NavigationLink { LiveContainerGuestDetailView(guestID: update.bundleIdentifier) } label: {
                                    GitHubUpdateRow(candidate: update, iconData: guestApps.first { $0.id == update.bundleIdentifier }?.iconData)
                                }
                                .fullWidthListSeparators()
                            } else if let app = installedApps.first(where: { $0.id == update.bundleIdentifier }) {
                                NavigationLink {
                                    GitHubUpdateDetailView(candidate: update, app: app)
                                } label: {
                                    GitHubUpdateRow(candidate: update, app: app)
                                }
                                .fullWidthListSeparators()
                            }
                        }
                    }
                }

                if hasConfiguredGitHubSources {
                    SwiftUI.Section("GitHub Updates") {
                        HStack(spacing: 9) {
                            if isCheckingGitHubUpdates { ProgressView() }
                            else if configuredGitHubChecks.contains(where: { $0.state.needsAttention }) {
                                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                            } else {
                                Image(systemName: "arrow.down.circle").foregroundStyle(Color.sideKickAccentGradient)
                            }
                            Text(updateCheckStatus)
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            if shouldOfferGitHubCheckAction {
                                SwiftUI.Button(githubUpdateCheckFailed ? "Retry" : "Check Now") {
                                    Task { await checkGitHubUpdatesNow() }
                                }
                                .font(.caption.weight(.semibold))
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        if isCheckingGitHubUpdates {
                            ProgressView()
                                .progressViewStyle(.linear)
                                .padding(.horizontal, 10)
                                .padding(.bottom, 8)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                        ForEach(configuredGitHubAttentionChecks, id: \.targetID) { check in
                            if let target = attentionTarget(for: check) {
                                NavigationLink {
                                    GitHubUpdateAttentionDetailView(target: target, result: check)
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(target.name).font(.subheadline.weight(.medium))
                                        Text(check.state.message)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .fullWidthListSeparators()
                            }
                        }
                    }
                }

                if let localLoadError {
                    Section {
                        Label("Couldn’t Load Your Apps", systemImage: "exclamationmark.circle")
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
                } else if filteredInstalledApps.isEmpty && filteredImportedApps.isEmpty && guestApps.isEmpty && queuedManualUpdates.isEmpty && unresolvedQueuedManualUpdates.isEmpty {
                    ContentUnavailableView(
                        "Your apps appear here",
                        systemImage: "square.stack.3d.up",
                        description: Text("Import an IPA to install it, or manage apps already installed with SideKick.")
                    )
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
                            .fullWidthListSeparators()
                            .sideKickNavigationLinkIndicator()
                            .contextMenu {
                                SwiftUI.Button {
                                    UIApplication.shared.open(InstalledApp.openAppURL(targetBundleIdentifier: app.resignedBundleIdentifier))
                                } label: {
                                    Label("Open", systemImage: "arrow.up.forward.app")
                                }
                                SwiftUI.Button {
                                    Task { await refreshInstalledApp(app) }
                                } label: {
                                    Label("Refresh Signing", systemImage: "arrow.clockwise")
                                }
                                .disabled(isRefreshingAll || refreshingAppID != nil)
                                Divider()
                                SwiftUI.Button {
                                    managementApp = app
                                    showingManagementApp = true
                                } label: {
                                    Label("More Options", systemImage: "ellipsis.circle")
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("Active")
                            Spacer()
                            SwiftUI.Button {
                                Task { await refreshAllApps() }
                            } label: {
                                if isRefreshingAll {
                                    if let refreshAllProgress {
                                        Text("\(refreshAllProgress.completed)/\(refreshAllProgress.total)")
                                    } else { ProgressView() }
                                } else {
                                    Text("Refresh All")
                                }
                            }
                            .font(.caption.weight(.medium))
                            .disabled(isRefreshingAll || refreshingAppID != nil || filteredInstalledApps.isEmpty)
                        }
                    } footer: {
                        if let remainingAppIDs {
                            Text("\(remainingAppIDs) App IDs Remaining")
                                .frame(maxWidth: .infinity)
                                .multilineTextAlignment(.center)
                        }
                    }
                }

                if !environment.liveContainerState.connections.isEmpty || !guestApps.isEmpty {
                    LiveContainerLibrarySection()
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
                            .fullWidthListSeparators()
                            .sideKickNavigationLinkIndicator()
                            .contextMenu {
                                SwiftUI.Button {
                                    managementImportedApp = app
                                    showingImportedManagement = true
                                } label: {
                                    Label("More Options", systemImage: "ellipsis.circle")
                                }
                                SwiftUI.Button(role: .destructive) {
                                    Task { await viewModel.delete(app) }
                                } label: {
                                    Label("Remove Imported IPA", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("My Apps")
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
                    .accessibilityLabel("Add App")
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
            .task { await viewModel.load(); startAppIDCapacityCheck() }
            .task { await openPendingUpdateNotification() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { cancelBackgroundChecks() }
                else if phase == .active {
                    startAppIDCapacityCheck()
                    Task { await openPendingUpdateNotification() }
                }
            }
            .onDisappear {
                cancelBackgroundChecks()
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

    @ViewBuilder
    private func installedAppRow(_ app: InstalledAppSummary) -> some View {
        SideKickLibraryAppRow(
            name: app.name,
            versionText: "Version \(app.version)",
            iconData: app.iconData,
            metadata: { EmptyView() },
            status: {
                VStack(alignment: .center, spacing: 4) {
                    Text("Expires in")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 82, alignment: .center)
                    Text("\(daysRemaining(for: app.expirationDate, now: expirationClock)) DAYS")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 82, height: 34)
                        .background(expirationColor(for: app.expirationDate, now: expirationClock).opacity(0.84), in: .capsule)
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
        guard scenePhase != .background else { return }
        startAppIDCapacityCheck()
    }

    private func startAppIDCapacityCheck() {
        appIDCapacityTask?.cancel()
        let generation = UUID()
        capacityGeneration = generation
        appIDCapacityTask = Task { await loadAppIDCapacity(generation: generation) }
    }

    private func cancelBackgroundChecks() {
        capacityGeneration = UUID()
        appIDCapacityTask?.cancel()
        appIDCapacityTask = nil
    }

    private var updateCheckStatus: String {
        let availableCount = configuredGitHubChecks.filter { $0.state == .updateAvailable }.count
        if availableCount > 0 {
            return availableCount == 1 ? "A GitHub update is available." : "\(availableCount) GitHub updates are available."
        }
        let failureCount = configuredGitHubChecks.filter { $0.state == .failed }.count
        if failureCount > 0 {
            return failureCount == 1
                ? "One GitHub update check failed. Retry the check."
                : "\(failureCount) GitHub update checks failed. Retry the checks."
        }
        if configuredGitHubAttentionChecks.count > 0 {
            return "GitHub update tracking needs attention for \(configuredGitHubAttentionChecks.count) app(s)."
        }
        if isCheckingGitHubUpdates { return "Checking GitHub for updates…" }
        if configuredGitHubChecks.contains(where: { $0.state == .skipped }) { return "The latest GitHub build was skipped." }
        if configuredGitHubChecks.contains(where: { $0.state == .current }) { return "Confirmed GitHub builds are current." }
        if configuredGitHubChecks.contains(where: { $0.state == .installedAhead }) { return "Installed builds are ahead of GitHub releases." }
        return "No confirmed GitHub updates are available."
    }

    private var shouldOfferGitHubCheckAction: Bool {
        !isCheckingGitHubUpdates && environment.hasGitHubUpdateTargets
    }

    private func checkGitHubUpdatesNow() async {
        environment.requestGitHubUpdateCheck(force: true)
        await environment.awaitPendingGitHubChecks()
    }

    private func attentionTarget(for check: GitHubCheckResult) -> GitHubUpdateTarget? {
        if let app = installedApps.first(where: { $0.id == check.targetID }) { return app.updateTarget }
        if let guest = guestApps.first(where: { $0.id == check.targetID }) { return guest.updateTarget }
        return nil
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

    private func loadAppIDCapacity(generation: UUID) async {
        defer {
            if capacityGeneration == generation { appIDCapacityTask = nil }
        }
        let capacityStore = SigningAccountStore()
        await capacityStore.reload()
        guard !Task.isCancelled, capacityGeneration == generation else { return }
        let eligibleAccounts = capacityStore.accounts.filter { $0.isFreeAccount && $0.hasSavedSession }
        guard !eligibleAccounts.isEmpty else {
            remainingAppIDs = nil
            return
        }

        var totalRemaining = 0
        var loadedInventoryCount = 0
        for account in eligibleAccounts {
            guard !Task.isCancelled, capacityGeneration == generation else { return }
            do {
                let inventory = try await capacityStore.fetchDeveloperInventory(for: account)
                totalRemaining += max(10 - inventory.appIDs.count, 0)
                loadedInventoryCount += 1
            } catch {
                guard !Task.isCancelled, capacityGeneration == generation else { return }
                debugLog("[SideKick] Couldn’t check App ID capacity for \(account.email): \(error.localizedDescription)")
            }
        }
        guard !Task.isCancelled, capacityGeneration == generation else { return }
        remainingAppIDs = loadedInventoryCount > 0 ? totalRemaining : nil
    }

    private func refreshAllApps() async {
        guard !isRefreshingAll, refreshingAppID == nil else { return }
        viewModel.errorMessage = nil
        viewModel.noticeMessage = nil
        isRefreshingAll = true
        refreshAllProgress = nil
        defer {
            isRefreshingAll = false
            refreshAllProgress = nil
        }
        let service = SideStoreOperationService(accountStore: accountStore, ipaStore: environment.ipaImportStore)
        let result = await service.refreshAllManagedAppsQuietly { completed, total in
            refreshAllProgress = (completed, total)
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
        defer {
            isRetryingRefreshFailures = false
            retryRefreshProgress = nil
        }
        let retried = await SideStoreOperationService(accountStore: accountStore, ipaStore: environment.ipaImportStore)
            .retryFailedManagedApps(failures) { completed, total in
                retryRefreshProgress = (completed, total)
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

    private func daysRemaining(for date: Date, now: Date) -> Int {
        SigningExpiry.daysRemaining(until: date, now: now)
    }

    private func expirationColor(for date: Date, now: Date) -> Color {
        let days = min(max(daysRemaining(for: date, now: now), 1), 7)
        let greenToRed = Double(days - 1) / 6
        return Color(hue: greenToRed * 0.33, saturation: 0.82, brightness: 0.86)
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
