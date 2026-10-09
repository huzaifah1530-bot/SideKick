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
            List {
                if filteredApps.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? "Your library is empty" : "No matching apps",
                        systemImage: "square.stack.3d.up",
                        description: Text(query.isEmpty ? "Import an IPA to add an app to your library." : "Try another name or bundle identifier.")
                    )
                    .listRowBackground(Color.clear)
                }

                if !filteredApps.isEmpty {
                    Section("Imported") {
                        ForEach(filteredApps) { app in
                            NavigationLink {
                                AppManagementView(importedApp: app) {
                                    await viewModel.delete(app)
                                    await load()
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
            .searchable(text: $query, prompt: "Search apps")
            .navigationTitle("Library")
            .task { await viewModel.load() }
            .refreshable { await viewModel.load() }
        }
    }
}
