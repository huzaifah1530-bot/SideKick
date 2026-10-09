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
                        Text(importedApp.map { "Version \($0.version)" } ?? installedApp.map { "Version \($0.version)" } ?? "Installed")
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
                    LabeledContent(
                        "Signing expires",
                        value: "\(installedApp.expirationDate.formatted(.relative(presentation: .numeric))) · \(installedApp.expirationDate.formatted(date: .abbreviated, time: .omitted))"
                    )
                }
            }

            Section {
                if let importedApp {
                    if accountStore.accounts.contains(where: \.hasSavedSession) {
                        NavigationLink {
                            InstallAccountSelectionView(
                                app: importedApp,
                                accounts: accountStore.accounts.filter(\.hasSavedSession),
                                accountStore: accountStore,
                                ipaStore: environment.ipaImportStore
                            )
                        } label: {
                            Text("Install")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .disabled(accountStore.isWorking)
                    } else {
                        Text("Add an Apple ID in Accounts to install this app.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if onDelete != nil {
                        SwiftUI.Button("Remove Imported IPA", role: .destructive) {
                            Task {
                                await onDelete?()
                                dismiss()
                            }
                        }
                    }
                } else if let installedApp {
                    SwiftUI.Button {
                        UIApplication.shared.open(InstalledApp.openAppURL(targetBundleIdentifier: installedApp.resignedBundleIdentifier))
                    } label: {
                        Text("Open")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)

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
        if let data = importedApp?.iconData ?? installedApp?.iconData, let icon = UIImage(data: data) {
            Image(uiImage: icon).resizable().scaledToFit()
        } else {
            Image(systemName: "app.fill")
                .font(.system(size: 34))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.blue.gradient)
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

private struct InstallAccountSelectionView: View {
    let app: ImportedIPA
    let accounts: [SigningAccountSummary]
    let accountStore: SigningAccountStore
    let ipaStore: IPAImportStore

    var body: some View {
        List {
            Section {
                ForEach(accounts) { account in
                    NavigationLink {
                        InstallConsoleView(app: app, account: account, accountStore: accountStore, ipaStore: ipaStore)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(account.email).font(.body.weight(.medium))
                            Text("\(account.teamName) · \(account.teamType)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 5)
                    }
                }
            } header: {
                Text("Apple Account")
            } footer: {
                Text("Choose the account that will sign and install \(app.name).")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Choose Account")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct InstallConsoleView: View {
    let app: ImportedIPA
    let account: SigningAccountSummary
    let accountStore: SigningAccountStore
    let ipaStore: IPAImportStore

    @Environment(\.dismiss) private var dismiss
    @State private var lines: [String] = []
    @State private var progress = 0.0
    @State private var isRunning = true
    @State private var didStart = false
    @State private var failure: String?
    @State private var lastLoggedPercent = -5

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(isRunning ? "Installing" : (failure == nil ? "Installed" : "Install Failed"))
                    .font(.largeTitle.bold())
                Text(app.name)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                ProgressView(value: progress)
                    .tint(failure == nil ? .accentColor : .red)
                Text(isRunning ? "\(Int(progress * 100))%" : (failure == nil ? "Complete" : "Needs attention"))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 9) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(line.contains("ERROR") ? .red : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(14)
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
                .onChange(of: lines.count) { _, count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }

            if let failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !isRunning {
                SwiftUI.Button(failure == nil ? "Done" : "Close") { dismiss() }
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
            }
        }
        .padding()
        .navigationTitle("Install Activity")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(isRunning ? .hidden : .visible, for: .navigationBar)
        .interactiveDismissDisabled(isRunning)
        .task {
            guard !didStart else { return }
            didStart = true
            await runInstall()
        }
    }

    @MainActor
    private func runInstall() async {
        append("Starting install · \(Date.now.formatted(date: .omitted, time: .standard))")
        append("Account selected · \(account.email)")
        append("Preparing imported IPA")
        do {
            try await SideStoreOperationService(accountStore: accountStore, ipaStore: ipaStore)
                .install(app, using: account) { fraction in
                    let clamped = min(max(fraction, 0), 1)
                    progress = clamped
                    if clamped > 0 {
                        let percent = Int(clamped * 100)
                        if percent >= lastLoggedPercent + 5 || percent == 100 {
                            lastLoggedPercent = percent
                            append("Install pipeline progress · \(percent)%")
                        }
                    }
                }
            progress = 1
            append("Install completed successfully")
        } catch {
            failure = error.localizedDescription
            append("ERROR · \(error.localizedDescription)")
        }
        isRunning = false
    }

    @MainActor
    private func append(_ message: String) {
        lines.append("[\(Date.now.formatted(date: .omitted, time: .standard))] \(message)")
    }
}
