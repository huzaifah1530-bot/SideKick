import SwiftUI
import UIKit

struct AppManagementView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var accountStore = SigningAccountStore()
    @State private var isWorking = false
    @State private var isFindingShareIPA = false
    @State private var shareIPA: ImportedIPA?
    @State private var pendingUpdateIPA: ImportedIPA?
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
                if let pendingUpdateIPA {
                    LabeledContent("Queued update", value: "Version \(pendingUpdateIPA.version)")
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
                                ipaStore: environment.ipaImportStore,
                                isUpdate: false,
                                onInstalled: nil
                            )
                        } label: {
                            Label("Install", systemImage: "arrow.down.circle")
                                .fontWeight(.semibold)
                        }
                        .disabled(accountStore.isWorking)
                    } else {
                        Text("Add an Apple ID in Accounts to install this app.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    NavigationLink {
                        ShareIPAView(app: importedApp)
                    } label: {
                        Label("Share IPA", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, alignment: .leading)
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
                    NavigationLink {
                        GitHubUpdateSettingsView(app: installedApp)
                    } label: {
                        Label("GitHub Update Source", systemImage: "chevron.left.forwardslash.chevron.right")
                    }

                    SwiftUI.Button {
                        Task { await findIPAForSharing(installedApp) }
                    } label: {
                        HStack {
                            if isFindingShareIPA { ProgressView() }
                            Label("Share IPA", systemImage: "square.and.arrow.up")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(isFindingShareIPA)

                    if let pendingUpdateIPA {
                        if let originalAccount = accountStore.accounts.first(where: {
                            $0.accountIdentifier == installedApp.accountIdentifier
                                && $0.teamIdentifier == installedApp.teamIdentifier
                                && $0.hasSavedSession
                        }) {
                            NavigationLink {
                                InstallConsoleView(
                                    app: pendingUpdateIPA,
                                    account: originalAccount,
                                    accountStore: accountStore,
                                    ipaStore: environment.ipaImportStore,
                                    isUpdate: true,
                                    onInstalled: {
                                        do {
                                            try await environment.ipaImportStore.delete(pendingUpdateIPA)
                                            self.pendingUpdateIPA = nil
                                        } catch {
                                            self.errorMessage = error.localizedDescription
                                        }
                                    }
                                )
                            } label: {
                                Text("Update")
                                    .fontWeight(.semibold)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                        } else {
                            Text("Updates must be signed with the account that installed this app (\(installedApp.accountEmail)). Add that account back in Accounts to continue.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        SwiftUI.Button {
                            UIApplication.shared.open(InstalledApp.openAppURL(targetBundleIdentifier: installedApp.resignedBundleIdentifier))
                        } label: {
                            Text("Open")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                    }

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

                    NavigationLink {
                        JITEnableView(app: installedApp)
                    } label: {
                        Label("Enable JIT", systemImage: "bolt.fill")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                }
            }
        }
        .listStyle(.insetGrouped)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(appName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $shareIPA) { ipa in
            ShareIPAView(app: ipa)
        }
        .onAppear { Task { await reloadManagementState() } }
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

    @MainActor
    private func reloadManagementState() async {
        await accountStore.reload()
        guard let installedApp else { return }
        let matchingBundleIDs = Set([installedApp.bundleIdentifier, installedApp.resignedBundleIdentifier].map { $0.lowercased() })
        pendingUpdateIPA = (try? await environment.ipaImportStore.importedApps())?
            .first { matchingBundleIDs.contains($0.bundleIdentifier.lowercased()) }
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
                .enableJIT(bundleIdentifier: app.bundleIdentifier)
            statusMessage = "JIT was enabled for \(app.name)."
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
    let isUpdate: Bool
    let onInstalled: (() async -> Void)?

    var body: some View {
        List {
            Section {
                ForEach(accounts) { account in
                    NavigationLink {
                        InstallConsoleView(app: app, account: account, accountStore: accountStore, ipaStore: ipaStore, isUpdate: isUpdate, onInstalled: onInstalled)
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
                Text("Choose the account that will sign and \(isUpdate ? "update" : "install") \(app.name).")
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
            await runInstall()
        }
    }

    @MainActor
    private func runInstall() async {
        append("Starting install · \(Date.now.formatted(date: .omitted, time: .standard))")
        append("Account selected · \(account.email)")
        append(isUpdate ? "Preparing update IPA" : "Preparing imported IPA")
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
            append(isUpdate ? "Update completed successfully" : "Install completed successfully")
            await onInstalled?()
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
