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

struct HomeView: View {
    @State var viewModel: HomeViewModel
    @State private var showingImporter = false
    @State private var showingURLImport = false
    @State private var incomingShareURL: URL?
    @State private var ipaAwaitingUpdateChoice: ImportedIPA?
    @State private var installedApps: [InstalledAppSummary] = []
    @State private var accountStore = SigningAccountStore()
    @State private var remainingAppIDs: Int?
    @State private var isRefreshingAll = false
    @State private var refreshAllProgress: (completed: Int, total: Int)?
    @State private var guestApps: [LiveContainerGuest] = []
    @State private var githubChecks: [GitHubCheckResult] = []
    @State private var githubUpdates: [GitHubUpdateCandidate] = []
    @State private var isCheckingGitHubUpdates = false
    @State private var githubUpdateCheckFailed = false
    @State private var githubScanGeneration = UUID()
    @State private var expirationClock = Date.now
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase

    private var installedBundleIdentifiers: Set<String> {
        Set(installedApps.flatMap(\.updateMatchingBundleIdentifiers))
    }

    private var filteredImportedApps: [ImportedIPA] {
        viewModel.importedApps.filter { $0.queuedForInstalledAppID?.hasPrefix("livecontainer:") != true && !installedBundleIdentifiers.contains($0.bundleIdentifier.lowercased()) }
    }

    private var queuedManualUpdates: [QueuedManualUpdate] {
        viewModel.importedApps.compactMap { ipa in
            guard ipa.isUpdateQueued, ipa.githubUpdateKey == nil,
                  ipa.fileName?.hasPrefix("github-update-") != true,
                  let installedApp = installedApps.first(where: {
                      if let targetID = ipa.queuedForInstalledAppID { return $0.id == targetID }
                      return $0.updateMatchingBundleIdentifiers.contains(ipa.bundleIdentifier.lowercased()) && installedApps.filter { $0.updateMatchingBundleIdentifiers.contains(ipa.bundleIdentifier.lowercased()) }.count == 1
                  }) else { return nil }
            return QueuedManualUpdate(ipa: ipa, installedApp: installedApp)
        }
    }

