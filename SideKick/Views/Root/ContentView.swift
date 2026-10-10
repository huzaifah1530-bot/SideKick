import SwiftUI
import CoreData
import Combine

struct ContentView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    @State private var setupStatus = SetupStatus()
    @State private var connectionWarning: LocalVPNService.ConnectionWarning?
    @State private var showingConnectionSettings = false

    var body: some View {
        Group {
            if case .ready = environment.databaseState {
                if setupStatus.isReady {
                    TabView(selection: $selectedTab) {
                        HomeView(viewModel: HomeViewModel(store: environment.ipaImportStore))
                            .tabItem { Label("SideKick", systemImage: "bolt.fill") }
                            .tag(0)
                        AccountsView()
                            .tabItem { Label("Accounts", systemImage: "person.2.fill") }
                            .tag(1)
                        SettingsView()
                            .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                            .tag(2)
                    }
                } else {
                    RequiredSetupView(status: setupStatus)
                }
            } else {
                databaseStatusView
            }
        }
        .task {
            if scenePhase == .background { environment.pauseGitHubChecks() }
            else { environment.resumeGitHubChecks() }
            await environment.startDatabase()
            await setupStatus.refresh()
        }
        .task { await checkConnectionWarning() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { environment.pauseGitHubChecks() }
            guard phase == .active else { return }
            environment.resumeGitHubChecks()
            Task { await checkConnectionWarning() }
            guard case .ready = environment.databaseState else { return }
            Task {
                await environment.reloadLocalCatalogues(checkForUpdates: true)
                environment.rescanLiveContainerApps()
            }
            Task { await setupStatus.refresh() }
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
        .alert(connectionWarning?.title ?? "Local Connection", isPresented: Binding(
            get: { connectionWarning != nil },
            set: { if !$0 { connectionWarning = nil } }
        )) {
            SwiftUI.Button("Connection Settings") {
                LocalVPNService.shared.acknowledgeConnectionWarning()
                connectionWarning = nil
                showingConnectionSettings = true
            }
            SwiftUI.Button("Not Now", role: .cancel) {
                LocalVPNService.shared.acknowledgeConnectionWarning()
                connectionWarning = nil
            }
        } message: {
            Text(connectionWarning?.message ?? "")
        }
        .sheet(isPresented: $showingConnectionSettings) {
            NavigationStack {
                LocalConnectionSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            SwiftUI.Button("Done") { showingConnectionSettings = false }
                        }
                    }
            }
        }
    }

    @MainActor private func checkConnectionWarning() async {
        guard scenePhase == .active, connectionWarning == nil, !showingConnectionSettings else { return }
        let warning = await LocalVPNService.shared.connectionWarningIfNeeded()
        guard !Task.isCancelled, scenePhase == .active, connectionWarning == nil,
              !showingConnectionSettings else { return }
        connectionWarning = warning
    }

    @ViewBuilder
    private var databaseStatusView: some View {
        VStack(spacing: 18) {
            switch environment.databaseState {
            case .starting:
                ProgressView("Opening SideKick data…")
            case .failed(let message):
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.system(size: 42))
                    .foregroundStyle(.orange)
                Text("SideKick couldn’t open its local data")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("SideKick keeps its signing data in the app’s private storage. It couldn’t start the local database; no data has been reset.\n\n\(message)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                SwiftUI.Button("Try Again") {
                    Task { await environment.startDatabase() }
                }
                .buttonStyle(.bordered)
            case .ready:
                EmptyView()
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.sideKickCanvas)
    }
}
