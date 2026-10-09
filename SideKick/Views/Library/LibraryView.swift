import SwiftUI

struct LibraryView: View {
    @State var viewModel: HomeViewModel
    @Environment(AppEnvironment.self) private var environment
    @State private var query = ""
    @State private var accountStore = SigningAccountStore()
    @State private var installedApps: [InstalledAppSummary] = []
    @State private var workingID: String?
    @State private var errorMessage: String?

    private var operationService: SideStoreOperationService {
        SideStoreOperationService(accountStore: accountStore, ipaStore: environment.ipaImportStore)
    }

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
                            ImportedIPARow(app: app)
                                .overlay(alignment: .trailing) {
                                    Menu {
                                        ForEach(accountStore.accounts.filter(\.hasSavedSession)) { account in
                                            SwiftUI.Button("Install with \(account.email)") {
                                                Task { await install(app, using: account) }
                                            }
                                        }
                                        if accountStore.accounts.filter(\.hasSavedSession).isEmpty {
                                            Text("Add an Apple ID in Accounts first")
                                        }
                                    } label: {
                                        if workingID == app.id {
                                            ProgressView().padding(.trailing, 48)
                                        } else {
                                            Label("Install", systemImage: "arrow.down.app.fill")
                                                .labelStyle(.iconOnly)
                                                .font(.title3)
                                                .padding(.trailing, 48)
                                        }
                                    }
                                    .disabled(workingID != nil || accountStore.isWorking)
                                }
                                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .swipeActions {
                                    SwiftUI.Button(role: .destructive) {
                                        Task { await viewModel.delete(app) }
                                    } label: {
                                        Label("Remove IPA", systemImage: "trash")
                                    }
                                }
                                }
                            }
                        }

                        if !installedApps.isEmpty {
                            Section("Installed Apps") {
                                ForEach(installedApps.filter {
                                    query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.bundleIdentifier.localizedCaseInsensitiveContains(query)
                                }) { app in
                                    HStack(spacing: 12) {
                                        Image(systemName: "app.fill")
                                            .font(.title2).foregroundStyle(.white)
                                            .frame(width: 48, height: 48)
                                            .background(.indigo.gradient, in: .rect(cornerRadius: 12))
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(app.name).font(.headline)
                                            Text("Signed with \(app.accountEmail)").font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        SwiftUI.Button {
                                            Task { await refresh(app) }
                                        } label: {
                                            if workingID == app.id { ProgressView() }
                                            else { Image(systemName: "arrow.clockwise") }
                                        }
                                        .buttonStyle(.bordered)
                                        .disabled(workingID != nil || accountStore.isWorking)
                                        .accessibilityLabel("Refresh \(app.name)")
                                    }
                                    .padding(12)
                                    .background(.background, in: .rect(cornerRadius: 18))
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
            .alert("App operation failed", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                SwiftUI.Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func load() async {
        await viewModel.load()
        await accountStore.reload()
        installedApps = await operationService.installedApps()
    }

    private func install(_ app: ImportedIPA, using account: SigningAccountSummary) async {
        workingID = app.id
        defer { workingID = nil }
        do {
            try await operationService.install(app, using: account)
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    private func refresh(_ app: InstalledAppSummary) async {
        workingID = app.id
        defer { workingID = nil }
        do {
            try await operationService.refresh(bundleIdentifier: app.bundleIdentifier)
            await load()
        } catch { errorMessage = error.localizedDescription }
    }
}