    private var filteredInstalledApps: [InstalledAppSummary] {
        var seenBundleIDs = Set<String>()
        return installedApps.filter { app in
            guard seenBundleIDs.insert(app.id.lowercased()).inserted else { return false }
            return true
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if !githubUpdates.isEmpty || !queuedManualUpdates.isEmpty {
                    SwiftUI.Section("Updates") {
                        ForEach(queuedManualUpdates) { queuedUpdate in
                            NavigationLink {
                                AppManagementView(installedApp: queuedUpdate.installedApp)
                            } label: {
                                QueuedManualUpdateRow(update: queuedUpdate)
                            }
                            .fullWidthListSeparators()
                            .navigationLinkIndicatorVisibility(.hidden)
                        }
                        ForEach(filteredGitHubUpdates) { update in
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
                        if let attention = githubChecks.first(where: { $0.state.needsAttention }) {
                            Text(attention.detail ?? attention.state.message).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Section {
                        HStack(spacing: 9) {
                            if isCheckingGitHubUpdates { ProgressView() }
                            else if githubUpdateCheckFailed {
                                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                            } else {
                                Image(systemName: "arrow.down.circle").foregroundStyle(Color.sideKickAccentGradient)
                            }
                            Text(updateCheckStatus)
                                .font(.subheadline.weight(.medium))
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }

                if filteredInstalledApps.isEmpty && filteredImportedApps.isEmpty {
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
                            .navigationLinkIndicatorVisibility(.hidden)
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
                            .disabled(isRefreshingAll || filteredInstalledApps.isEmpty)
                        }
                    } footer: {
                        if let remainingAppIDs {
                            Text("\(remainingAppIDs) App IDs Remaining")
                                .frame(maxWidth: .infinity)
                                .multilineTextAlignment(.center)
                        }
                    }
                }

                LiveContainerLibrarySection()

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
                            .navigationLinkIndicatorVisibility(.hidden)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("My Apps")
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
                }
            }
            .navigationDestination(isPresented: $showingURLImport) {
                URLImportView(initialURL: incomingShareURL) { _ in
                    await load()
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
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await environment.ipaImportStore.cleanupAbandonedTemporaryIPAImports()
                await load()
                await loadAppIDCapacity()
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
            .onReceive(NotificationCenter.default.publisher(for: .sideKickImportedIPAsDidChange)) { _ in
                Task {
                    await viewModel.load()
                    await environment.githubUpdateDownloads.validateQueuedFiles(ipaImportStore: environment.ipaImportStore)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .sideKickGitHubSettingsDidChange)) { _ in
                Task { await load() }
            }
            .refreshable {
                await load()
                await loadAppIDCapacity()
            }
            .confirmationDialog(
                "\(ipaAwaitingUpdateChoice?.name ?? "This app") is already installed",
                isPresented: Binding(
                    get: { ipaAwaitingUpdateChoice != nil },
                    set: { if !$0 { ipaAwaitingUpdateChoice = nil } }
                )
            ) {
                ForEach(installedApps.filter { app in
                    ipaAwaitingUpdateChoice.map { app.updateMatchingBundleIdentifiers.contains($0.bundleIdentifier.lowercased()) } ?? false
                }) { installation in
                    SwiftUI.Button("Queue for \(installation.name) · \(installation.accountEmail) (\(installation.teamIdentifier))") {
                        Task { await queuePendingUpdate(for: installation.id) }
                    }
                }
                SwiftUI.Button("Cancel", role: .cancel) { ipaAwaitingUpdateChoice = nil }
            } message: {
                Text("Queue this IPA as the update for the installed app?")
            }
            .alert(viewModel.errorMessage == nil ? "IPA imported" : "Couldn’t import IPA", isPresented: Binding(
                get: { viewModel.errorMessage != nil || viewModel.noticeMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil; viewModel.noticeMessage = nil } }
            )) {
                SwiftUI.Button("OK", role: .cancel) { }
            } message: {
                Text(viewModel.errorMessage ?? viewModel.noticeMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private func installedAppRow(_ app: InstalledAppSummary) -> some View {
        HStack(spacing: 12) {
            if let data = app.iconData, let icon = UIImage(data: data) {
                Image(uiImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56, height: 56)
                    .clipShape(.rect(cornerRadius: 12))
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(.blue.gradient, in: .rect(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name).font(.body.weight(.semibold))
                Text("Version \(app.version)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 8)
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
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
    }

    private func load() async {
        expirationClock = .now
        await SideStoreOperationService.pruneUnusedCaches()
        await viewModel.load()
        await environment.githubUpdateDownloads.validateQueuedFiles(ipaImportStore: environment.ipaImportStore)
        installedApps = await SideStoreOperationService(
            accountStore: SigningAccountStore(),
            ipaStore: environment.ipaImportStore
        ).installedApps()
        expirationClock = .now
        await scanGitHubUpdates()
    }

    private var updateCheckStatus: String {
        if isCheckingGitHubUpdates { return "Checking for Updates" }
        if githubUpdateCheckFailed { return "Couldn’t Check GitHub Updates" }
        if githubChecks.contains(where: { $0.state.needsAttention }) { return "Update Tracking Needs Attention" }
        if githubChecks.contains(where: { $0.state == .skipped }) { return "Latest Builds Were Skipped" }
        if githubChecks.contains(where: { $0.state == .current }) { return "Confirmed Builds Are Current" }
        return "No Confirmed Updates"
    }

    private var filteredGitHubUpdates: [GitHubUpdateCandidate] {
        githubUpdates
    }

    private func scanGitHubUpdates() async {
        let generation = UUID()
        githubScanGeneration = generation
        isCheckingGitHubUpdates = true
        defer {
            if githubScanGeneration == generation { isCheckingGitHubUpdates = false }
        }
        let result = await GitHubUpdateScanner.scanAll(filteredInstalledApps)
        let candidates = result.candidates
        let didFailCheck = result.didFail
        guard githubScanGeneration == generation else { return }
        await environment.githubUpdateDownloads.restoreQueuedFiles(for: candidates, ipaImportStore: environment.ipaImportStore)
        guard githubScanGeneration == generation else { return }
        guestApps = (try? await environment.liveContainerStore.snapshot().apps) ?? []
        githubChecks = result.checks
        githubUpdates = candidates
        await GitHubUpdateNotificationScheduler.notify(candidates)
        githubUpdateCheckFailed = didFailCheck
    }

    private func loadAppIDCapacity() async {
        await accountStore.reload()
        let eligibleAccounts = accountStore.accounts.filter { $0.isFreeAccount && $0.hasSavedSession }
        guard !eligibleAccounts.isEmpty else {
            remainingAppIDs = nil
            return
        }

        var totalRemaining = 0
        var loadedInventoryCount = 0
        for account in eligibleAccounts {
            do {
                let inventory = try await accountStore.fetchDeveloperInventory(for: account)
                totalRemaining += max(10 - inventory.appIDs.count, 0)
                loadedInventoryCount += 1
            } catch {
                debugLog("[SideKick] Couldn’t check App ID capacity for \(account.email): \(error.localizedDescription)")
            }
        }
        remainingAppIDs = loadedInventoryCount > 0 ? totalRemaining : nil
    }

    private func refreshAllApps() async {
        guard !isRefreshingAll else { return }
        isRefreshingAll = true
        refreshAllProgress = nil
        defer {
            isRefreshingAll = false
            refreshAllProgress = nil
        }
        let service = SideStoreOperationService(accountStore: accountStore, ipaStore: environment.ipaImportStore)
        _ = await service.refreshAllManagedAppsQuietly { completed, total in
            refreshAllProgress = (completed, total)
        }
        installedApps = await service.installedApps()
        await scanGitHubUpdates()
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
        if let error = SideKickIncomingIPA.consumePendingError() {
            viewModel.errorMessage = error
            return
        }
        guard let bookmark = SideKickIncomingIPA.consumePendingBookmark() else { return }
        do {
            let app = try await environment.ipaImportStore.prepareIPA(bookmarkData: bookmark)
            await handlePreparedIPA(app)
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
        await load()
    }

    private func prepareImport(from url: URL) async {
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
        installedApps = await SideStoreOperationService(
            accountStore: SigningAccountStore(),
            ipaStore: environment.ipaImportStore
        ).installedApps()
        let installedIDs = Set(installedApps.flatMap(\.updateMatchingBundleIdentifiers))
        guard installedIDs.contains(app.bundleIdentifier.lowercased()) else {
            await savePreparedIPA(app, update: false)
            return
        }
        ipaAwaitingUpdateChoice = app
    }

    private func queuePendingUpdate(for targetID: String) async {
        guard let app = ipaAwaitingUpdateChoice else { return }
        ipaAwaitingUpdateChoice = nil
        await savePreparedIPA(app, update: true, targetID: targetID)
    }

    private func savePreparedIPA(_ app: ImportedIPA, update: Bool, targetID: String? = nil) async {
        do {
            var savedApp = app
            savedApp.isQueuedForUpdate = update
            savedApp.queuedForInstalledAppID = targetID
            try await environment.ipaImportStore.saveImportedIPA(savedApp)
            viewModel.importedApps = try await environment.ipaImportStore.importedApps()
            viewModel.noticeMessage = update ? "\(app.name) is queued as an update." : "\(app.name) is ready to install."
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }
}
