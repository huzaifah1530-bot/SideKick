import SwiftUI

struct LibraryView: View {
    @State var viewModel: HomeViewModel
    @State private var query = ""

    private var filteredApps: [ImportedIPA] {
        viewModel.importedApps.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.bundleIdentifier.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if filteredApps.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? "Your library is empty" : "No matching IPAs",
                        systemImage: "square.stack.3d.up",
                        description: Text(query.isEmpty ? "Import an IPA from the Today tab to keep it here." : "Try another name or bundle identifier.")
                    )
                } else {
                    List {
                        ForEach(filteredApps) { app in
                            ImportedIPARow(app: app)
                                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .swipeActions {
                                    Button(role: .destructive) {
                                        Task { await viewModel.delete(app) }
                                    } label: {
                                        Label("Remove IPA", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.sideKickCanvas)
            .searchable(text: $query, prompt: "Search your IPA library")
            .navigationTitle("Library")
            .task { await viewModel.load() }
            .refreshable { await viewModel.load() }
        }
    }
}
