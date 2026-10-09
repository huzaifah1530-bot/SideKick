import SwiftUI

struct LibraryView: View {
    @State var viewModel: HomeViewModel
    @State private var query = ""

    private var filteredApps: [SideloadedApp] { viewModel.apps.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) } }

    var body: some View {
        NavigationStack {
            List(filteredApps) { app in
                AppRow(app: app) { Task { await viewModel.refresh(app) } }
                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .background(Color.sideKickCanvas)
            .searchable(text: $query, prompt: "Search installed apps")
            .navigationTitle("Library")
            .task { await viewModel.load() }
        }
    }
}
