import SwiftUI

struct ContentView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var selectedTab = 0

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
