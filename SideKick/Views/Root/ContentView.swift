import SwiftUI

struct ContentView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var selectedTab = 0
    @State private var isConfirmingDatabaseReset = false
    @State private var recoveryError: String?
    @State private var recoveryComplete = false

    var body: some View {
        Group {
            if case .ready = environment.databaseState {
                TabView(selection: $selectedTab) {
                    HomeView(viewModel: HomeViewModel(store: environment.ipaImportStore))
                        .tabItem { Label("Today", systemImage: "square.grid.2x2.fill") }
                        .tag(0)
                    LibraryView(viewModel: HomeViewModel(store: environment.ipaImportStore))
                        .tabItem { Label("Library", systemImage: "square.stack.3d.up.fill") }
                        .tag(1)
                    AccountsView()
                        .tabItem { Label("Accounts", systemImage: "person.2.fill") }
                        .tag(2)
                    SettingsView()
                        .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                        .tag(3)
                }
            } else {
                databaseStatusView
            }
        }
        .task { await environment.startDatabase() }
        .confirmationDialog(
            "Back Up and Reset SideStore’s Database?",
            isPresented: $isConfirmingDatabaseReset,
            titleVisibility: .visible
        ) {
            SwiftUI.Button("Back Up and Reset Database", role: .destructive) {
                Task {
                    do {
                        try await environment.backUpAndResetDatabase()
                        recoveryComplete = true
                    } catch {
                        recoveryError = error.localizedDescription
                    }
                }
            }
            SwiftUI.Button("Cancel", role: .cancel) {}
        } message: {
            Text("SideKick will first copy the database files to a ZIP in Files > On My iPhone > SideKick. Resetting clears SideStore’s local app, source, and account records. Installed apps remain on your phone, but may need to be added again before they can be refreshed.")
        }
        .alert("Database recovery", isPresented: Binding(
            get: { recoveryError != nil || recoveryComplete },
            set: { if !$0 { recoveryError = nil; recoveryComplete = false } }
        )) {
            SwiftUI.Button("OK", role: .cancel) { recoveryError = nil; recoveryComplete = false }
        } message: {
            if let recoveryError {
                Text(recoveryError)
            } else if let backupURL = environment.databaseBackupURL {
                Text("A fresh database was created. The backup is at \(backupURL.lastPathComponent) in Files > On My iPhone > SideKick. Keep it until you’ve confirmed everything works.")
            }
        }
    }

    @ViewBuilder
    private var databaseStatusView: some View {
        VStack(spacing: 18) {
            switch environment.databaseState {
            case .starting:
                ProgressView("Opening SideStore data…")
            case .repairing:
                ProgressView("Backing up and repairing…")
            case .failed(let message):
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.system(size: 42))
                    .foregroundStyle(.orange)
                Text("SideStore data could not be opened")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("The crash report indicates the local database is corrupted. SideKick has blocked sign-in so it won’t crash while trying to write to it.\n\n\(message)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                SwiftUI.Button("Try Again") {
                    Task { await environment.startDatabase() }
                }
                .buttonStyle(.bordered)
                if environment.canOfferDatabaseReset {
                    SwiftUI.Button("Back Up and Reset Database", role: .destructive) {
                        isConfirmingDatabaseReset = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .ready:
                EmptyView()
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.sideKickCanvas)
    }
}
