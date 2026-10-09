import SwiftUI

struct LibraryView: View {
    @State var viewModel: HomeViewModel
    @Environment(AppEnvironment.self) private var environment
    @State private var query = ""
    @State private var installedApps: [InstalledAppSummary] = []

    private var filteredApps: [ImportedIPA] {
        viewModel.importedApps.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.bundleIdentifier.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            SwiftUI.Group {
                if filteredApps.isEmpty && installedApps.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? "Your library is empty" : "No matching IPAs",
                        systemImage: "square.stack.3d.up",
                        description: Text(query.isEmpty ? "Import an IPA from the Today tab to keep it here." : "Try another name or bundle identifier.")
                    )
                } else {
                    List {
                        if !filteredApps.isEmpty {
                            Section("Imported IPAs") {
                                ForEach(filteredApps) { app in
                                    NavigationLink {
                                        AppManagementView(importedApp: app) {
                                            await viewModel.delete(app)
                                            await load()
                                        }
                                    } label: {
                                        ImportedIPARow(app: app)
                                    }
                                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                                }
                            }
                        }

                        if !installedApps.isEmpty {
                            Section("Installed Apps") {
                                ForEach(installedApps.filter {
                                    query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.bundleIdentifier.localizedCaseInsensitiveContains(query)
                                }) { app in
                                    NavigationLink {
                                        AppManagementView(installedApp: app)
                                    } label: {
                                        InstalledAppRow(app: app)
                                    }
                                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
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
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func load() async {
        await viewModel.load()
        installedApps = await SideStoreOperationService(
            accountStore: SigningAccountStore(),
            ipaStore: environment.ipaImportStore
        ).installedApps()
    }
}

private struct InstalledAppRow: View {
    let app: InstalledAppSummary

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "app.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(.indigo.gradient, in: .rect(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name).font(.headline)
                Text("Signed with \(app.accountEmail)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
        .padding(14)
        .background(.background, in: .rect(cornerRadius: 20))
    }
}
