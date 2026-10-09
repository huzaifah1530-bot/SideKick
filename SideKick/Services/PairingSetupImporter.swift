import Foundation
import MinimuxerCommon

enum PairingSetupImporter {
    static func importFile(from url: URL) throws {
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)
        guard let contents = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }

        let manager = PairingFileManager.shared
        let preferenceOrder: [PairingProtocol]
        if #available(iOS 26.4, *) {
            // On newer iOS, LocalDevVPN's loopback tunnel is compatible with
            // Remote Pairing; Lockdown additionally requires IKEv2/IPSec.
            preferenceOrder = [.rppairing, .lockdown]
        } else {
            preferenceOrder = [.lockdown, .rppairing]
        }

        var protocolToUse: PairingProtocol?
        var lastParseError: Error?
        for candidate in preferenceOrder {
            do {
                _ = try manager.parse(content: contents, preferred: candidate)
                protocolToUse = candidate
                break
            } catch {
                lastParseError = error
            }
        }
        guard let protocolToUse else {
            throw lastParseError ?? CocoaError(.fileReadCorruptFile)
        }

        _ = try manager.savePairingFile(contents: contents, preferred: protocolToUse)
        manager.preferredProtocol = protocolToUse
        manager.persistedActiveProtocol = protocolToUse
    }
}
