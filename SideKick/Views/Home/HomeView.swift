import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct HomeView: View {
    @State var viewModel: HomeViewModel
    @State private var showingImporter = false
    @State private var showingURLImport = false
    @State private var incomingShareURL: URL?
    @State private var ipaAwaitingUpdateChoice: ImportedIPA?
    @State private var installedApps: [InstalledAppSummary] = []
    @Environment(AppEnvironment.self) private var environment

    private var installedBundleIdentifiers: Set<String> {
        Set(installedApps.flatMap { [$0.bundleIdentifier, $0.resignedBundleIdentifier] }
            .map { $0.lowercased() })
    }

    private var filteredImportedApps: [ImportedIPA] {
        viewModel.importedApps.filter {
            !installedBundleIdentifiers.contains($0.bundleIdentifier.lowercased())
                && (viewModel.searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(viewModel.searchText)
                    || $0.bundleIdentifier.localizedCaseInsensitiveContains(viewModel.searchText))
        }
    }

    private var filteredInstalledApps: [InstalledAppSummary] {
        let matches = installedApps.filter {
            viewModel.searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(viewModel.searchText)
                || $0.bundleIdentifier.localizedCaseInsensitiveContains(viewModel.searchText)
        }
        var seenBundleIDs = Set<String>()
        return matches.filter { app in
            let identifiers = [app.bundleIdentifier, app.resignedBundleIdentifier].map { $0.lowercased() }
            guard !identifiers.contains(where: seenBundleIDs.contains) else { return false }
            identifiers.forEach { seenBundleIDs.insert($0) }
            return true
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

                if !filteredInstalledApps.isEmpty {
                    SwiftUI.Section("Installed") {
                        ForEach(filteredInstalledApps) { app in
                            NavigationLink {
                                AppManagementView(installedApp: app)
                            } label: {
                                installedAppRow(app)
                            }
                        }
                    }
                }

                if !filteredImportedApps.isEmpty {
                    SwiftUI.Section("Ready to Install") {
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
                    Menu {
                        SwiftUI.Button {
                            showingImporter = true
                        } label: {
                            Label("From Files", systemImage: "folder")
                        }
                        SwiftUI.Button {
                            incomingShareURL = nil
                            showingURLImport = true
                        } label: {
                            Label("From URL", systemImage: "link")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add App")
                }
            }
            .navigationDestination(isPresented: $showingURLImport) {
                URLImportView(initialURL: incomingShareURL) { _ in
                    await load()
                }
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    Task { await prepareImport(from: url) }
                case .failure(let error):
                    viewModel.errorMessage = error.localizedDescription
                }
            }
            .task {
                await environment.ipaImportStore.cleanupAbandonedTemporaryIPAImports()
                await load()
            }
            .task {
                if let url = SideKickShareLink.consumePendingURL() {
                    incomingShareURL = url
                    showingURLImport = true
                }
                await importPendingIPA()
            }
            .onReceive(NotificationCenter.default.publisher(for: SideKickShareLink.importNotification)) { notification in
                guard let url = SideKickShareLink.consumePendingURL()
                    ?? (notification.userInfo?[SideKickShareLink.urlKey] as? URL) else { return }
                incomingShareURL = url
                showingURLImport = true
            }
            .onReceive(NotificationCenter.default.publisher(for: SideKickIncomingIPA.importNotification)) { _ in
                Task { await importPendingIPA() }
            }
            .refreshable { await load() }
            .confirmationDialog(
                "\(ipaAwaitingUpdateChoice?.name ?? "This app") is already installed",
                isPresented: Binding(
                    get: { ipaAwaitingUpdateChoice != nil },
                    set: { if !$0 { ipaAwaitingUpdateChoice = nil } }
                ),
                titleVisibility: .visible
            ) {
                SwiftUI.Button("Queue for Update") { Task { await queuePendingUpdate() } }
                SwiftUI.Button("Cancel", role: .cancel) { ipaAwaitingUpdateChoice = nil }
            } message: {
                Text("Queue this IPA as the update for the installed app?")
            }
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

    private func importPendingIPA() async {
        if let error = SideKickIncomingIPA.consumePendingError() {
            viewModel.errorMessage = error
            return
        }
        guard let bookmark = SideKickIncomingIPA.consumePendingBookmark() else { return }
        do {
            let app = try await environment.ipaImportStore.prepareIPA(bookmarkData: bookmark)
            await handlePreparedIPA(app)
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
        await load()
    }

    private func prepareImport(from url: URL) async {
        viewModel.isImporting = true
        defer { viewModel.isImporting = false }
        do {
            let app = try await environment.ipaImportStore.prepareIPA(from: url)
            await handlePreparedIPA(app)
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }

    private func handlePreparedIPA(_ app: ImportedIPA) async {
        installedApps = await SideStoreOperationService(
            accountStore: SigningAccountStore(),
            ipaStore: environment.ipaImportStore
        ).installedApps()
        let installedIDs = Set(installedApps.flatMap { [$0.bundleIdentifier, $0.resignedBundleIdentifier] }.map { $0.lowercased() })
        guard installedIDs.contains(app.bundleIdentifier.lowercased()) else {
            await savePreparedIPA(app, update: false)
            return
        }
        ipaAwaitingUpdateChoice = app
    }

    private func queuePendingUpdate() async {
        guard let app = ipaAwaitingUpdateChoice else { return }
        ipaAwaitingUpdateChoice = nil
        await savePreparedIPA(app, update: true)
    }

    private func savePreparedIPA(_ app: ImportedIPA, update: Bool) async {
        do {
            try await environment.ipaImportStore.saveImportedIPA(app)
            viewModel.importedApps = try await environment.ipaImportStore.importedApps()
            viewModel.noticeMessage = update ? "\(app.name) is queued as an update." : "\(app.name) is ready to install."
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }
}
