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

    private var filteredInstalledApps: [InstalledAppSummary] {
        installedApps.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.bundleIdentifier.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if filteredInstalledApps.isEmpty && filteredApps.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? "Your library is empty" : "No matching apps",
                        systemImage: "square.stack.3d.up",
                        description: Text(query.isEmpty ? "Import an IPA to add an app to your library." : "Try another name or bundle identifier.")
                    )
                    .listRowBackground(Color.clear)
                }

                if !filteredInstalledApps.isEmpty {
                    Section("Installed") {
                        ForEach(filteredInstalledApps) { app in
                            NavigationLink {
                                AppManagementView(installedApp: app)
                            } label: {
                                installedAppRow(app)
                            }
                        }
                    }
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
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func installedAppRow(_ app: InstalledAppSummary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "app.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(.indigo.gradient, in: .rect(cornerRadius: 13))

            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Signed with \(app.accountEmail)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 5)
    }

    private func load() async {
        await viewModel.load()
        installedApps = await SideStoreOperationService(
            accountStore: SigningAccountStore(),
            ipaStore: environment.ipaImportStore
        ).installedApps()
    }
}
