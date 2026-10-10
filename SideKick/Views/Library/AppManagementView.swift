import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct AppManagementView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var expirationClock = Date.now
    @State private var accountStore = SigningAccountStore()
    @State private var isShowingRefreshConsole = false
    @State private var isFindingShareIPA = false
    @State private var shareIPA: ImportedIPA?
    @State private var pendingUpdateIPA: ImportedIPA?
    @State private var errorMessage: String?
    @State private var isConfirmingQueuedUpdateRemoval = false

    private let importedApp: ImportedIPA?
    @State private var installedApp: InstalledAppSummary?
    private let onDelete: (() async -> Void)?

    init(importedApp: ImportedIPA, onDelete: (() async -> Void)? = nil) {
        self.importedApp = importedApp
        _installedApp = State(initialValue: nil)
        self.onDelete = onDelete
    }

    init(installedApp: InstalledAppSummary) {
        self.importedApp = nil
        _installedApp = State(initialValue: installedApp)
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

            if let importedApp {
                Section("Install") {
                    if !accountStore.accounts.isEmpty {
                        NavigationLink {
                            InstallAccountSelectionView(
                                app: importedApp,
                                accounts: accountStore.accounts,
                                accountStore: accountStore,
                                ipaStore: environment.ipaImportStore,
                                isUpdate: false,
                                onInstalled: nil
                            )
                        } label: {
                            Label("Install", systemImage: "arrow.down.circle")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .fullWidthListSeparators()
                        .disabled(accountStore.isWorking)
                    } else {
                        Text("Add an Apple ID in Accounts to install this app.")
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let installedApp {
                Section(pendingUpdateIPA == nil ? "Open" : "Update") {
                    if let pendingUpdateIPA {
                        queuedUpdateActions(ipa: pendingUpdateIPA, installedApp: installedApp)
                    } else {
                        SwiftUI.Button {
                            UIApplication.shared.open(InstalledApp.openAppURL(targetBundleIdentifier: installedApp.resignedBundleIdentifier))
                        } label: {
                            Text("Open")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .fullWidthListSeparators()
                    }
                }

                Section("Refresh") {
                    SwiftUI.Button {
                        isShowingRefreshConsole = true
                    } label: {
                        Text("Refresh")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .fullWidthListSeparators()

                    NavigationLink {
                        RefreshOptionsView(app: installedApp, accountStore: accountStore)
                    } label: {
                        Label("Options", systemImage: "slider.horizontal.3")
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .fullWidthListSeparators()
                }
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
                        value: "\(SigningExpiry.description(until: installedApp.expirationDate, now: expirationClock)) · \(installedApp.expirationDate.formatted(date: .abbreviated, time: .shortened))"
                    )
                }
                if let pendingUpdateIPA {
                    LabeledContent("Queued update", value: "Version \(pendingUpdateIPA.version)")
                }
            }

            Section("App Settings") {
                if let installedApp {
                    NavigationLink {
                        GitHubUpdateSettingsView(app: installedApp)
                    } label: {
                        Label("GitHub Update Source", systemImage: "chevron.left.forwardslash.chevron.right")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .fullWidthListSeparators()

                    SwiftUI.Button {
                        Task { await findIPAForSharing(installedApp) }
                    } label: {
                        HStack {
                            Label("Share IPA", systemImage: "square.and.arrow.up")
                            Spacer()
                            if isFindingShareIPA { ProgressView() }
                        }
                    }
                    .disabled(isFindingShareIPA)
                    .fullWidthListSeparators()

                    NavigationLink {
                        ResignOptionsView(app: installedApp, accountStore: accountStore)
                    } label: {
                        Label("Re-sign", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .fullWidthListSeparators()

                    NavigationLink {
                        JITEnableView(app: installedApp)
                    } label: {
                        Label("Enable JIT", systemImage: "bolt.fill")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .fullWidthListSeparators()
                } else if let importedApp {
                    NavigationLink {
                        ShareIPAView(app: importedApp)
                    } label: {
                        Label("Share IPA", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .fullWidthListSeparators()

                    if onDelete != nil {
                        SwiftUI.Button(role: .destructive) {
                            Task {
                                await onDelete?()
                                dismiss()
                            }
                        } label: {
                            Label("Remove Imported IPA", systemImage: "trash")
                        }
                        .fullWidthListSeparators()
                    }
                }
            }
            .font(.body)
        }
        .listStyle(.insetGrouped)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(appName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $shareIPA) { ipa in
            ShareIPAView(app: ipa)
        }
        .navigationDestination(isPresented: $isShowingRefreshConsole) {
            if let installedApp {
                RefreshConsoleView(app: installedApp, accountStore: accountStore)
            }
        }
        .onAppear { Task { await reloadManagementState() } }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await reloadManagementState() }
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) }
                catch { return }
                expirationClock = .now
            }
        }
        .alert("App action failed", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            SwiftUI.Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder
    private func queuedUpdateActions(ipa: ImportedIPA, installedApp: InstalledAppSummary) -> some View {
        let updateAccounts = accountStore.accounts
        if let account = updateAccounts.filter(\.hasSavedSession).first(where: {
            $0.accountIdentifier == installedApp.accountIdentifier
        }) ?? updateAccounts.first(where: \.hasSavedSession) {
            NavigationLink {
                if account.teamIdentifier != installedApp.teamIdentifier {
                    SeparateInstallReviewView(source: ipa, account: account, accountStore: accountStore, originalName: installedApp.name)
                } else {
                    InstallConsoleView(
                        app: ipa,
                        account: account,
                        accountStore: accountStore,
                        ipaStore: environment.ipaImportStore,
                        isUpdate: true,
                        onInstalled: { await finishQueuedUpdate(ipa) }
                    )
                }
            } label: {
                Label("Update", systemImage: "arrow.down.app")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .fullWidthListSeparators()

        } else {
            Text("Add the Apple account that installed this app (\(installedApp.accountEmail)) in Accounts to update it.")
                .foregroundStyle(.secondary)
        }
                NavigationLink {
                    InstallAccountSelectionView(
                        app: ipa,
                        accounts: updateAccounts,
                        accountStore: accountStore,
                        ipaStore: environment.ipaImportStore,
                        isUpdate: true,
                        onInstalled: { await finishQueuedUpdate(ipa) },
                        currentTeamIdentifier: installedApp.teamIdentifier
                    )
                } label: {
                    Label("Options", systemImage: "slider.horizontal.3")
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .fullWidthListSeparators()
        SwiftUI.Button(role: .destructive) {
            isConfirmingQueuedUpdateRemoval = true
        } label: {
            Label("Remove Queued IPA", systemImage: "trash")
        }
        .fullWidthListSeparators()
        .alert("Remove queued update?", isPresented: $isConfirmingQueuedUpdateRemoval) {
            SwiftUI.Button("Remove IPA", role: .destructive) { Task { await removeQueuedUpdate() } }
            SwiftUI.Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the queued IPA from SideKick. The installed app will remain on your device.")
        }
    }

    @MainActor
    private func finishQueuedUpdate(_ ipa: ImportedIPA) async {
        do {
            if let updateKey = ipa.githubUpdateKey,
               let repositoryURL = ipa.githubRepositoryURL {
                let store = GitHubUpdateConfigurationStore.shared
                if var configuration = try await store.configuration(for: installedApp?.id ?? bundleIdentifier),
                   configuration.repositoryURL == repositoryURL {
                    configuration.lastInstalledUpdateKey = updateKey
                    configuration.dismissedUpdateKey = nil
                    try await store.save(configuration)
                }
            }
            try await environment.ipaImportStore.delete(ipa)
            pendingUpdateIPA = nil
            await reloadManagementState()
        } catch {
            errorMessage = error.localizedDescription
        }
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

    @MainActor
    private func reloadManagementState() async {
        expirationClock = .now
        var availableInstallations: [InstalledAppSummary] = []
        if let current = installedApp {
            let service = SideStoreOperationService(accountStore: accountStore, ipaStore: environment.ipaImportStore)
            let apps = await service.installedApps()
            availableInstallations = apps
            if let latest = apps.first(where: { $0.id == current.id }) {
                installedApp = latest
            }
        }
        if let installedApp {
            let matchingBundleIDs = installedApp.updateMatchingBundleIdentifiers
            let imports = (try? await environment.ipaImportStore.importedApps()) ?? []
            pendingUpdateIPA = imports.first { ipa in
                ipa.isUpdateQueued && (ipa.queuedForInstalledAppID == installedApp.id || (ipa.queuedForInstalledAppID == nil && matchingBundleIDs.contains(ipa.bundleIdentifier.lowercased()) && availableInstallations.filter { app in app.updateMatchingBundleIdentifiers.contains(ipa.bundleIdentifier.lowercased()) }.count == 1))
            }
        }
        await accountStore.reload()
    }

    @MainActor
    private func removeQueuedUpdate() async {
        guard let pendingUpdateIPA else { return }
        do {
            try await environment.ipaImportStore.delete(pendingUpdateIPA)
            self.pendingUpdateIPA = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func findIPAForSharing(_ app: InstalledAppSummary) async {
        isFindingShareIPA = true
        defer { isFindingShareIPA = false }
        do {
            let imported = try await environment.ipaImportStore.importedApps()
            guard let sourceIPA = imported.first(where: { $0.bundleIdentifier == app.bundleIdentifier }) else {
                errorMessage = "SideKick can’t extract an IPA from an installed app. Import its original IPA into SideKick first, then share it here."
                return
            }
            shareIPA = sourceIPA
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private enum AppSigningOperation: Equatable {
    case refresh
    case resign

    var progressTitle: String { self == .refresh ? "Refreshing" : "Re-signing" }
    var completedTitle: String { self == .refresh ? "Refresh Complete" : "Re-sign Complete" }
    var failedTitle: String { self == .refresh ? "Refresh Failed" : "Re-sign Failed" }
    var activityTitle: String { self == .refresh ? "Refresh Activity" : "Re-sign Activity" }
}

private enum AppSigningError: LocalizedError {
    case accountRequired

    var errorDescription: String? {
        "Choose a saved Apple ID before re-signing this app."
    }
}

private struct RefreshConsoleView: View {
    let app: InstalledAppSummary
    let accountStore: SigningAccountStore
    var selectedAccount: SigningAccountSummary? = nil
    var operation: AppSigningOperation = .refresh

    @Environment(AppEnvironment.self) private var environment
    @State private var progress = 0.0
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [String] = []
    @State private var isRunning = true
    @State private var didStart = false
    @State private var failure: String?
    @State private var lastLoggedPercent = -5

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(isRunning ? operation.progressTitle : (failure == nil ? operation.completedTitle : operation.failedTitle))
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
        .navigationTitle(operation.activityTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(isRunning ? .hidden : .visible, for: .navigationBar)
        .interactiveDismissDisabled(isRunning)
        .task {
            guard !didStart else { return }
            didStart = true
            await runRefresh()
        }
    }

    @MainActor
    private func runRefresh() async {
        append("Starting \(operation == .refresh ? "refresh" : "re-sign") · \(Date.now.formatted(date: .omitted, time: .standard))")
        append("Account selected · \(selectedAccount?.email ?? app.accountEmail)")
        append(operation == .refresh ? "Preparing signing refresh" : "Preparing app re-sign")
        do {
            let service = SideStoreOperationService(accountStore: accountStore, ipaStore: environment.ipaImportStore)
            if operation == .resign {
                guard let selectedAccount else {
                    throw AppSigningError.accountRequired
                }
                try await service.resign(bundleIdentifier: app.id, using: selectedAccount) { value in
                    updateProgress(value)
                }
            } else {
                try await service.refresh(bundleIdentifier: app.id, using: selectedAccount) { value in
                    updateProgress(value)
                }
            }
            progress = 1
            append(operation == .refresh ? "Refresh completed successfully" : "Re-sign completed successfully")
            await ExpirationNotificationScheduler.update()
        } catch {
            failure = error.localizedDescription
            append("ERROR · \(error.localizedDescription)")
        }
        isRunning = false
    }

    @MainActor
    private func updateProgress(_ value: Double) {
        progress = min(max(value, 0), 1)
        if value > 0 {
            let percent = Int(value * 100)
            if percent >= lastLoggedPercent + 5 || percent == 100 {
                lastLoggedPercent = percent
                append("\(operation == .refresh ? "Refresh" : "Re-sign") pipeline progress · \(percent)%")
            }
        }
    }

    @MainActor
    private func append(_ message: String) {
        lines.append("[\(Date.now.formatted(date: .omitted, time: .standard))] \(message)")
    }
}

private struct ResignOptionsView: View {
    let app: InstalledAppSummary
    let accountStore: SigningAccountStore

    private var eligibleAccounts: [SigningAccountSummary] {
        accountStore.accounts
    }

    var body: some View {
        List {
            if eligibleAccounts.isEmpty {
                Section {
                    Text("Add a saved Apple ID on this app’s signing team in Accounts to re-sign it.")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Signing Account")
                } footer: {
                    Text("Re-signing keeps the app on its current team and replaces its signing certificate. A different team requires installing the app again.")
                }
            } else {
                Section {
                    ForEach(eligibleAccounts) { account in
                        NavigationLink {
                            if !account.hasSavedSession {
                                SigningAccountDetailView(account: account, accountStore: accountStore)
                            } else if account.teamIdentifier != app.teamIdentifier {
                                OtherTeamSourceView(app: app, account: account, accountStore: accountStore)
                            } else {
                                RefreshConsoleView(
                                    app: app,
                                    accountStore: accountStore,
                                    selectedAccount: account,
                                    operation: .resign
                                )
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(account.email)
                                    .font(.body.weight(.medium))
                                Text(account.hasSavedSession ? "\(account.teamName) · \(account.teamType)" : "Reconnect this account")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 5)
                        }
                        .fullWidthListSeparators()
                    }
                } header: {
                    Text("Signing Account")
                } footer: {
                    Text("Choose any saved Apple ID. Accounts on this signing team can re-sign the current app. Another team requires a separate installation from an IPA, with separate app data.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Re-sign App")
        .navigationBarTitleDisplayMode(.inline)
        .task { await accountStore.reload() }
    }
}

private struct RefreshOptionsView: View {
    let app: InstalledAppSummary
    let accountStore: SigningAccountStore

    private var eligibleAccounts: [SigningAccountSummary] {
        accountStore.accounts
    }

    var body: some View {
        List {
            if eligibleAccounts.isEmpty {
                Section {
                    Text("Add or reconnect an Apple ID in Accounts to continue.")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Signing Account")
                } footer: {
                    Text("Refreshing keeps the app on its current signing team. To change teams, install or update from an IPA using the other account.")
                }
            } else {
                Section {
                    ForEach(eligibleAccounts) { account in
                        NavigationLink {
                            if !account.hasSavedSession {
                                SigningAccountDetailView(account: account, accountStore: accountStore)
                            } else if account.teamIdentifier != app.teamIdentifier {
                                OtherTeamSourceView(app: app, account: account, accountStore: accountStore)
                            } else {
                                RefreshConsoleView(
                                    app: app,
                                    accountStore: accountStore,
                                    selectedAccount: account
                                )
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(account.email)
                                    .font(.body.weight(.medium))
                                Text(account.hasSavedSession ? "\(account.teamName) · \(account.teamType)" : "Reconnect this account")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 5)
                        }
                        .fullWidthListSeparators()
                    }
                } header: {
                    Text("Signing Account")
                } footer: {
                    Text("Choose the saved Apple ID session SideKick should use for this refresh. The installed app’s signing team must stay the same.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Refresh Options")
        .navigationBarTitleDisplayMode(.inline)
        .task { await accountStore.reload() }
    }
}

private struct JITEnableView: View {
    let app: InstalledAppSummary

    @Environment(AppEnvironment.self) private var environment
    @State private var accountStore = SigningAccountStore()
    @State private var isWorking = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Label("Open \(app.name) first, then return here and enable JIT. Keep the app open in the background while SideKick connects.", systemImage: "info.circle")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)

                if #available(iOS 17, *) {
                    NavigationLink {
                        SideJITServerConfigView()
                    } label: {
                        Label("JIT Server Setup", systemImage: "desktopcomputer")
                    }
                    Text("On iOS 17 and later, JIT may need SideJITServer running on a paired computer on the same network. SideKick can connect to it, but cannot run that computer-side service itself.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("JIT uses the device pairing connection. Keep the pairing file valid and the local device connection available.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Before You Enable JIT")
            }

            Section {
                SwiftUI.Button {
                    Task { await enableJIT() }
                } label: {
                    HStack {
                        if isWorking { ProgressView() }
                        Text(isWorking ? "Connecting…" : "Enable JIT for \(app.name)")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(isWorking)

                if let statusMessage {
                    Label(statusMessage, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("JIT Connection")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Enable JIT")
        .navigationBarTitleDisplayMode(.inline)
    }

    @MainActor
    private func enableJIT() async {
        isWorking = true
        statusMessage = nil
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await SideStoreOperationService(accountStore: accountStore, ipaStore: environment.ipaImportStore)
                .enableJIT(bundleIdentifier: app.id)
            statusMessage = "JIT was enabled for \(app.name)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct InstallAccountSelectionView: View {
    let app: ImportedIPA
    let accounts: [SigningAccountSummary]
    let accountStore: SigningAccountStore
    let ipaStore: IPAImportStore
    let isUpdate: Bool
    let onInstalled: (() async -> Void)?
    var onSourceMissing: (() async -> Void)? = nil
    var currentTeamIdentifier: String? = nil

    var body: some View {
        List {
            Section {
                if accounts.isEmpty {
                    Text("Add an Apple ID in Accounts to continue.").foregroundStyle(.secondary)
                    NavigationLink("Accounts") { AccountsView() }
                }
                ForEach(accounts) { account in
                    NavigationLink {
                        if !account.hasSavedSession {
                            SigningAccountDetailView(account: account, accountStore: accountStore)
                        } else if let currentTeamIdentifier, currentTeamIdentifier != account.teamIdentifier {
                            SeparateInstallReviewView(source: app, account: account, accountStore: accountStore, originalName: app.name)
                        } else {
                            InstallConsoleView(app: app, account: account, accountStore: accountStore, ipaStore: ipaStore, isUpdate: isUpdate, onInstalled: onInstalled, onSourceMissing: onSourceMissing)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(account.email).font(.body.weight(.medium))
                            Text(account.hasSavedSession ? "\(account.teamName) · \(account.teamType)" : "Reconnect this account")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 5)
                    }
                }
            } header: {
                Text("Apple Account")
            } footer: {
                Text("Choose the account that will sign \(app.name). Updating the existing app keeps its team. A different team offers a separate installation with separate data.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Choose Account")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct InstallConsoleView: View {
    let app: ImportedIPA
    let account: SigningAccountSummary
    let accountStore: SigningAccountStore
    let ipaStore: IPAImportStore
    let isUpdate: Bool
    let onInstalled: (() async -> Void)?
    var onSourceMissing: (() async -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var lines: [String] = []
    @State private var progress = 0.0
    @State private var isRunning = true
    @State private var didStart = false
    @State private var failure: String?
    @State private var lastLoggedPercent = -5
    @State private var showingInstallConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(isRunning ? (isUpdate ? "Updating" : "Installing") : (failure == nil ? (isUpdate ? "Updated" : "Installed") : (isUpdate ? "Update Failed" : "Install Failed")))
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
            if UserDefaults.standard.isInstallConfirmationEnabled {
                showingInstallConfirmation = true
            } else {
                await runInstall()
            }
        }
        .alert(isUpdate ? "Update \(app.name)?" : "Install \(app.name)?", isPresented: $showingInstallConfirmation) {
            SwiftUI.Button(isUpdate ? "Update" : "Install") { Task { await runInstall() } }
            SwiftUI.Button("Cancel", role: .cancel) { isRunning = false; dismiss() }
        } message: {
            Text("Version \(app.version) will be signed using \(account.email).")
        }
    }

    @MainActor
    private func runInstall() async {
        append("Starting install · \(Date.now.formatted(date: .omitted, time: .standard))")
        append("Account selected · \(account.email)")
        append(isUpdate ? "Preparing update IPA" : "Preparing imported IPA")
        do {
            try await SideStoreOperationService(accountStore: accountStore, ipaStore: ipaStore)
                .install(
                    app,
                    using: account,
                    recoveryHandler: {
                        append("Revoked custom certificate found · switching to the selected Apple ID certificate and retrying")
                    }
                ) { fraction in
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
            append(isUpdate ? "Update completed successfully" : "Install completed successfully")
            await onInstalled?()
        } catch {
            failure = error.localizedDescription
            append("ERROR · \(error.localizedDescription)")
            if let importError = error as? IPAImportError, case .sourceFileMissing = importError {
                await onSourceMissing?()
            }
        }
        isRunning = false
    }

    @MainActor
    private func append(_ message: String) {
        lines.append("[\(Date.now.formatted(date: .omitted, time: .standard))] \(message)")
    }
}
