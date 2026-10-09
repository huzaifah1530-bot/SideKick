import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct HomeView: View {
    @State var viewModel: HomeViewModel
    @State private var showingImporter = false
    @State private var installedApps: [InstalledAppSummary] = []
    @Environment(AppEnvironment.self) private var environment

    private var capacityRows: [InstalledAppSummary] {
        var seen = Set<String>()
        return installedApps.filter { seen.insert($0.teamIdentifier).inserted }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Installed") {
                    if installedApps.isEmpty {
                        ContentUnavailableView(
                            "No installed apps yet",
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

                Section("Account capacity") {
                    if capacityRows.isEmpty {
                        Text("Add an Apple Account to see capacity.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(capacityRows, id: \.teamIdentifier) { account in
                            LabeledContent(account.accountEmail, value: account.capacityDescription)
                        }
                    }
                } footer: {
                    Text("Capacity reflects apps and App IDs recorded by SideKick. iOS doesn’t provide a reliable list of apps installed by other sideloaders.")
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
                Text("\(app.accountEmail) · Version \(app.version)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
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
