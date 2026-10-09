import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct HomeView: View {
    @State var viewModel: HomeViewModel
    @State private var showingImporter = false
    @State private var installedApps: [InstalledAppSummary] = []
    @Environment(AppEnvironment.self) private var environment

    private var filteredImportedApps: [ImportedIPA] {
        viewModel.importedApps.filter {
            viewModel.searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(viewModel.searchText)
                || $0.bundleIdentifier.localizedCaseInsensitiveContains(viewModel.searchText)
        }
    }

    private var filteredInstalledApps: [InstalledAppSummary] {
        installedApps.filter {
            viewModel.searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(viewModel.searchText)
                || $0.bundleIdentifier.localizedCaseInsensitiveContains(viewModel.searchText)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if filteredInstalledApps.isEmpty && filteredImportedApps.isEmpty {
                    ContentUnavailableView(
                        viewModel.searchText.isEmpty ? "Your apps appear here" : "No matching apps",
                        systemImage: "square.stack.3d.up",
                        description: Text(viewModel.searchText.isEmpty
                            ? "Import an IPA to install it, or manage apps already installed with SideKick."
                            : "Try another app name or bundle identifier.")
                    )
                    .listRowBackground(Color.clear)
                }

                if !filteredInstalledApps.isEmpty || !filteredImportedApps.isEmpty {
                    SwiftUI.Section("Ready to Install") {
                        ForEach(filteredInstalledApps) { app in
                            NavigationLink {
                                AppManagementView(installedApp: app)
                            } label: {
                                installedAppRow(app)
                            }
                        }
                        ForEach(filteredImportedApps) { app in
                            NavigationLink {
                                AppManagementView(importedApp: app) {
                                    await viewModel.delete(app)
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
            .navigationTitle("SideKick")
            .searchable(text: $viewModel.searchText, prompt: "Search apps")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SwiftUI.Button {
                        showingImporter = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Import IPA")
                }
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    Task { await viewModel.importIPA(from: url) }
                case .failure(let error):
                    viewModel.errorMessage = error.localizedDescription
                }
            }
            .task { await load() }
            .refreshable { await load() }
            .alert(viewModel.errorMessage == nil ? "IPA imported" : "Couldn’t import IPA", isPresented: Binding(
                get: { viewModel.errorMessage != nil || viewModel.noticeMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil; viewModel.noticeMessage = nil } }
            )) {
                SwiftUI.Button("OK", role: .cancel) { }
            } message: {
                Text(viewModel.errorMessage ?? viewModel.noticeMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private func installedAppRow(_ app: InstalledAppSummary) -> some View {
        HStack(spacing: 12) {
            if let data = app.iconData, let icon = UIImage(data: data) {
                Image(uiImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56, height: 56)
                    .clipShape(.rect(cornerRadius: 12))
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(.blue.gradient, in: .rect(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name).font(.body.weight(.semibold))
                Text("Version \(app.version) · \(app.expirationDate.formatted(.relative(presentation: .numeric)))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 4)
    }

    private func load() async {
        await viewModel.load()
        installedApps = await SideStoreOperationService(
            accountStore: SigningAccountStore(),
            ipaStore: environment.ipaImportStore
        ).installedApps()
    }
}
