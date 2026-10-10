import Foundation
import NetworkExtension
import Minimuxer
import Observation
import SideSign
import UIKit

enum LocalConnectionMode: String, CaseIterable, Identifiable {
    case external, builtIn
    var id: String { rawValue }
    var title: String { self == .external ? "LocalDevVPN" : "Built-in VPN" }
}

@MainActor
@Observable
final class LocalVPNService {
    static let shared = LocalVPNService()
    private(set) var status: NEVPNStatus = .invalid
    private(set) var isConfigured = false
    private(set) var externalTunnelConnected = false
    private(set) var lastError: String?
    private(set) var preferredMode = LocalConnectionMode(rawValue: UserDefaults.standard.string(forKey: "sidekick.connection.mode") ?? "") ?? .external
    var mode: LocalConnectionMode { preferredMode == .builtIn && hasSupportedProfiles ? .builtIn : .external }
    var isConnectionReady: Bool { mode == .builtIn ? isConfigured : externalConnected }
    var externalInstalled: Bool { UIApplication.shared.canOpenURL(Self.externalURL) }
    var externalConnected: Bool {
        Minimuxer.shared.network.activeInterfaces.contains {
            $0.name.lowercased().hasPrefix("utun") && $0.ip.hasPrefix("10.7.")
        }
    }
    static let externalURL = URL(string: "localdevvpn://enable?scheme=sidestore")!
    static let externalStoreURL = URL(string: "https://apps.apple.com/app/id6755608044")!
    private var manager: NETunnelProviderManager?
    private var leases: Set<UUID> = []
    private var connectionTask: Task<Void, Error>?
    private var heartbeatTask: Task<Void, Never>?
    private var statusObserver: NSObjectProtocol?

    var isBusy: Bool { !leases.isEmpty }
    var extensionURL: URL {
        Bundle.Info.activeBundleURL.appendingPathComponent("PlugIns/SideKickVPN.appex")
    }
    var extensionBundleIdentifier: String? { Bundle(url: extensionURL)?.bundleIdentifier }
    // The installed signature is immutable until iOS replaces this process.
    private let signatureSupported: Bool = {
        let extensionURL = Bundle.Info.activeBundleURL.appendingPathComponent("PlugIns/SideKickVPN.appex")
        guard let hostApp = ALTApplication(fileURL: Bundle.Info.activeBundleURL),
              let tunnelApp = ALTApplication(fileURL: extensionURL),
              let host = hostApp.provisioningProfile, let tunnel = tunnelApp.provisioningProfile else { return false }
        let key = "com.apple.developer.networking.networkextension"
        return [host.entitlements, tunnel.entitlements, hostApp.entitlements, tunnelApp.entitlements].allSatisfy {
            ($0[key] as? [String])?.contains("packet-tunnel-provider") == true
        }
    }()
    var hasSupportedProfiles: Bool { signatureSupported }
    var statusLabel: String {
        if mode == .external { return externalTunnelConnected ? "Connected" : "Connect LocalDevVPN" }
        guard hasSupportedProfiles else { return "Unavailable" }
        return switch status {
        case .connected: "Connected"
        case .connecting, .reasserting: "Connecting"
        case .disconnecting: "Disconnecting"
        case .disconnected: "Ready"
        case .invalid: isConfigured ? "Unavailable" : "Permission Needed"
        @unknown default: "Unavailable"
        }
    }

