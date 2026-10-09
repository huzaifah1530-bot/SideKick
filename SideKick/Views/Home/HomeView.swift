import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct HomeView: View {
    @State var viewModel: HomeViewModel
    @State private var showingImporter = false
    @State private var installedApps: [InstalledAppSummary] = []
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        NavigationStack {
            List {
                SwiftUI.Section("Managed Apps") {
                    if installedApps.isEmpty {
                        ContentUnavailableView(
                            "No apps managed yet",
                            systemImage: "square.stack.3d.up",
                            description: Text("Import an IPA from Library to get started.")
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(installedApps) { app in
                            NavigationLink {
                                AppManagementView(installedApp: app)
                            } label: {
                                installedAppRow(app)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("SideKick")
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
            .alert(viewModel.errorMessage == nil ? "Added to library" : "Couldn’t import IPA", isPresented: Binding(
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
