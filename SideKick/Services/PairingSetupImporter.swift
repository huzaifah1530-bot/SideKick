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
        let protocolToUse: PairingProtocol
        do {
            _ = try manager.parse(content: contents, preferred: .lockdown)
            protocolToUse = .lockdown
        } catch {
            _ = try manager.parse(content: contents, preferred: .rppairing)
            protocolToUse = .rppairing
        }

        _ = try manager.savePairingFile(contents: contents, preferred: protocolToUse)
        manager.preferredProtocol = protocolToUse
        manager.persistedActiveProtocol = protocolToUse
    }
}