    private init() {
        statusObserver = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.status = self?.manager?.connection.status ?? .invalid }
        }
    }

    func selectMode(_ mode: LocalConnectionMode) async throws {
        guard !isBusy else { throw LocalVPNError.inUse }
        if mode == .builtIn && !hasSupportedProfiles { throw LocalVPNError.unsupportedSignature }
        manager?.connection.stopVPNTunnel()
        preferredMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "sidekick.connection.mode")
        UserDefaults.standard.set(false, forKey: "sidekick.setup.pairing-verified")
        lastError = nil
        await refreshStatus()
    }

    func refreshStatus() async {
        externalTunnelConnected = externalConnected
        guard hasSupportedProfiles else { isConfigured = false; status = .invalid; return }
        do {
            guard let identifier = extensionBundleIdentifier else { throw LocalVPNError.missingExtension }
            let configurations = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = configurations.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == identifier }
            isConfigured = manager?.isEnabled == true
            status = manager?.connection.status ?? .invalid
            // Clean up an operation interrupted by self-reinstallation or process exit.
            if leases.isEmpty, status == .connected || status == .connecting || status == .reasserting {
                manager?.connection.stopVPNTunnel()
            }
        } catch { lastError = readable(error) }
    }

    func authorize() async throws {
        guard !isBusy else { throw LocalVPNError.inUse }
        guard extensionBundleIdentifier != nil else { throw LocalVPNError.missingExtension }
        guard hasSupportedProfiles else { throw LocalVPNError.unsupportedSignature }
        guard let identifier = extensionBundleIdentifier else { throw LocalVPNError.missingExtension }
        let configurations = try await NETunnelProviderManager.loadAllFromPreferences()
        let configuration = configurations.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == identifier } ?? NETunnelProviderManager()
        let tunnel = NETunnelProviderProtocol()
        tunnel.providerBundleIdentifier = identifier
        tunnel.serverAddress = "SideKick Local Connection"
        tunnel.providerConfiguration = ["TunnelIfaceIP": "10.7.1.1/32", "TunnelPeerIP": "10.7.0.1/32"]
        tunnel.disconnectOnSleep = false
        configuration.protocolConfiguration = tunnel
        configuration.localizedDescription = "SideKick Local Connection"
        configuration.isEnabled = true
        configuration.isOnDemandEnabled = false
        configuration.onDemandRules = []
        try await configuration.saveToPreferences()
        try await configuration.loadFromPreferences()
        manager = configuration
        isConfigured = true
        status = configuration.connection.status
        lastError = nil
        UserDefaults.standard.set(true, forKey: "useLocalVPN")
        UserDefaults.standard.set(false, forKey: "sidekick.setup.pairing-verified")
        ConnectionConfig.shared.useLocalVPN = true
    }

    func acquire() async throws -> UUID {
        let lease = UUID()
        leases.insert(lease)
        do {
            if connectionTask == nil {
                connectionTask = Task { try await connect() }
            }
            try await connectionTask!.value
            try Task.checkCancellation()
            if mode == .builtIn {
                guard manager?.connection.status == .connected else { throw LocalVPNError.timeout }
            } else if !externalConnected { throw LocalVPNError.externalNotConnected }
            return lease
        } catch {
            lastError = readable(error)
            release(lease)
            throw LocalVPNError.connection(lastError ?? error.localizedDescription)
        }
    }

    func release(_ lease: UUID) {
        leases.remove(lease)
        guard leases.isEmpty else { return }
        connectionTask?.cancel(); connectionTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        if mode == .builtIn { manager?.connection.stopVPNTunnel() }
        status = manager?.connection.status ?? .invalid
    }

    func withConnection<T>(_ operation: () async throws -> T) async throws -> T {
        let lease = try await acquire()
        defer { release(lease) }
        return try await operation()
    }

    private func connect() async throws {
        try Task.checkCancellation()
        if mode == .external {
            guard externalConnected else { throw LocalVPNError.externalNotConnected }
            try await prepareDeviceConnection()
            return
        }
        guard extensionBundleIdentifier != nil else { throw LocalVPNError.missingExtension }
        guard hasSupportedProfiles else { throw LocalVPNError.unsupportedSignature }
        await refreshStatus()
        try Task.checkCancellation()
        guard let manager, isConfigured else { throw LocalVPNError.permissionRequired }
        guard manager.isEnabled else { throw LocalVPNError.permissionRequired }
        UserDefaults.standard.set(true, forKey: "useLocalVPN")
        ConnectionConfig.shared.useLocalVPN = true
        // A previous stop can take a moment to settle before iOS permits a start.
        let deadline = Date.now.addingTimeInterval(30)
        while manager.connection.status == .disconnecting {
            try Task.checkCancellation()
            guard Date.now < deadline else { throw LocalVPNError.timeout }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        if manager.connection.status != .connected && manager.connection.status != .connecting && manager.connection.status != .reasserting {
            try manager.connection.startVPNTunnel()
        }
        while manager.connection.status != .connected {
            try Task.checkCancellation()
            status = manager.connection.status
            guard Date.now < deadline else { throw LocalVPNError.timeout }
            if status == .invalid { throw LocalVPNError.permissionRequired }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        status = .connected
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.leases.isEmpty else { return }
                if let session = self.manager?.connection as? NETunnelProviderSession {
                    do { try session.sendProviderMessage(Data("SideKick.heartbeat".utf8), responseHandler: nil) }
                    catch { self.lastError = self.readable(error) }
                }
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
            }
        }
        try await prepareDeviceConnection()
    }

    private func prepareDeviceConnection() async throws {
        UserDefaults.standard.set(true, forKey: "useLocalVPN")
        ConnectionConfig.shared.useLocalVPN = true
        guard let pairing = PairingFileManager.shared.fetchPairingFile() else { throw LocalVPNError.pairingRequired }
        UserDefaults.standard.enableEMPforWireguard = false
        try await AppBootManager.shared.startMinimuxer(pairingFile: pairing)
        try await ensureMinimuxerReady()
        try Task.checkCancellation()
        lastError = nil
    }

    func removeConfiguration() async throws {
        guard !isBusy else { throw LocalVPNError.inUse }
        manager?.connection.stopVPNTunnel()
        if let manager { try await manager.removeFromPreferences() }
        manager = nil; isConfigured = false; status = .invalid
        UserDefaults.standard.set(false, forKey: "sidekick.setup.pairing-verified")
    }

    private func readable(_ error: Error) -> String {
        if let error = error as? LocalVPNError { return error.localizedDescription }
        if mode == .external { return "SideKick couldn’t reach this iPhone. Connect LocalDevVPN, check the pairing file, then try again. \(error.localizedDescription)" }
        return "iOS couldn’t use SideKick’s local VPN. Check that VPN permission is allowed and that both SideKick and its tunnel extension were signed with the Network Extension capability. Another VPN may need to be disconnected. \(error.localizedDescription)"
    }
}

enum LocalVPNError: LocalizedError {
    case missingExtension, unsupportedSignature, permissionRequired, pairingRequired, timeout, inUse, externalNotConnected, connection(String)
    var errorDescription: String? {
        switch self {
        case .externalNotConnected: "Connect LocalDevVPN, then return to SideKick and try again. For a scheduled refresh, its local tunnel must already be connected."
        case .missingExtension: "This SideKick installation is missing its VPN extension. Reinstall the complete IPA and keep SideKickVPN enabled during signing."
        case .unsupportedSignature: "This signing profile does not support SideKick’s built-in VPN. Re-sign the app and its SideKickVPN extension with profiles that include the Network Extension capability. A free Apple ID profile cannot provide this capability."
        case .pairingRequired: "Import a pairing file for this iPhone in Settings → Connection & Pairing before using the local connection."
        case .permissionRequired: "Allow SideKick’s local VPN in Settings → Local Connection before installing or refreshing."
        case .timeout: "SideKick’s local VPN did not connect in time. Check VPN permission and disconnect any conflicting VPN, then try again."
        case .inUse: "A SideKick operation is using the local connection. Wait for it to finish before removing VPN permission."
        case .connection(let message): message
        }
    }
}
