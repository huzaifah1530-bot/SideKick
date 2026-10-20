import Foundation
import Minimuxer
import Observation
import UIKit

/// The local connection to this iPhone. SideKick relies on the LocalDevVPN app for the
/// loopback tunnel and only verifies the paired device here.
@MainActor
@Observable
final class LocalVPNService {
    static let shared = LocalVPNService()
    private(set) var externalTunnelConnected = false
    private(set) var lastError: String?
    var isConnectionReady: Bool { externalConnected }
    var externalInstalled: Bool { UIApplication.shared.canOpenURL(Self.externalURL) }
    var externalConnected: Bool {
        Minimuxer.shared.network.activeInterfaces.contains {
            $0.name.lowercased().hasPrefix("utun") && $0.ip.hasPrefix("10.7.")
        }
    }
    static let externalURL = URL(string: "localdevvpn://enable?scheme=sidestore")!
    static let externalStoreURL = URL(string: "https://apps.apple.com/app/id6755608044")!
    private var leases: Set<UUID> = []
    private var connectionTask: Task<Void, Error>?
    var isBusy: Bool { !leases.isEmpty }
    var statusLabel: String { externalTunnelConnected ? "Connected" : "Connect LocalDevVPN" }

    private init() {
        // The built-in VPN was removed; forget its old mode choice.
        UserDefaults.standard.removeObject(forKey: "sidekick.connection.mode")
    }

    func refreshStatus() async {
        // Network interface changes can lag behind the app switch that starts LocalDevVPN.
        externalTunnelConnected = externalConnected
    }

    func acquire() async throws -> UUID {
        return try await SideKickDiagnostics.perform(DiagnosticsStore.operationID == nil ? .connection : DiagnosticsStore.operation, stage: .localConnection) {
            return try await performAcquire()
        }
    }

    private func performAcquire() async throws -> UUID {
        let lease = UUID()
        leases.insert(lease)
        do {
            if connectionTask == nil {
                connectionTask = Task { try await connect() }
            }
            try await connectionTask!.value
            try Task.checkCancellation()
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
    }

    func withConnection<T>(_ operation: () async throws -> T) async throws -> T {
        let lease = try await acquire()
        defer { release(lease) }
        return try await operation()
    }

    private func connect() async throws {
        try Task.checkCancellation()
        // Interface addresses are a UI hint; verify the paired device itself.
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

    private func readable(_ error: Error) -> String {
        if let error = error as? LocalVPNError { return error.localizedDescription }
        return "SideKick couldn’t reach this iPhone. Connect LocalDevVPN, check the pairing file, then try again. \(error.localizedDescription)"
    }
}

enum LocalVPNError: LocalizedError {
    case pairingRequired, inUse, externalNotConnected, connection(String)
    var errorDescription: String? {
        switch self {
        case .externalNotConnected: "Connect LocalDevVPN, then return to SideKick and try again. For a scheduled refresh, its local tunnel must already be connected."
        case .pairingRequired: "Import a pairing file for this iPhone in Settings → Connection & Pairing before using the local connection."
        case .inUse: "A SideKick operation is using the local connection. Wait for it to finish, then try again."
        case .connection(let message): message
        }
    }
}
