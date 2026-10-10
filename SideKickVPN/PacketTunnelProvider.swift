//
//  PacketTunnelProvider.swift
//  TunnelProv
//
//  Created by Stossy11 on 28/03/2025.
//

import NetworkExtension
import Foundation
import Darwin
#if DEBUG
import os.log
#endif

@inline(__always)
private func tunnelLog(_ message: @autoclosure () -> String) {
#if DEBUG
    os_log("[TunnelProv] %{public}@", type: .error, message())
#endif
}


class PacketTunnelProvider: NEPacketTunnelProvider {
    private let lifecycleLock = NSLock()
    private var running = false
    private var lastHeartbeat = ProcessInfo.processInfo.systemUptime
    private var watchdog: DispatchSourceTimer?

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        if messageData == Data("SideKick.heartbeat".utf8) {
            lifecycleLock.lock()
            lastHeartbeat = ProcessInfo.processInfo.systemUptime
            lifecycleLock.unlock()
        }
        completionHandler?(Data("OK".utf8))
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        lifecycleLock.lock()
        running = false
        lifecycleLock.unlock()
        watchdog?.cancel()
        watchdog = nil
        completionHandler()
    }

    private func startWatchdog() {
        lifecycleLock.lock()
        running = true
        lastHeartbeat = ProcessInfo.processInfo.systemUptime
        lifecycleLock.unlock()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.sidekick.vpn.watchdog"))
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lifecycleLock.lock()
            let expired = ProcessInfo.processInfo.systemUptime - self.lastHeartbeat >= 90
            self.lifecycleLock.unlock()
            if expired { self.cancelTunnelWithError(nil) }
        }
        watchdog = timer
        timer.resume()
    }

    var tunnelIfaceIP: String = TunnelConstants.defaultIfaceIP
    var tunnelPeerIP: String = TunnelConstants.defaultPeerIP

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        if let options = options {
            for (key, val) in options {
                tunnelLog("startTunnel option \(key) = \(String(describing: val))")
            }
        } else {
            tunnelLog("startTunnel: options is nil")
        }

        let providerConfiguration =
            (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration

        if let ifaceIp = options?[TunnelConstants.ifaceIPConfigurationKey] as? String
            ?? providerConfiguration?[TunnelConstants.ifaceIPConfigurationKey] as? String {
            tunnelLog("TunnelIfaceIP configured as: \(ifaceIp)")
            tunnelIfaceIP = ifaceIp
        }
        if let peerIp = options?[TunnelConstants.peerIPConfigurationKey] as? String
            ?? providerConfiguration?[TunnelConstants.peerIPConfigurationKey] as? String {
            tunnelLog("TunnelPeerIP configured as: \(peerIp)")
            tunnelPeerIP = peerIp
        }

        let ifaceEndpoint = CIDREndpoint(tunnelIfaceIP, defaultPrefix: 24)
        let peerEndpoint = CIDREndpoint(tunnelPeerIP, defaultPrefix: 32)

        tunnelLog("Configuring P2P settings: peer=\(peerEndpoint.ip)/\(peerEndpoint.prefix) (\(peerEndpoint.subnetMask)), iface=\(ifaceEndpoint.ip)/\(ifaceEndpoint.prefix) (\(ifaceEndpoint.subnetMask))")

        // tunnel iface configuration
        let ifaceIPv4 = NEIPv4Settings(addresses: [ifaceEndpoint.ip], subnetMasks: [ifaceEndpoint.subnetMask])
        let tunnelDestinationIPv4Routes = [
            // actual destination routes of this VPN tunnel
            NEIPv4Route(destinationAddress: peerEndpoint.ip, subnetMask: peerEndpoint.subnetMask)
        ]
        ifaceIPv4.includedRoutes = tunnelDestinationIPv4Routes
        ifaceIPv4.excludedRoutes = [.default()]

        // Tunneling config
        let settings = NEPacketTunnelNetworkSettings(
            // NOTE: 'tunnelRemoteAddress' is just for UI concerns and is not involved in routing
            tunnelRemoteAddress: peerEndpoint.ip
        )
        settings.ipv4Settings = ifaceIPv4

        tunnelLog("Calling setTunnelNetworkSettings...")
        setTunnelNetworkSettings(settings) { error in
            if let error = error {
                tunnelLog("Failed to set settings: \(error.localizedDescription)")
                return completionHandler(error)
            }
            tunnelLog("Tunnel network settings set successfully. Starting packet loops.")
            self.startWatchdog()
            self.setPackets()
            completionHandler(nil)
        }
    }

    func setPackets() {
        packetFlow.readPackets { [self] packets, protocols in
            lifecycleLock.lock()
            let shouldContinue = running
            lifecycleLock.unlock()
            guard shouldContinue else { return }
            var modified = packets

            for i in modified.indices where protocols[i].int32Value == AF_INET && modified[i].count >= 20 {
                // Swap bytes without assuming Data's storage is UInt32-aligned.
                for offset in 0..<4 { modified[i].swapAt(12 + offset, 16 + offset) }
            }

            self.packetFlow.writePackets(modified, withProtocols: protocols)
            setPackets()
        }
    }
}
