import SwiftUI
import UniformTypeIdentifiers
import UIKit
import CoreLocation

struct RefreshSettingsView: View {
    @AppStorage("sidekick.setup.refresh-shortcut-added") private var refreshShortcutAdded = false
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
                        Label("Cellular Refresh Shortcuts", systemImage: "antenna.radiowaves.left.and.right")
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
                Text("Helps keep SideKick’s refresh helper available. iOS may still pause background work.")
            }

            Section {
                Link(destination: RefreshShortcut.downloadURL) {
                    Label("Get the Shortcut", systemImage: "1.circle")
                }
                .fullWidthListSeparators()
                NavigationLink {
                    ShortcutRepairGuideView()
                } label: {
                    Label("Fix the SideKick Step", systemImage: "2.circle")
                }
                .fullWidthListSeparators()
                NavigationLink {
                    DailyRefreshAutomationGuideView()
                } label: {
                    Label("Schedule It Daily", systemImage: "3.circle")
                }
                .fullWidthListSeparators()
                Link(destination: RefreshShortcut.shortcutsURL) {
                    Label("Open Shortcuts", systemImage: "arrow.up.forward.app")
                }
                .fullWidthListSeparators()
                Toggle("I’ve Added the Shortcut", isOn: $refreshShortcutAdded)
                ShortcutTestPanel()
            } header: {
                Text("Daily Automation")
            } footer: {
                Text("Optional. After you add it, the shortcut’s SideKick step shows as not found. That’s expected; step 2 shows how to replace it.")
            }
        }
        .navigationTitle("App Refresh")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { locationAccess = CLLocationManager().authorizationStatus }
        }
    }
}

