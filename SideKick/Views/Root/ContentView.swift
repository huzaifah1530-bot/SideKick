import SwiftUI
import CoreData
import Combine
import UIKit

struct ContentView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var isForeground = false
    @State private var selectedTab = 0
    @State private var openedDownload: OpenedDownload?
    @State private var setupStatus = SetupStatus()
    @StateObject private var unsavedSettings = UnsavedSettingsCoordinator.shared

    var body: some View {
        Group {
            if case .ready = environment.databaseState {
                if setupStatus.isReady {
                    TabView(selection: Binding(get: { selectedTab }, set: { tab in
                        guard tab != selectedTab else { return }
                        unsavedSettings.requestNavigation { selectedTab = tab }
                    })) {
                        Tab("Apps", systemImage: "app.badge.checkmark", value: 0) {
                            HomeView(viewModel: HomeViewModel(store: environment.ipaImportStore))
                        }
                        Tab("Accounts", systemImage: "person.crop.circle", value: 1) {
                            AccountsView(showsNavigationStack: true)
                        }
                        Tab("Settings", systemImage: "gear", value: 2) {
                            SettingsView()
                        }
                    }
                    .refreshActivityAccessory(environment.refreshActivity) {
                        unsavedSettings.requestNavigation { selectedTab = 0 }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        ActiveDownloadsButton { id in openedDownload = OpenedDownload(id: id) }
                            .padding(.trailing, Spacing.m)
                            .padding(.bottom, 72)
                            .animation(.smooth, value: environment.githubUpdateDownloads.activeJobIDs)
                    }
                    .sheet(item: $openedDownload) { item in
                        NavigationStack {
                            downloadPage(item.id)
                                .toolbar {
                                    ToolbarItem(placement: .cancellationAction) {
                                        SwiftUI.Button("Done") { openedDownload = nil }
                                    }
                                }
                        }
                    }
                } else {
                    RequiredSetupView(status: setupStatus)
                }
            } else {
                databaseStatusView
            }
        }
        .task {
            // The shipping root is hosted by UIKit, not a SwiftUI App/Scene.
            // Its scenePhase environment can remain at the default background.
            isForeground = UIApplication.shared.applicationState != .background
            if isForeground { environment.resumeGitHubChecks() }
            else { environment.pauseGitHubChecks() }
            await environment.startDatabase()
            if case .ready = environment.databaseState { await setupStatus.refresh() }
        }
        .onAppear(perform: applyWindowTint)
        .alert("Save changes?", isPresented: $unsavedSettings.isPresented) {
            SwiftUI.Button("Save") { Task { await unsavedSettings.saveAndLeave() } }
                .keyboardShortcut(.defaultAction)
            SwiftUI.Button("Don’t Save") { unsavedSettings.discardAndLeave() }
            SwiftUI.Button("Keep Editing", role: .cancel) { unsavedSettings.stay() }
        } message: {
            Text("Your changes haven’t been saved.")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            isForeground = false
            environment.pauseGitHubChecks()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            isForeground = true
            environment.resumeGitHubChecks()
            guard case .ready = environment.databaseState else { return }
            Task {
                await environment.reloadLocalCatalogues()
                environment.rescanLiveContainerApps()
            }
            Task { await setupStatus.refresh() }
        }
        .task(id: isForeground) {
            guard isForeground else { return }
            while !Task.isCancelled {
                // Automatic checks are bounded to avoid exhausting GitHub's
                // unauthenticated quota. Explicit refresh always checks now.
                do { try await Task.sleep(for: .seconds(900)) }
                catch { return }
                guard !Task.isCancelled else { return }
                environment.requestGitHubUpdateCheck()
            }
        }
        .onChange(of: selectedTab) { _, tab in
            guard tab == 0, case .ready = environment.databaseState else { return }
            environment.rescanLiveContainerApps()
            Task { await environment.reloadLocalCatalogues() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sideKickGitHubSettingsDidChange)
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)) { _ in
                Task { await environment.gitHubSettingsChanged() }
            }
        .onReceive(NotificationCenter.default.publisher(for: .sideKickLiveContainerDidChange)) { _ in
            Task { await environment.reloadLiveContainerCatalogue() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sideKickLiveContainerCheckRequested)) { _ in
            environment.rescanLiveContainerApps()
        }
        .onReceive(NotificationCenter.default.publisher(for: GitHubUpdateNotificationRouteStore.tappedNotification)) { _ in
            unsavedSettings.requestNavigation { selectedTab = 0 }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange)
            .filter { notification in
                guard let context = notification.object as? NSManagedObjectContext,
                      context === DatabaseManager.shared.viewContext else { return false }
                if notification.userInfo?[NSInvalidatedAllObjectsKey] != nil { return true }
                return [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey].contains { key in
                    (notification.userInfo?[key] as? Set<NSManagedObject>)?.contains { $0 is InstalledApp } == true
                }
            }
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)) { _ in
                Task { await environment.reloadLocalCatalogues() }
            }
    }

    @ViewBuilder
    private func downloadPage(_ id: String) -> some View {
        if let candidate = environment.githubUpdateDownloads.candidates[id] {
            if candidate.targetKind == .liveContainer {
                LiveContainerGuestDetailView(guestID: candidate.bundleIdentifier)
            } else if let app = environment.installedApps.first(where: { $0.id == candidate.bundleIdentifier }) {
                GitHubUpdateDetailView(candidate: candidate, app: app)
            } else {
                ContentUnavailableView("App Not Found", systemImage: "app.dashed",
                    description: Text("The app this download was for is no longer installed."))
            }
        } else {
            ContentUnavailableView("Download Finished", systemImage: "checkmark.circle")
        }
    }

    /// UIKit-presented alerts, menus and share sheets read the window tint, not SwiftUI's.
    private func applyWindowTint() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows { window.tintColor = .sideKickAccent }
        }
    }

    @ViewBuilder
    private var databaseStatusView: some View {
        switch environment.databaseState {
        case .starting:
            ProgressView("Opening SideKick…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.sideKickCanvas)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn’t Open SideKick’s Data", systemImage: "externaldrive.badge.exclamationmark")
            } description: {
                VStack(spacing: Spacing.xs) {
                    Text("Nothing has been reset. Try again, or restart the app.")
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } actions: {
                SwiftUI.Button {
                    Task {
                        await environment.startDatabase()
                        if case .ready = environment.databaseState { await setupStatus.refresh() }
                    }
                } label: {
                    Text("Try Again").font(.headline).padding(.horizontal, Spacing.l)
                }
                .primaryActionStyle()
            }
            .background(Color.sideKickCanvas)
        case .ready:
            EmptyView()
        }
    }
}

private struct OpenedDownload: Identifiable {
    let id: String
}
