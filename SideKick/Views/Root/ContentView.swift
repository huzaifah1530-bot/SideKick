import SwiftUI

struct ContentView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var selectedTab = 0

    var body: some View {
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
    }
}