struct DailyRefreshAutomationGuideView: View {
    var body: some View {
        List {
            Section {
                Text("The shortcut and its daily automation are separate. Adding the shortcut doesn’t schedule it.")
                Text("SideKick can’t read or confirm your personal automations. Check the Shortcuts app to see whether you created one.")
                    .foregroundStyle(.secondary)
            }
            Section("Create a Daily Automation") {
                Label("Open Shortcuts and choose Automation.", systemImage: "1.circle")
                Label("Create a Time of Day automation and choose Daily.", systemImage: "2.circle")
                Label("Choose Run Shortcut, then pick your repaired “Refresh SideKick Apps” shortcut.", systemImage: "3.circle")
                Label("Turn on Run Immediately and turn off Notify When Run, then tap Done.", systemImage: "4.circle")
            }
            Section {
                Link(destination: RefreshShortcut.shortcutsURL) {
                    Label("Open Shortcuts", systemImage: "arrow.up.forward.app")
                }
                .fullWidthListSeparators()
            } footer: {
                Text("Run Immediately lets it run without asking. You can skip automation and refresh from SideKick whenever you want; iOS controls background timing.")
            }
        }
        .navigationTitle("Schedule It Daily")
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
                Toggle("Remove 3-App Limit", isOn: $disableAppLimit)
                    .disabled(!UserDefaults.standard.isCowExploitSupported && ProcessInfo().sparseRestorePatched)
            } header: {
                Text("Signing")
            } footer: {
                Text(!UserDefaults.standard.isCowExploitSupported && ProcessInfo().sparseRestorePatched
                    ? "The app limit bypass is unavailable on this iOS version. Saving resigned apps keeps an extra IPA in Files → SideKick → ResignedApps."
                    : "The app limit option depends on iOS and account type. Saving resigned apps keeps an extra IPA in Files → SideKick → ResignedApps.")
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
            Section("Pairing File") {
                LabeledContent("Status") {
                    Label(PairingFileManager.shared.hasPairingFile() ? "Imported" : "Not set up",
                          systemImage: PairingFileManager.shared.hasPairingFile() ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(PairingFileManager.shared.hasPairingFile() ? Color.green : Color.secondary)
                }
                SwiftUI.Button(PairingFileManager.shared.hasPairingFile() ? "Replace Pairing File…" : "Import Pairing File…") { isChoosingPairingFile = true }
                Link("How to Get a Pairing File", destination: AppConstants.URLs.pairingDocumentation)
            }

            Section {
                Toggle("Retry ports automatically", isOn: $autoRetryPort)
                Picker("Port", selection: $isAutomaticPortDraft) {
                    Text("Automatic").tag(true)
                    Text("Custom").tag(false)
                }
                if !isAutomaticPortDraft {
                    LabeledContent("Custom Port") {
                        TextField("1–65535", text: $fixedPortDraft)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(isValidFixedPortDraft || fixedPortDraft.isEmpty ? Color.primary : Color.red)
                    }
                }
            } header: {
                Text("Remote Pairing Port")
            } footer: {
                if !isAutomaticPortDraft, !fixedPortDraft.isEmpty, !isValidFixedPortDraft {
                    Label("Enter a number from 1 to 65535.", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                } else {
                    Text("Keep this on Automatic unless your setup needs a fixed port. The pairing file is private to this iPhone.")
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                SwiftUI.Button("Save") { _ = savePort() }
                    .fontWeight(.semibold)
                    .disabled(!isPortDraftDirty || (!isAutomaticPortDraft && validatedFixedPortDraft == nil))
            }
        }
        .navigationTitle("Pairing")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: portOverride) { _, value in
            isAutomaticPortDraft = value == 0
            fixedPortDraft = value == 0 ? "" : String(value)
            syncMinimuxerBackendFromUserDefaults()
        }
        .guardUnsavedSettings(isDirty: isPortDraftDirty, save: {
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

    private var isPortDraftDirty: Bool {
        portDraftLoaded && (isAutomaticPortDraft ? portOverride != 0 : fixedPortDraft != String(portOverride))
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
                let instruction = "In Settings → Connection, choose \(recovery), then retry."
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
    @State private var remoteSelection: RemoteAnisetteSelection?
    @State private var remoteError: String?
    @State private var isFetchingRemote = false
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
                Toggle("Generate on This iPhone", isOn: $useOnDeviceAnisette)
                if !useOnDeviceAnisette {
                    TextField("Server URL", text: $server)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                SwiftUI.Button {
                    Task { await useNewestServer() }
                } label: {
                    HStack {
                        Text("Use Newest Anisette Server")
                        Spacer()
                        if isFetchingRemote { ProgressView() }
                    }
                }
                .disabled(isFetchingRemote)
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
                Text("Authentication Data")
            } footer: {
                Text("Changing the provider regenerates authentication data. Accounts and certificates are kept.")
            }

            Section {
                LabeledContent("Recommended", value: remoteSelection?.server.name ?? (remoteError == nil ? "Checking…" : "Unavailable"))
                LabeledContent("List updated", value: remoteUpdatedText)
                if let applied = AnisetteRemoteRecord.load() {
                    LabeledContent("You switched", value: applied.appliedAt.formatted(date: .abbreviated, time: .shortened))
                }
                if let remoteError {
                    Text(remoteError).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Newest Server")
            } footer: {
                Text("If sign-in or refresh fails with an Anisette error, the server may have stopped working. SideKick’s GitHub repository lists the current recommended server, so check here for a newer one.")
            }

            Section {
                TextField("Client information", text: $clientInfo, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("User agent", text: $userAgent, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Custom Headers")
            } footer: {
                Text("Leave empty to use the defaults. Use a matching pair for your server.")
            }
            Section {
                SwiftUI.Button("Regenerate Authentication Data", role: .destructive) { showReset = true }
            } footer: {
                Text("Creates fresh data at the next sign-in.")
            }
        }
        .disabled(isSaving || !settingsLoaded)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    SwiftUI.Button("Save") { Task { _ = await saveAuthenticationSettings() } }
                        .fontWeight(.semibold)
                        .disabled(!settingsLoaded || savedDraft == draft)
                }
            }
        }
        .messageAlert("Anisette", message: $message)
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
            await loadRemoteList()
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
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    private var remoteUpdatedText: String {
        if let date = remoteSelection?.lastUpdated { return date.formatted(date: .abbreviated, time: .shortened) }
        return remoteSelection == nil && remoteError == nil ? "Checking…" : "Unknown"
    }

    /// Shows what GitHub currently recommends without changing anything.
    @MainActor private func loadRemoteList() async {
        guard !isFetchingRemote else { return }
        isFetchingRemote = true
        defer { isFetchingRemote = false }
        do {
            remoteSelection = try await RemoteAnisetteConfigurationClient().fetchRecommended()
            remoteError = nil
        } catch {
            remoteError = error.localizedDescription
        }
    }

    /// Downloads the recommended server from the repository and applies it right away.
    @MainActor private func useNewestServer() async {
        guard !isFetchingRemote, !isSaving else { return }
        isFetchingRemote = true
        defer { isFetchingRemote = false }
        let selection: RemoteAnisetteSelection
        do {
            selection = try await RemoteAnisetteConfigurationClient().fetchRecommended()
            remoteSelection = selection
            remoteError = nil
        } catch {
            remoteError = error.localizedDescription
            message = error.localizedDescription
            return
        }
        server = selection.serverURL.absoluteString
        useOnDeviceAnisette = false
        clientInfo = selection.server.clientInfo
        userAgent = selection.server.userAgent
        guard await saveAuthenticationSettings() else { return }
        AnisetteRemoteRecord(serverID: selection.server.id, appliedAt: .now).save()
        let updated = selection.lastUpdated.map { " The list was updated \($0.formatted(date: .abbreviated, time: .shortened))." } ?? ""
        message = "Switched to \(selection.server.name).\(updated) Try signing in or refreshing again."
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

/// When the user last applied the recommended server from GitHub.
private struct AnisetteRemoteRecord: Codable {
    private static let key = "sidekick.anisette.remote.applied.v1"
    let serverID: String
    let appliedAt: Date

    static func load() -> AnisetteRemoteRecord? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
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
    @State private var cleanReport: String?

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
        .messageAlert("Couldn’t Update Storage", message: $errorMessage)
        .messageAlert("Storage Cleaned", message: $cleanReport)
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
            Text("Tap a folder to see what’s using space. iOS Storage may count differently.")
        }
    }

    private var importedIPAsSection: some View {
        Section {
            LabeledContent("Downloaded IPAs", value: "\(removableImportedApps.count) · \(storageUsage.formatted(storageUsage.importedIPAs))")
            if storageUsage.importedIPAs > 0 {
                SwiftUI.Button("Review Downloaded IPAs…") {
                    selectedRemovalKeys.removeAll()
                    isShowingClearReview = true
                }
            }
        } header: {
            Text("Imported IPAs")
        } footer: {
            Text("Files you opened from the Files app stay where they are.")
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
                    Label("Clean Unused Files", systemImage: "sparkles")
                    Spacer()
                    if isCleaning { ProgressView() }
                }
            }
            .disabled(isCleaning)
        } header: {
            Text("Signing & Temporary Files")
        } footer: {
            Text("SideKick keeps each app’s source so it can re-sign it. Cleaning removes expired sources and caches; recent sources are kept for 24 hours.")
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
            Text("Removed IPAs disappear from Ready to Install and downloaded updates. Installed apps aren’t affected.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var removableIPAsSection: some View {
        Section {
            ForEach(Array(removableImportedApps.enumerated()), id: \.offset) { entry in
                removalRow(for: entry.element)
            }
        } header: {
            HStack {
                Text("\(selectedRemovalApps.count) of \(removableImportedApps.count) Selected")
                Spacer()
                SwiftUI.Button(selectedRemovalApps.count == removableImportedApps.count ? "Deselect All" : "Select All") {
                    if selectedRemovalApps.count == removableImportedApps.count { selectedRemovalKeys.removeAll() }
                    else { selectedRemovalKeys = Set(removableImportedApps.map(removalKey(for:))) }
                }
                .font(.subheadline.weight(.semibold))
                .textCase(nil)
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
                    Text("\(app.version) · \(app.isUpdateQueued ? "Downloaded update" : "Ready to install")")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: selectedRemovalKeys.contains(key) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selectedRemovalKeys.contains(key) ? Color.sideKickAccent : Color.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedRemovalKeys.contains(key) ? .isSelected : [])
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
            cleanReport = report
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
