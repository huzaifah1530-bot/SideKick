import SwiftUI
import UniformTypeIdentifiers

struct RefreshSettingsView: View {
    @AppStorage("isBackgroundRefreshEnabled") private var backgroundRefresh = true
    @AppStorage("isIdleTimeoutDisableEnabled") private var keepScreenAwake = true
    @AppStorage("isCellularRefreshEnabled") private var cellularRefresh = false
    @AppStorage("isBackgroundServiceEnabled") private var keepAliveEnabled = true
    @AppStorage("backgroundServiceMode") private var keepAliveMode = "audio"

    var body: some View {
        Form {
            Section {
                Toggle("Automatic app refresh", isOn: $backgroundRefresh)
                Toggle("Keep SideKick active during refresh", isOn: $keepScreenAwake)
                Toggle("Refresh over cellular", isOn: $cellularRefresh)
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
                .onChange(of: keepAliveMode) { _, value in
                    BackgroundServiceManager.switchTo(mode: BackgroundServiceMode(rawValue: value) ?? .audio)
                }
            } header: {
                Text("Background keep-alive")
            } footer: {
                Text("SideStore’s background service can help keep its refresh helper available. iOS may still pause background work.")
            }
        }
        .navigationTitle("App Refresh")
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
            } header: {
                Text("Signing")
            } footer: {
                Text("The app limit option depends on iOS and account type. Disabling it can make installs fail if Apple’s limit is reached.")
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
    @AppStorage("useLocalVPN") private var useLocalVPN = true
    @AppStorage("isAutoRetryRemotePairingPortEnabled") private var autoRetryPort = true
    @AppStorage("remotePairingPortOverride") private var portOverride = 0
    @AppStorage("acceptIPv6ConnectionConfig") private var allowIPv6 = false
    @State private var isChoosingPairingFile = false
    @State private var pairingStatus: String?
    @State private var isShowingPairingStatus = false

    var body: some View {
        Form {
            Section {
                Toggle("Use Local VPN for device connection", isOn: $useLocalVPN)
                Toggle("Retry remote pairing ports automatically", isOn: $autoRetryPort)
                Stepper(value: $portOverride, in: 0...65_535) {
                    LabeledContent("Remote pairing port", value: portOverride == 0 ? "Automatic" : String(portOverride))
                }
                Toggle("Accept IPv6 connection configuration", isOn: $allowIPv6)
            } header: {
                Text("Pairing")
            } footer: {
                Text("Set the port to Automatic unless your pairing setup requires a fixed port. LocalDevVPN must be connected separately before SideKick can contact this iPhone.")
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
        do {
            guard let url = try result.get().first else { return }
            UserDefaults.standard.set(false, forKey: "sidekick.setup.pairing-verified")
            try PairingSetupImporter.importFile(from: url)
            guard let pairingContent = PairingFileManager.shared.fetchPairingFile() else {
                throw PairingSetupError.unreadableFile
            }
            try await AppBootManager.shared.startMinimuxer(pairingFile: pairingContent)
            do {
                try await ensureMinimuxerReady()
                _ = try await fetchUDID(forceLive: true)
                UserDefaults.standard.set(true, forKey: "sidekick.setup.pairing-verified")
                pairingStatus = "Pairing is set up and SideKick can reach this iPhone. Install and refresh are ready."
            } catch {
                pairingStatus = "Pairing file imported. SideKick couldn’t reach the iPhone yet. Connect to Wi-Fi, open LocalDevVPN, tap Connect, then retry an install or refresh.\n\n\(error.localizedDescription)"
            }
        } catch {
            pairingStatus = "SideKick couldn’t import that pairing file. Make sure it was created for this iPhone and try again.\n\n\(error.localizedDescription)"
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
    @AppStorage("isAnisetteOfflineMode") private var offlineMode = false
    @AppStorage("menuAnisetteURL") private var serverURL = ""
    @AppStorage("menuAnisetteList") private var serverListURL = ""

    var body: some View {
        Form {
            Section {
                Toggle("Generate Anisette on this device", isOn: $useOnDeviceAnisette)
                Toggle("Offline mode", isOn: $offlineMode)
                if !useOnDeviceAnisette {
                    TextField("Anisette server URL", text: $serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Server list URL", text: $serverListURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            } header: {
                Text("Authentication data")
            } footer: {
                Text("Anisette is used by Apple ID authentication. Keep the recommended on-device option unless you have configured a trusted compatible server.")
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
    @State private var managedBytes: Int64 = 0
    @State private var isConfirmingClear = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                LabeledContent("Items", value: "\(importedApps.count)")
                LabeledContent("SideKick storage", value: ByteCountFormatter.string(fromByteCount: managedBytes, countStyle: .file))
                if managedBytes > 0 {
                    SwiftUI.Button("Remove downloaded IPA copies", role: .destructive) {
                        isConfirmingClear = true
                    }
                }
            } header: {
                Text("Imported IPAs")
            } footer: {
                Text("This removes IPA copies stored by SideKick. Files linked from the Files app remain in their original location.")
            }

            Section("SideStore data") {
                Text("Signing records and app metadata are managed by SideStore. Removing an imported IPA does not uninstall its app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
        do {
            importedApps = try await environment.ipaImportStore.importedApps()
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ImportedIPAs", isDirectory: true)
            managedBytes = importedApps.compactMap { app -> Int64? in
                guard let fileName = app.fileName,
                      let values = try? directory.appendingPathComponent(fileName).resourceValues(forKeys: [.fileSizeKey]),
                      let size = values.fileSize else { return nil }
                return Int64(size)
            }.reduce(0, +)
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
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
