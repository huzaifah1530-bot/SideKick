import SwiftUI
import UniformTypeIdentifiers
import UIKit

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
    @State private var githubUpdates: [GitHubUpdateCandidate] = []
    @State private var isCheckingGitHubUpdates = false
    @Environment(AppEnvironment.self) private var environment

    private var installedBundleIdentifiers: Set<String> {
        Set(installedApps.flatMap { [$0.bundleIdentifier, $0.resignedBundleIdentifier] }
            .map { $0.lowercased() })
    }

    private var filteredImportedApps: [ImportedIPA] {
        viewModel.importedApps.filter {
            !installedBundleIdentifiers.contains($0.bundleIdentifier.lowercased())
                && (viewModel.searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(viewModel.searchText)
                    || $0.bundleIdentifier.localizedCaseInsensitiveContains(viewModel.searchText))
        }
    }

    private var filteredInstalledApps: [InstalledAppSummary] {
        let matches = installedApps.filter {
            viewModel.searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(viewModel.searchText)
                || $0.bundleIdentifier.localizedCaseInsensitiveContains(viewModel.searchText)
        }
        var seenBundleIDs = Set<String>()
        return matches.filter { app in
            let identifiers = [app.bundleIdentifier, app.resignedBundleIdentifier].map { $0.lowercased() }
            guard !identifiers.contains(where: seenBundleIDs.contains) else { return false }
            identifiers.forEach { seenBundleIDs.insert($0) }
            return true
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if !githubUpdates.isEmpty {
                    SwiftUI.Section("Updates") {
                        ForEach(filteredGitHubUpdates) { update in
                            if let app = installedApps.first(where: { $0.bundleIdentifier == update.bundleIdentifier }) {
                                NavigationLink {
                                    GitHubUpdateDetailView(candidate: update, app: app)
                                } label: {
                                    GitHubUpdateRow(candidate: update, app: app)
                                }
                            }
                        }
                    }
                } else {
                    Section {
                        HStack(spacing: 9) {
                            if isCheckingGitHubUpdates { ProgressView() }
                            else { Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary) }
                            Text(isCheckingGitHubUpdates ? "Checking for Updates" : "No Updates Available")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                        }
                        .padding(.vertical, 5)
                        .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
                    }
                }

                if filteredInstalledApps.isEmpty && filteredImportedApps.isEmpty {
                    ContentUnavailableView(
                        viewModel.searchText.isEmpty ? "Your apps appear here" : "No matching apps",
                        systemImage: "square.stack.3d.up",
                        description: Text(viewModel.searchText.isEmpty
                            ? "Import an IPA to install it, or manage apps already installed with SideKick."
                            : "Try another app name or bundle identifier.")
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
                        }
                        if let remainingAppIDs {
                            HStack {
                                Spacer()
                                Text("\(remainingAppIDs) App IDs Remaining")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .listRowBackground(Color.clear)
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
                    }
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
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("My Apps")
            .searchable(text: $viewModel.searchText, prompt: "Search apps")
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
            .task {
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
            .refreshable {
                await load()
                await loadAppIDCapacity()
            }
            .confirmationDialog(
                "\(ipaAwaitingUpdateChoice?.name ?? "This app") is already installed",
                isPresented: Binding(
                    get: { ipaAwaitingUpdateChoice != nil },
                    set: { if !$0 { ipaAwaitingUpdateChoice = nil } }
                ),
                titleVisibility: .visible
            ) {
                SwiftUI.Button("Queue for Update") { Task { await queuePendingUpdate() } }
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
                Text("Version \(app.version) · \(app.expirationDate.formatted(.relative(presentation: .numeric)))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 4) {
                Text("Expires in")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(daysRemaining(for: app.expirationDate)) DAYS")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(expirationColor(for: app.expirationDate), in: .capsule)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
    }

    private func load() async {
        await viewModel.load()
        installedApps = await SideStoreOperationService(
            accountStore: SigningAccountStore(),
            ipaStore: environment.ipaImportStore
        ).installedApps()
        await scanGitHubUpdates()
    }

    private var filteredGitHubUpdates: [GitHubUpdateCandidate] {
        githubUpdates.filter {
            viewModel.searchText.isEmpty || $0.appName.localizedCaseInsensitiveContains(viewModel.searchText)
                || $0.bundleIdentifier.localizedCaseInsensitiveContains(viewModel.searchText)
        }
    }

    private func scanGitHubUpdates() async {
        isCheckingGitHubUpdates = true
        defer { isCheckingGitHubUpdates = false }
        let configurationStore = GitHubUpdateConfigurationStore()
        let service = GitHubUpdateService()
        let token = try? GitHubCredentialStore().load()
        var candidates: [GitHubUpdateCandidate] = []
        for app in filteredInstalledApps {
            let configuration: GitHubUpdateConfiguration?
            do { configuration = try await configurationStore.configuration(for: app.bundleIdentifier) }
            catch { continue }
            guard let configuration else { continue }
            do {
                if let candidate = try await service.candidate(for: app, configuration: configuration, token: token) {
                    candidates.append(candidate)
                }
            } catch {
                debugLog("[SideKick] GitHub update check failed for \(app.name): \(error.localizedDescription)")
            }
        }
        githubUpdates = candidates
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

    private func daysRemaining(for date: Date) -> Int {
        max(Int(ceil(date.timeIntervalSinceNow / 86_400)), 0)
    }

    private func expirationColor(for date: Date) -> Color {
        let days = min(max(daysRemaining(for: date), 1), 7)
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
        let installedIDs = Set(installedApps.flatMap { [$0.bundleIdentifier, $0.resignedBundleIdentifier] }.map { $0.lowercased() })
        guard installedIDs.contains(app.bundleIdentifier.lowercased()) else {
            await savePreparedIPA(app, update: false)
            return
        }
        ipaAwaitingUpdateChoice = app
    }

    private func queuePendingUpdate() async {
        guard let app = ipaAwaitingUpdateChoice else { return }
        ipaAwaitingUpdateChoice = nil
        await savePreparedIPA(app, update: true)
    }

    private func savePreparedIPA(_ app: ImportedIPA, update: Bool) async {
        do {
            try await environment.ipaImportStore.saveImportedIPA(app)
            viewModel.importedApps = try await environment.ipaImportStore.importedApps()
            viewModel.noticeMessage = update ? "\(app.name) is queued as an update." : "\(app.name) is ready to install."
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }
}
