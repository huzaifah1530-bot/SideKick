import SwiftUI
import UniformTypeIdentifiers
import UIKit
import CoreLocation

struct RefreshSettingsView: View {
    @AppStorage("isBackgroundRefreshEnabled") private var backgroundRefresh = true
    @AppStorage("isIdleTimeoutDisableEnabled") private var keepScreenAwake = true
    @AppStorage("isCellularRefreshEnabled") private var cellularRefresh = false
    @AppStorage("isBackgroundServiceEnabled") private var keepAliveEnabled = true
    @AppStorage("backgroundServiceMode") private var keepAliveMode = "audio"
    @Environment(\.scenePhase) private var scenePhase
    @State private var locationAccess = CLLocationManager().authorizationStatus

    var body: some View {
        Form {
            Section {
                Toggle("Automatic app refresh", isOn: $backgroundRefresh)
                    .onChange(of: backgroundRefresh) { _, enabled in
                        UIApplication.shared.setMinimumBackgroundFetchInterval(enabled ? UIApplication.backgroundFetchIntervalMinimum : UIApplication.backgroundFetchIntervalNever)
                    }
                Toggle("Keep SideKick active during refresh", isOn: $keepScreenAwake)
                Toggle("Refresh over cellular", isOn: $cellularRefresh)
                if cellularRefresh {
                    NavigationLink {
                        CellularShortcutSettingsView()
                    } label: {
                        Label("Cellular Refresh Shortcuts", systemImage: "square.stack.3d.up")
                    }
                    .fullWidthListSeparators()
                }
            } footer: {
                Text("Automatic refresh renews signing before apps expire. iOS controls when background work runs, so open SideKick and refresh manually if a deadline is close.")
            }

            Section {
                Toggle("Enable keep-alive service", isOn: $keepAliveEnabled)
                    .onChange(of: keepAliveEnabled) { _, enabled in
                        BackgroundServiceManager.setEnabled(enabled)
                    }
                Picker("Keep-alive method", selection: $keepAliveMode) {
                    Text("Audio").tag("audio")
                    Text("Location").tag("location")
                }
                .disabled(!keepAliveEnabled)
                .onChange(of: keepAliveMode) { previous, value in
                    BackgroundServiceManager.service(for: BackgroundServiceMode(rawValue: previous) ?? .audio).stop()
                    BackgroundServiceManager.switchTo(mode: BackgroundServiceMode(rawValue: value) ?? .audio)
                    locationAccess = CLLocationManager().authorizationStatus
                }
                if keepAliveEnabled && keepAliveMode == "location" && (locationAccess == .denied || locationAccess == .restricted) {
                    Label("Location access is required for this method", systemImage: "location.slash")
                        .foregroundStyle(.secondary)
                    Link("Open iOS Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                }
            } header: {
                Text("Background keep-alive")
            } footer: {
                Text("SideStore’s background service can help keep its refresh helper available. iOS may still pause background work.")
            }

            Section {
                Link("Get Refresh Shortcut", destination: URL(string: "https://www.icloud.com/shortcuts/2af57f665d434568a589f1e9b7d7f4d1")!)
                Link("Open Shortcuts", destination: URL(string: "shortcuts://")!)
                NavigationLink {
                    DailyRefreshAutomationGuideView()
                } label: {
                    Label("How to schedule daily refresh", systemImage: "list.number")
                }
            } header: {
                Text("Optional daily automation")
            } footer: {
                Text("Adding the shortcut does not schedule it, and SideKick cannot verify whether a personal automation was created. Daily scheduling is optional; you can also refresh manually. iOS controls when background work runs.")
            }
        }
        .navigationTitle("App Refresh")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { locationAccess = CLLocationManager().authorizationStatus }
        }
    }
}

private struct DailyRefreshAutomationGuideView: View {
    var body: some View {
        List {
            Section {
                Text("The refresh shortcut and its daily automation are separate. Installing the shortcut does not schedule it.")
                Text("SideKick cannot read or confirm your personal automations. Check the Shortcuts app to see whether you created one.")
                    .foregroundStyle(.secondary)
            }
            Section("Create a daily automation") {
                LabeledContent("1", value: "Open Shortcuts and choose Automation.")
                LabeledContent("2", value: "Create a Time of Day automation and choose Daily.")
                LabeledContent("3", value: "Choose Run Shortcut, then select Refresh SideKick Apps.")
                LabeledContent("4", value: "Set it to run immediately, if that option is shown, and confirm.")
            }
            Section {
                Text("You can skip automation and refresh from SideKick whenever you want. Background timing is controlled by iOS.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Daily Refresh Guide")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct CellularShortcutSettingsView: View {
    @AppStorage("turnOffDataShortcutName") private var turnOffName = AppConstants.Shortcuts.defaultTurnOffDataShortcutName
    @AppStorage("turnOnDataShortcutName") private var turnOnName = AppConstants.Shortcuts.defaultTurnOnDataShortcutName

    var body: some View {
        Form {
            Section {
                TextField("Turn cellular data off", text: $turnOffName)
                    .autocorrectionDisabled()
                    .onSubmit { CellularRefreshManager.shared.setTurnOffDataShortcutName(turnOffName) }
                TextField("Turn cellular data on", text: $turnOnName)
                    .autocorrectionDisabled()
                    .onSubmit { CellularRefreshManager.shared.setTurnOnDataShortcutName(turnOnName) }
                Link("Open Shortcuts", destination: URL(string: "shortcuts://")!)
            } footer: {
                Text("Create two shortcuts using Set Cellular Data: one turns data off and one turns it on. Enter their exact names here. SideKick runs them around the device connection step and restores cellular data afterward. SideKick manages its built-in local VPN automatically.")
            }
        }
        .navigationTitle("Cellular Shortcuts")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct InstallSigningSettingsView: View {
    @AppStorage("isInstallConfirmationEnabled") private var confirmInstall = true
    @AppStorage("isAutoLaunchAppAfterInstallEnabled") private var launchAfterInstall = false
    @AppStorage("isClearCustomizationsOnUninstallEnabled") private var clearCustomizations = true
    @AppStorage("isAppLimitDisabled") private var disableAppLimit = false
    @AppStorage("preferResignedIPA") private var preferResignedIPA = true
    @AppStorage("isExportResignedAppEnabled") private var exportResignedApp = false

    var body: some View {
        Form {
            Section("Install behavior") {
                Toggle("Confirm before installing", isOn: $confirmInstall)
                Toggle("Open app after installation", isOn: $launchAfterInstall)
                Toggle("Clear app customizations after uninstall", isOn: $clearCustomizations)
            }

            Section {
                Toggle("Prefer the resigned IPA", isOn: $preferResignedIPA)
                Toggle("Save a copy of resigned apps", isOn: $exportResignedApp)
                Toggle("Disable SideStore app limit", isOn: $disableAppLimit)
                    .disabled(!UserDefaults.standard.isCowExploitSupported && ProcessInfo().sparseRestorePatched)
            } header: {
                Text("Signing")
            } footer: {
                Text(!UserDefaults.standard.isCowExploitSupported && ProcessInfo().sparseRestorePatched
                    ? "The app limit bypass is unavailable on this iOS version. Saving resigned apps keeps an extra IPA in Files → SideKick → ResignedApps."
                    : "The app limit option depends on iOS and account type. Saving resigned apps keeps an extra IPA in Files → SideKick → ResignedApps.")
            }

            Section("Certificates and profiles") {
                Text("Apple Developer certificates, provisioning profiles, and App IDs are managed per Apple ID in the Accounts tab.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Install & Signing")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ConnectionSettingsView: View {
    @AppStorage("isAutoRetryRemotePairingPortEnabled") private var autoRetryPort = true
    @AppStorage("remotePairingPortOverride") private var portOverride = 0
    @State private var vpn = LocalVPNService.shared
    @State private var isAutomaticPortDraft = true
    @State private var fixedPortDraft = ""
    @State private var portDraftLoaded = false
    @State private var isChoosingPairingFile = false
    @State private var isShowingLocalConnection = false
    @State private var pairingStatus: String?
    @State private var pairingRecoveryAction: String?
    @State private var isShowingPairingStatus = false

    var body: some View {
        Form {
            Section {
                NavigationLink { LocalConnectionSettingsView() } label: {
                    Label("Local Connection", systemImage: "network.badge.shield.half.filled")
                }
                .fullWidthListSeparators()
                Toggle("Retry remote pairing ports automatically", isOn: $autoRetryPort)
                Toggle("Automatic port selection", isOn: $isAutomaticPortDraft)
                LabeledContent("Fixed remote pairing port") {
                    TextField("1–65,535", text: $fixedPortDraft)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .disabled(isAutomaticPortDraft)
                }
                if !isAutomaticPortDraft, !isValidFixedPortDraft {
                    Text("Enter a whole number from 1 to 65,535.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if !isAutomaticPortDraft {
                    Stepper(value: Binding<Int>(
                        get: { validatedFixedPortDraft ?? 1 },
                        set: { fixedPortDraft = String($0) }
                    ), in: 1...65_535) {
                        LabeledContent("Adjust fixed port", value: validatedFixedPortDraft.map(String.init) ?? "Enter a port")
                    }
                }
                SwiftUI.Button("Save Port") {
                    _ = savePort()
                }
                .disabled(isAutomaticPortDraft ? portOverride == 0 : validatedFixedPortDraft == nil)
            } header: {
                Text("Pairing")
            } footer: {
                Text("Set the port to Automatic unless your pairing setup requires a fixed port. Choose LocalDevVPN for free Apple Accounts, or the optional built-in VPN when your signing profiles support it.")
            }

            Section("Pairing file") {
                LabeledContent("Status", value: PairingFileManager.shared.hasPairingFile() ? "Ready" : "Not set up")
                SwiftUI.Button("Import or replace pairing file…") { isChoosingPairingFile = true }
                Link("How to get a pairing file", destination: AppConstants.URLs.pairingDocumentation)
                Text("This file is a private trust record for this iPhone. Keep it secure and import one created for this device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Connection & Pairing")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: portOverride) { _, value in
            isAutomaticPortDraft = value == 0
            fixedPortDraft = value == 0 ? "" : String(value)
            syncMinimuxerBackendFromUserDefaults()
        }
        .guardUnsavedSettings(isDirty: portDraftLoaded && (isAutomaticPortDraft ? portOverride != 0 : fixedPortDraft != String(portOverride)), save: {
            savePort()
        }, discard: {
            isAutomaticPortDraft = portOverride == 0
            fixedPortDraft = portOverride == 0 ? "" : String(portOverride)
        })
        .onAppear {
            guard !portDraftLoaded else { return }
            portDraftLoaded = true
            isAutomaticPortDraft = portOverride == 0
            fixedPortDraft = portOverride == 0 ? "" : String(portOverride)
        }
        .navigationDestination(isPresented: $isShowingLocalConnection) { LocalConnectionSettingsView() }
        .task { await vpn.refreshStatus() }
        .fileImporter(
            isPresented: $isChoosingPairingFile,
            allowedContentTypes: PairingFileManager.supportedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            Task { await importPairingFile(result) }
        }
        .alert("Device pairing", isPresented: $isShowingPairingStatus) {
            if let pairingRecoveryAction {
                SwiftUI.Button(pairingRecoveryAction) {
                    isShowingLocalConnection = true
                    self.pairingRecoveryAction = nil
                }
            }
            SwiftUI.Button("OK", role: .cancel) { pairingStatus = nil }
        } message: {
            Text(pairingStatus ?? "")
        }
    }

    private func savePort() -> Bool {
        if isAutomaticPortDraft { portOverride = 0; return true }
        guard let port = validatedFixedPortDraft else { return false }
        portOverride = port
        fixedPortDraft = String(port)
        return true
    }

    private var validatedFixedPortDraft: Int? {
        guard !fixedPortDraft.isEmpty,
              fixedPortDraft.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }),
              let port = Int(fixedPortDraft), (1...65_535).contains(port) else { return nil }
        return port
    }

    private var isValidFixedPortDraft: Bool { validatedFixedPortDraft != nil }

    @MainActor
    private func importPairingFile(_ result: Result<[URL], Error>) async {
        var didImport = false
        pairingRecoveryAction = nil
        do {
            guard let url = try result.get().first else { return }
            UserDefaults.standard.set(false, forKey: "sidekick.setup.pairing-verified")
            try PairingSetupImporter.importFile(from: url)
            didImport = true
            guard PairingFileManager.shared.fetchPairingFile() != nil else {
                throw PairingSetupError.unreadableFile
            }
            do {
                let vpnLease = try await LocalVPNService.shared.acquire()
                defer { LocalVPNService.shared.release(vpnLease) }
                try await ensureMinimuxerReady()
                _ = try await fetchUDID(forceLive: true)
                UserDefaults.standard.set(true, forKey: "sidekick.setup.pairing-verified")
                pairingRecoveryAction = nil
                pairingStatus = "Pairing is set up and SideKick can reach this iPhone. Install and refresh are ready."
            } catch {
                await vpn.refreshStatus()
                let recovery = vpn.mode == .external
                    ? (vpn.externalInstalled ? "Connect LocalDevVPN" : "Get LocalDevVPN")
                    : (vpn.isConfigured ? "Verify Device Connection" : "Allow Built-in VPN")
                pairingRecoveryAction = recovery
                let instruction = "In Settings → Connection & Pairing → Local Connection, choose \(recovery), then retry."
                pairingStatus = "Pairing file imported. SideKick couldn’t reach the iPhone yet. \(instruction) Check that this pairing file belongs to your iPhone.\n\n\(error.localizedDescription)"
            }
        } catch {
            pairingStatus = didImport
                ? "The pairing file is saved, but the local connection could not be verified.\n\n\(error.localizedDescription)"
                : "SideKick couldn’t import that pairing file. Make sure it was created for this iPhone and try again.\n\n\(error.localizedDescription)"
        }
        isShowingPairingStatus = true
    }
}

private enum PairingSetupError: LocalizedError {
    case unreadableFile
    var errorDescription: String? { "The pairing file was imported but could not be read." }
}

struct AnisetteSettingsView: View {
    @State private var useOnDeviceAnisette = true
    @State private var server = AnisetteConfiguration.windowsServer
    @State private var clientInfo = ""
    @State private var userAgent = ""
    @State private var isSaving = false
    @State private var showReset = false
    @State private var message: String?
    @State private var settingsLoaded = false
    private struct Draft: Equatable {
        let onDevice: Bool
        let server: String
        let clientInfo: String
        let userAgent: String
    }
    @State private var savedDraft: Draft?
    private var draft: Draft { Draft(onDevice: useOnDeviceAnisette, server: server, clientInfo: clientInfo, userAgent: userAgent) }

    var body: some View {
        Form {
            Section {
                Toggle("Generate Anisette on this device", isOn: $useOnDeviceAnisette)
                TextField("Server URL", text: $server)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SwiftUI.Button("Use Windows Anisette server") {
                    server = AnisetteConfiguration.windowsServer
                    useOnDeviceAnisette = false
                    clientInfo = AnisetteConfiguration.windowsClientInfo
                    userAgent = AnisetteConfiguration.windowsUserAgent
                }
                SwiftUI.Button("Use On-Device Defaults") {
                    useOnDeviceAnisette = true
                    clientInfo = AppConstants.Anisette.defaultClientInfo
                    userAgent = AppConstants.Anisette.defaultUserAgent
                }
                NavigationLink {
                    AnisetteServersView()
                } label: {
                    Label("Servers & Server Lists", systemImage: "server.rack")
                }
                .fullWidthListSeparators()
            } header: {
                Text("Authentication data")
            } footer: {
                Text("The Windows preset selects a remote server with matching authentication headers. Save to apply your changes. Switching providers or headers regenerates authentication data; your saved accounts and certificates are kept.")
            }

            Section {
                TextField("Client information", text: $clientInfo, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("User agent", text: $userAgent, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SwiftUI.Button("Save Authentication Settings") {
                    Task { _ = await saveAuthenticationSettings() }
                }
            } header: {
                Text("Custom authentication headers")
            } footer: {
                Text("Leave a header empty to use the compatibility default. Use a matching client information and user agent pair for your server.")
            }
            Section {
                SwiftUI.Button("Regenerate Authentication Data", role: .destructive) { showReset = true }
            } footer: {
                Text("Clears saved Anisette provisioning data and creates fresh data at the next sign-in. Saved accounts, certificates and installed app records are kept.")
            }
            if let message {
                Section { Text(message).font(.footnote) }
            }
        }
        .disabled(isSaving || !settingsLoaded)
        .guardUnsavedSettings(isDirty: settingsLoaded && savedDraft != draft, save: {
            await saveAuthenticationSettings()
        }, discard: {
            guard let savedDraft else { return }
            useOnDeviceAnisette = savedDraft.onDevice
            server = savedDraft.server
            clientInfo = savedDraft.clientInfo
            userAgent = savedDraft.userAgent
        })
        .task {
            guard !settingsLoaded else { return }
            useOnDeviceAnisette = UserDefaults.standard.useOnDeviceAnisette
            let currentServer = UserDefaults.standard.menuAnisetteURL
            server = currentServer.isEmpty ? AnisetteConfiguration.windowsServer : currentServer
            let config = await AnisetteConfigManager.shared.loadConfig()
            clientInfo = config.clientInfo
            userAgent = config.userAgent
            savedDraft = draft
            settingsLoaded = true
        }
        .confirmationDialog("Regenerate authentication data?", isPresented: $showReset, titleVisibility: .visible) {
            SwiftUI.Button("Regenerate Data", role: .destructive) {
                run {
                    try await SigningAccountStore().resetAnisetteProvisioning()
                    message = "Authentication data cleared. Fresh data will be generated at the next sign-in."
                }
            }
        } message: {
            Text("Your accounts, certificates and app records will stay on this device.")
        }
        .navigationTitle("Anisette")
        .navigationBarTitleDisplayMode(.inline)
    }

    @MainActor private func saveAuthenticationSettings() async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            try await SigningAccountStore().saveAnisetteConfiguration(server: server,
                clientInfo: clientInfo, userAgent: userAgent, onDevice: useOnDeviceAnisette)
            savedDraft = draft
            message = "Authentication settings saved."
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        isSaving = true
        message = nil
        Task { @MainActor in
            defer { isSaving = false }
            do { try await operation() }
            catch { message = error.localizedDescription }
        }
    }
}

struct SettingsStorageView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var importedApps: [ImportedIPA] = []
    @State private var storageUsage = SideKickStorageUsage()
    @State private var isMeasuring = false
    @State private var isCleaning = false
    @State private var isShowingClearReview = false
    @State private var selectedRemovalKeys = Set<String>()
    @State private var errorMessage: String?

    var body: some View {
        List {
            allAppDataSection
            importedIPAsSection
            signingTemporarySection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .sideKickStorageDidChange)) { _ in Task { await reload() } }
        .sheet(isPresented: $isShowingClearReview) { clearReviewSheet }
        .alert("Storage", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            SwiftUI.Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var allAppDataSection: some View {
        Section {
            HStack {
                Text("Documents & Data")
                Spacer()
                if isMeasuring { ProgressView() }
                else { Text(storageUsage.formatted(storageUsage.totalContainer)).foregroundStyle(.secondary) }
            }
            ForEach(storageUsage.directories) { directory in
                NavigationLink {
                    StorageDirectoryDetailView(directory: directory)
                } label: {
                    LabeledContent(directory.name, value: storageUsage.formatted(directory.bytes))
                }
                .fullWidthListSeparators()
            }
        } header: { Text("All App Data") } footer: {
            Text("Includes hidden files, databases, logs, caches and temporary downloads. Tap a folder to see what takes space. iOS Storage may update later or count shared storage differently.")
        }
    }

    private var importedIPAsSection: some View {
        Section {
            LabeledContent("Items", value: "\(importedApps.count)")
            LabeledContent("Downloaded IPA copies", value: storageUsage.formatted(storageUsage.importedIPAs))
            if storageUsage.importedIPAs > 0 {
                SwiftUI.Button("Remove downloaded IPA copies", role: .destructive) {
                    selectedRemovalKeys.removeAll()
                    isShowingClearReview = true
                }
            }
        } header: {
            Text("Imported IPAs")
        } footer: {
            Text("This removes IPA copies stored by SideKick. Files linked from the Files app remain in their original location.")
        }
    }

    private var signingTemporarySection: some View {
        Section {
            LabeledContent("App signing cache", value: storageUsage.formatted(storageUsage.signingCache))
            LabeledContent("Temporary install files", value: storageUsage.formatted(storageUsage.temporaryFiles))
            LabeledContent("Saved resigned IPAs", value: storageUsage.formatted(storageUsage.exportedIPAs))
            NavigationLink { StorageFilesView() } label: {
                Label("Manage Cached & Temporary Files", systemImage: "folder.badge.gearshape")
            }
            SwiftUI.Button { Task { await cleanUnusedFiles() } } label: {
                HStack {
                    Label("Clean Unused Files", systemImage: "trash")
                    Spacer()
                    if isCleaning { ProgressView() }
                }
            }
            .disabled(isCleaning)
            .fullWidthListSeparators()
        } header: {
            Text("Signing & Temporary Files")
        } footer: {
            Text("SideKick keeps the current extracted source for each app so it can re-sign it. Extracted apps can be larger than their compressed IPAs. SideKick automatically removes completed install files and expired unused sources. Recent sources are kept for 24 hours for recovery. Clean Unused Files also clears disposable network caches. Saved resigned IPAs and app records are kept.")
        }
    }

    private var clearReviewSheet: some View {
        NavigationStack {
            clearReviewList
            .navigationTitle("Review IPA Copies")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { clearReviewToolbar }
        }
    }

    private var clearReviewList: some View {
        List {
            clearReviewExplanation
            removableIPAsSection
        }
    }

    private var clearReviewExplanation: some View {
        Section {
            Text("Removing these \(selectedRemovalApps.count) selected copies also deletes their SideKick import records. The selection may include queued updates or IPAs shown under Ready to Install. To restore an entry later, download or import its IPA again and re-queue it if needed. Installed apps and files in Files are not affected.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var removableIPAsSection: some View {
        Section("Downloaded IPA copies (\(selectedRemovalApps.count) selected)") {
            ForEach(Array(removableImportedApps.enumerated()), id: \.offset) { entry in
                removalRow(for: entry.element)
            }
        }
    }

    private func removalRow(for app: ImportedIPA) -> some View {
        let key = removalKey(for: app)
        return SwiftUI.Button {
            if selectedRemovalKeys.contains(key) { selectedRemovalKeys.remove(key) }
            else { selectedRemovalKeys.insert(key) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name).foregroundStyle(.primary)
                    Text("Version \(app.version) · \(app.isUpdateQueued ? "Queued for update" : "Imported IPA")")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: selectedRemovalKeys.contains(key) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedRemovalKeys.contains(key) ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ToolbarContentBuilder
    private var clearReviewToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            SwiftUI.Button("Cancel") { isShowingClearReview = false }
        }
        ToolbarItem(placement: .confirmationAction) {
            SwiftUI.Button("Remove \(selectedRemovalKeys.count)", role: .destructive) {
                isShowingClearReview = false
                Task { await clearSelectedManagedIPAs() }
            }
            .disabled(selectedRemovalKeys.isEmpty)
        }
    }

    @MainActor
    private func reload() async {
        guard !isMeasuring else { return }
        isMeasuring = true
        defer { isMeasuring = false }
        do {
            importedApps = try await environment.ipaImportStore.importedApps()
            storageUsage = await SideKickStorageUsage.measure()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func clearSelectedManagedIPAs() async {
        do {
            for app in importedApps where app.fileName != nil && selectedRemovalKeys.contains(removalKey(for: app)) {
                try await environment.ipaImportStore.delete(app)
            }
            try await environment.ipaImportStore.cleanupOrphanedManagedIPAs()
            selectedRemovalKeys.removeAll()
            await reload()
        } catch {
            errorMessage = error.localizedDescription
            await reload()
        }
    }

    private func removalKey(for app: ImportedIPA) -> String {
        "\(app.id)|\(app.importedAt.timeIntervalSince1970)"
    }

    private var removableImportedApps: [ImportedIPA] {
        importedApps.filter { $0.fileName != nil }
    }

    private var selectedRemovalApps: [ImportedIPA] {
        removableImportedApps.filter { selectedRemovalKeys.contains(removalKey(for: $0)) }
    }

    @MainActor
    private func cleanUnusedFiles() async {
        guard !isCleaning else { return }
        isCleaning = true
        defer { isCleaning = false }
        do {
            let report = try await SideKickStorageCleanup.cleanUnused(downloads: environment.githubUpdateDownloads)
            try await environment.ipaImportStore.cleanupOrphanedManagedIPAs()
            await reload()
            errorMessage = report
        } catch { errorMessage = error.localizedDescription }
    }
}

struct StorageDirectoryDetailView: View {
    let directory: StorageDirectoryUsage
    @State private var entries: [StorageDirectoryUsage] = []
    @State private var isLoading = true
    @State private var removable: [RemovableStorageItem] = []

    var body: some View {
        List {
            if isLoading {
                HStack { Spacer(); ProgressView("Measuring…"); Spacer() }
            } else if entries.isEmpty {
                ContentUnavailableView("No Files", systemImage: "folder")
            } else {
                ForEach(entries) { entry in
                    if (try? entry.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                        NavigationLink { StorageDirectoryDetailView(directory: entry) } label: {
                            LabeledContent(entry.name, value: ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file))
                        }
                        .fullWidthListSeparators()
                    } else {
                        LabeledContent(entry.name, value: ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file))
                            .fullWidthListSeparators()
                    }
                    if let item = removable.first(where: { $0.id == entry.id }) {
                        if let owner = item.policy.owner { Text("Retained signing source · \(owner)").font(.footnote).foregroundStyle(.secondary) }
                        if let reason = item.protectedReason { Text(reason).font(.footnote).foregroundStyle(.secondary) }
                        else { StorageRemovalAction(item: item) }
                    }
                }
            }
        }
        .navigationTitle(directory.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .sideKickStorageDidChange)) { _ in Task { await reload() } }
    }

    private func reload() async {
        isLoading = true
        entries = await SideKickStorageUsage.children(of: directory.url)
        removable = (try? await SideKickStorageCleanup.items()) ?? []
        isLoading = false
    }
}
