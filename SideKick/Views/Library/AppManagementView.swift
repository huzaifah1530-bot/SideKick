import SwiftUI
import UIKit

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
        List {
            Section {
                HStack(spacing: 16) {
                    appIcon
                        .frame(width: 76, height: 76)
                        .clipShape(.rect(cornerRadius: 17))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(appName)
                            .font(.title3.weight(.bold))
                        Text(importedApp.map { "Version \($0.version)" } ?? "Installed")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
            }

            Section("Details") {
                LabeledContent("Bundle ID", value: bundleIdentifier)
                    .lineLimit(2)
                    .textSelection(.enabled)
                if let importedApp {
                    LabeledContent("Imported", value: importedApp.formattedImportDate)
                }
                if let installedApp {
                    LabeledContent("Signing account", value: installedApp.accountEmail)
                    LabeledContent("Team", value: installedApp.teamIdentifier)
                }
            }

            Section {
                if let importedApp {
                    if let account = accountStore.accounts.first(where: { $0.isActive && $0.hasSavedSession }) {
                        SwiftUI.Button {
                            Task { await install(importedApp, using: account) }
                        } label: {
                            HStack {
                                if isWorking { ProgressView() }
                                else { Text("Install").fontWeight(.semibold) }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .disabled(isWorking || accountStore.isWorking)
                    } else {
                        Text("Add or select a signing account in Accounts to install this app.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if onDelete != nil {
                        SwiftUI.Button("Remove from Library", role: .destructive) {
                            Task {
                                await onDelete?()
                                dismiss()
                            }
                        }
                    }
                } else if let installedApp {
                    SwiftUI.Button {
                        Task { await refresh(installedApp) }
                        } label: {
                            HStack {
                                if isWorking { ProgressView() }
                                else { Text("Refresh").fontWeight(.semibold) }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .disabled(isWorking)
                }
            }
        }
        .listStyle(.insetGrouped)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(appName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await accountStore.reload() }
        .alert("App action failed", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            SwiftUI.Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder
    private var appIcon: some View {
        if let data = importedApp?.iconData, let icon = UIImage(data: data) {
            Image(uiImage: icon).resizable().scaledToFit()
        } else {
            Image(systemName: "app.fill")
                .font(.system(size: 34))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.blue.gradient)
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
