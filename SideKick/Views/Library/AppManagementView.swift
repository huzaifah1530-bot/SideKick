import SwiftUI

struct AppManagementView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var accountStore = SigningAccountStore()
    @State private var isWorking = false
    @State private var errorMessage: String?

    private let importedApp: ImportedIPA?
    private let installedApp: InstalledAppSummary?
    private let onDelete: (() async -> Void)?

    init(importedApp: ImportedIPA, onDelete: (() async -> Void)? = nil) {
        self.importedApp = importedApp
        self.installedApp = nil
        self.onDelete = onDelete
    }

    init(installedApp: InstalledAppSummary) {
        self.importedApp = nil
        self.installedApp = installedApp
        self.onDelete = nil
    }

    private var appName: String { importedApp?.name ?? installedApp?.name ?? "App" }
    private var bundleIdentifier: String { importedApp?.bundleIdentifier ?? installedApp?.bundleIdentifier ?? "" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                appHeader
                if let importedApp {
                    importedDetails(importedApp)
                } else if let installedApp {
                    installedDetails(installedApp)
                }
                dangerZone
            }
            .padding(20)
            .padding(.bottom, 24)
        }
        .background(Color.sideKickCanvas)
        .navigationTitle(appName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await accountStore.reload() }
        .alert("App action failed", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            SwiftUI.Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var appHeader: some View {
        HStack(spacing: 16) {
            Image(systemName: importedApp == nil ? "app.fill" : "app.dashed")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 76, height: 76)
                .background((importedApp == nil ? Color.indigo : Color.blue).gradient, in: .rect(cornerRadius: 20))
            VStack(alignment: .leading, spacing: 5) {
                Text(appName).font(.title2.weight(.bold))
                Text(importedApp == nil ? "Installed app" : "Imported IPA")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func importedDetails(_ app: ImportedIPA) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            detailRow("Version", app.version)
            detailRow("Bundle ID", app.bundleIdentifier)
            detailRow("Imported", app.formattedImportDate)

            Divider()

            Text("Install")
                .font(.title3.weight(.bold))
            if accountStore.accounts.filter(\.hasSavedSession).isEmpty {
                Label("Add an Apple ID in Accounts before installing.", systemImage: "person.crop.circle.badge.plus")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(accountStore.accounts.filter(\.hasSavedSession)) { account in
                    SwiftUI.Button {
                        Task { await install(app, using: account) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(account.email).font(.body.weight(.semibold))
                                Text(account.teamType).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.down.app.fill")
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isWorking)
                }
            }
        }
        .sectionCard()
    }

    private func installedDetails(_ app: InstalledAppSummary) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            detailRow("Bundle ID", app.bundleIdentifier)
            detailRow("Signing account", app.accountEmail)
            detailRow("Team", app.teamIdentifier)

            Divider()

            SwiftUI.Button {
                Task { await refresh(app) }
            } label: {
                Label(isWorking ? "Refreshing…" : "Refresh app", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isWorking)
        }
        .sectionCard()
    }

    private var dangerZone: some View {
        Group {
            if onDelete != nil {
                SwiftUI.Button(role: .destructive) {
                    Task {
                        await onDelete?()
                        dismiss()
                    }
                } label: {
                    Label("Remove from library", systemImage: "trash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body)
                .textSelection(.enabled)
        }
    }

    private func install(_ app: ImportedIPA, using account: SigningAccountSummary) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await SideStoreOperationService(
                accountStore: accountStore,
                ipaStore: environment.ipaImportStore
            ).install(app, using: account)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refresh(_ app: InstalledAppSummary) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await SideStoreOperationService(
                accountStore: accountStore,
                ipaStore: environment.ipaImportStore
            ).refresh(bundleIdentifier: app.bundleIdentifier)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private extension View {
    func sectionCard() -> some View {
        padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: .rect(cornerRadius: 22))
    }
}
