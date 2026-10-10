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
        }
        .navigationTitle("App Refresh")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { locationAccess = CLLocationManager().authorizationStatus }
        }
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
    @State private var isChoosingPairingFile = false
    @State private var pairingStatus: String?
    @State private var isShowingPairingStatus = false

    var body: some View {
        Form {
            Section {
                NavigationLink { LocalConnectionSettingsView() } label: {
                    Label("Local Connection", systemImage: "network.badge.shield.half.filled")
                }
                .fullWidthListSeparators()
                Toggle("Retry remote pairing ports automatically", isOn: $autoRetryPort)
                Stepper(value: $portOverride, in: 0...65_535) {
                    LabeledContent("Remote pairing port", value: portOverride == 0 ? "Automatic" : String(portOverride))
                }
                .onChange(of: portOverride) { _, _ in syncMinimuxerBackendFromUserDefaults() }
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
        .fileImporter(
            isPresented: $isChoosingPairingFile,
            allowedContentTypes: PairingFileManager.supportedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            Task { await importPairingFile(result) }
        }
        .alert("Device pairing", isPresented: $isShowingPairingStatus) {
            SwiftUI.Button("OK", role: .cancel) { pairingStatus = nil }
        } message: {
            Text(pairingStatus ?? "")
        }
    }

    @MainActor
    private func importPairingFile(_ result: Result<[URL], Error>) async {
        var didImport = false
        do {
            guard let url = try result.get().first else { return }
            UserDefaults.standard.set(false, forKey: "sidekick.setup.pairing-verified")
            try PairingSetupImporter.importFile(from: url)
            didImport = true
            guard PairingFileManager.shared.fetchPairingFile() != nil else {
                throw PairingSetupError.unreadableFile
            }
            let vpnLease = try await LocalVPNService.shared.acquire()
            defer { LocalVPNService.shared.release(vpnLease) }
            do {
                try await ensureMinimuxerReady()
                _ = try await fetchUDID(forceLive: true)
                UserDefaults.standard.set(true, forKey: "sidekick.setup.pairing-verified")
                pairingStatus = "Pairing is set up and SideKick can reach this iPhone. Install and refresh are ready."
            } catch {
                pairingStatus = "Pairing file imported. SideKick couldn’t reach the iPhone yet. Allow SideKick’s Local Connection in Settings, check that this pairing file belongs to your iPhone, then retry.\n\n\(error.localizedDescription)"
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
    @AppStorage("useOnDeviceAnisette") private var useOnDeviceAnisette = true

    var body: some View {
        Form {
            Section {
                Toggle("Generate Anisette on this device", isOn: $useOnDeviceAnisette)
                NavigationLink {
                    AnisetteServersView()
                } label: {
                    Label("Servers & Server Lists", systemImage: "server.rack")
                }
                .fullWidthListSeparators()
            } header: {
                Text("Authentication data")
            } footer: {
                Text("Anisette is used by Apple ID authentication. Server management supports selecting or adding a server, importing a saved list, and updating the catalogue. Changes apply to the next authentication request.")
            }

            Section {
                LabeledContent("Mode", value: useOnDeviceAnisette ? "On this device" : "Remote server")
            } header: {
                Text("Current setup")
            }
        }
        .navigationTitle("Anisette")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SettingsStorageView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var importedApps: [ImportedIPA] = []
    @State private var storageUsage = SideKickStorageUsage()
    @State private var isMeasuring = false
    @State private var isCleaning = false
    @State private var isConfirmingClear = false
    @State private var errorMessage: String?

    var body: some View {
        List {
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
            Section {
                LabeledContent("Items", value: "\(importedApps.count)")
                LabeledContent("Downloaded IPA copies", value: storageUsage.formatted(storageUsage.importedIPAs))
                if storageUsage.importedIPAs > 0 {
                    SwiftUI.Button("Remove downloaded IPA copies", role: .destructive) {
                        isConfirmingClear = true
                    }
                }
            } header: {
                Text("Imported IPAs")
            } footer: {
                Text("This removes IPA copies stored by SideKick. Files linked from the Files app remain in their original location.")
            }

            Section {
                LabeledContent("App signing cache", value: storageUsage.formatted(storageUsage.signingCache))
                LabeledContent("Temporary install files", value: storageUsage.formatted(storageUsage.temporaryFiles))
                LabeledContent("Saved resigned IPAs", value: storageUsage.formatted(storageUsage.exportedIPAs))
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
                Text("SideKick keeps the current extracted source for each app so it can re-sign it. Extracted apps can be larger than their compressed IPAs. Cleanup removes unused caches and abandoned temporary files. Saved resigned IPAs and app records are kept.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
        .alert("Remove downloaded IPA copies?", isPresented: $isConfirmingClear) {
            SwiftUI.Button("Remove", role: .destructive) { Task { await clearManagedIPAs() } }
            SwiftUI.Button("Cancel", role: .cancel) { }
        } message: {
            Text("This only removes IPA files saved inside SideKick. Installed apps and files in Files are not affected.")
        }
        .alert("Storage", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            SwiftUI.Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
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
    private func clearManagedIPAs() async {
        do {
            for app in importedApps where app.fileName != nil {
                try await environment.ipaImportStore.delete(app)
            }
            try await environment.ipaImportStore.cleanupOrphanedManagedIPAs()
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func cleanUnusedFiles() async {
        guard !isCleaning else { return }
        isCleaning = true
        defer { isCleaning = false }
        do {
            URLCache.shared.removeAllCachedResponses()
            await environment.ipaImportStore.cleanupAbandonedTemporaryIPAImports()
            try await environment.ipaImportStore.cleanupOrphanedManagedIPAs()
            await SideStoreOperationService.pruneUnusedCaches()
            await reload()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct StorageDirectoryDetailView: View {
    let directory: StorageDirectoryUsage
    @State private var entries: [StorageDirectoryUsage] = []
    @State private var isLoading = true

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
                }
            }
        }
        .navigationTitle(directory.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        isLoading = true
        entries = await SideKickStorageUsage.children(of: directory.url)
        isLoading = false
    }
}
