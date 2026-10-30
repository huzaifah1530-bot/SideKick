"""Review the final signed installation ID before any native app replacement."""
from pathlib import Path
import sys
path = Path(sys.argv[1]) / "SideStore/Core/Operations/PipelineOperations/InstallAppOperation.swift"
source = path.read_text(encoding="utf-8")
anchor = "        let authTeam = try await AuthManager.shared.getAuthenticatedTeam()\n        do {"
if source.count(anchor) != 1:
    raise SystemExit("Expected one final installation review anchor")
source = source.replace(anchor, """        let authTeam = try await AuthManager.shared.getAuthenticatedTeam()
        try await NativeInstallReplacementReview.review(finalIdentifier: resignedAppBundle.bundleIdentifier)
        do {""")
path.write_text(source, encoding="utf-8")

# Read one exact bundle ID from installation_proxy, including apps installed
# outside SideKick. Query errors remain errors, never "not installed".
root = Path(sys.argv[1])
mini = root / "Dependencies/minimuxer"
def edit(path, anchor, replacement):
    source = path.read_text(encoding="utf-8")
    if source.count(anchor) != 1:
        raise SystemExit(f"Expected one app lookup integration anchor in {path}: {anchor!r}")
    path.write_text(source.replace(anchor, replacement), encoding="utf-8")

edit(mini / "DeviceGateway/DeviceGatewayAPI.swift",
     "    func installIpa(bundleId: String) async throws",
     "    func lookupInstalledAppName(bundleId: String) async throws -> String?\n    func installIpa(bundleId: String) async throws")
# Default keeps external/mock gateways source-compatible and fails closed.
edit(mini / "DeviceGateway/DeviceGatewayAPI.swift", "public extension DeviceGatewayAPI {",
     """public extension DeviceGatewayAPI {
    func lookupInstalledAppName(bundleId: String) async throws -> String? {
        throw NSError(domain: "SideKick.InstallationLookup", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "This device gateway does not support checking installed apps."])
    }
""")

# IDevice v0.1.68-ss-3e55c84: installation_proxy_get_apps takes an application-type C string.
# Its plist array and outer Rust allocation must be released with their matching ABI helpers.
idevice = """    public func lookupInstalledAppName(bundleId: String) async throws -> String? {
        try await withFFIDispatch(on: nativeOperations.queue) {
            try self.performWithEitherService(connectRP: installation_proxy_connect_rsd,
                connectLockdown: installation_proxy_connect, cleanup: installation_proxy_client_free,
                serviceName: "instproxy") { client in
                var result: UnsafeMutableRawPointer? = nil
                var count: Int = 0
                defer {
                    if let result, count >= 0 {
                        idevice_plist_array_free(result.assumingMemoryBound(to: plist_t?.self), UInt(count))
                        idevice_outer_slice_free(result, UInt(count))
                    }
                }
                try bundleId.withCString { identifier in
                    var identifiers: [UnsafePointer<CChar>?] = [identifier]
                    if let error = installation_proxy_get_apps(client, nil, &identifiers, 1, &result, &count) {
                        let reason = self.getErrorMessage(from: error)
                        idevice_error_free(error)
                        throw IdeviceGatewayError(.serviceError, reason: "Installed app lookup failed: " + reason)
                    }
                }
                guard count >= 0, count == 0 || result != nil else {
                    throw IdeviceGatewayError(.serviceError, reason: "Installed app lookup returned invalid results")
                }
                guard count > 0, let result else { return nil }
                let values = result.assumingMemoryBound(to: plist_t?.self)
                for index in 0..<count {
                    guard let value = values[index],
                          let node = plist_dict_get_item(value, "CFBundleIdentifier"),
                          let identifier = self.getRustPlistString(node) else {
                        throw IdeviceGatewayError(.serviceError, reason: "Installed app lookup returned an invalid app entry")
                    }
                    guard identifier.caseInsensitiveCompare(bundleId) == .orderedSame else { continue }
                    for key in ["CFBundleDisplayName", "CFBundleName"] {
                        if let node = plist_dict_get_item(value, key), let name = self.getRustPlistString(node), !name.isEmpty { return name }
                    }
                    return identifier
                }
                return nil
            }
        }
    }

"""
edit(mini / "DeviceGateway/idevice/IdeviceGateway.swift",
     "    public func installIpa(bundleId: String) async throws {", idevice + "    public func installIpa(bundleId: String) async throws {")

legacy = """    public func lookupInstalledAppName(bundleId: String) async throws -> String? {
        try await withFFIDispatch(on: nativeOperations.queue) {
            if self.pairingFileType == .rppairing {
                return try self.withRSDService(.installationProxy) { stream in
                    try self.rsdSendPlist(stream, dict: ["Command": "Lookup",
                        "ClientOptions": ["ApplicationType": "Any", "BundleIDs": [bundleId]]])
                    while true {
                        let response = try self.rsdRecvPlist(stream)
                        if let error = response["Error"] as? String {
                            throw LibimobiledeviceGatewayError(.serviceError, reason: "Installed app lookup failed: " + error)
                        }
                        if let results = response["LookupResult"] as? [String: Any] {
                            guard let match = results.first(where: { $0.key.caseInsensitiveCompare(bundleId) == .orderedSame }) else { return nil }
                            guard let app = match.value as? [String: Any] else {
                                throw LibimobiledeviceGatewayError(.serviceError, reason: "Installed app lookup returned an invalid app entry")
                            }
                            return (app["CFBundleDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                                ?? (app["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? bundleId
                        }
                        if response["Status"] as? String == "Complete" {
                            throw LibimobiledeviceGatewayError(.serviceError, reason: "Installed app lookup completed without results")
                        }
                    }
                }
            }
            return try self.withService(service: .installationProxy,
                create: instproxy_client_new, cleanup: instproxy_client_free) { client in
                let options = plist_new_dict()
                defer { plist_free(options) }
                plist_dict_set_item(options, "ApplicationType", plist_new_string("Any"))
                var result: plist_t? = nil
                defer { if let result { plist_free(result) } }
                let status = bundleId.withCString { identifier in
                    var identifiers: [UnsafePointer<CChar>?] = [identifier, nil]
                    return instproxy_lookup(client, &identifiers, options, &result)
                }
                guard status == INSTPROXY_E_SUCCESS, let result else {
                    throw LibimobiledeviceGatewayError(.serviceError, reason: "Installed app lookup failed: code " + String(status.rawValue))
                }
                var xml: UnsafeMutablePointer<CChar>? = nil
                var length: UInt32 = 0
                let serialization = plist_to_xml(result, &xml, &length)
                guard serialization == PLIST_ERR_SUCCESS, let xml else {
                    throw LibimobiledeviceGatewayError(.serviceError, reason: "Installed app lookup returned unreadable results")
                }
                defer { free(xml) }
                let data = Data(bytes: xml, count: Int(length))
                guard let results = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                    throw LibimobiledeviceGatewayError(.serviceError, reason: "Installed app lookup returned invalid results")
                }
                guard let match = results.first(where: { $0.key.caseInsensitiveCompare(bundleId) == .orderedSame }) else { return nil }
                guard let app = match.value as? [String: Any] else {
                    throw LibimobiledeviceGatewayError(.serviceError, reason: "Installed app lookup returned an invalid app entry")
                }
                return (app["CFBundleDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                                ?? (app["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? bundleId
            }
        }
    }

"""
edit(mini / "DeviceGateway/libimobiledevice/LibimobiledeviceGateway.swift",
     "    public func installIpa(bundleId: String) async throws {", legacy + "    public func installIpa(bundleId: String) async throws {")

edit(root / "SideStore/Core/DeviceApi/MinimuxerWrapper.swift", "func installIPA(_ bundleId: String) async throws {",
     """func lookupInstalledAppName(_ bundleId: String) async throws -> String? {
    try await withRemotePairingRetry {
        try await minimuxer.gateway.lookupInstalledAppName(bundleId: bundleId)
    }
}

func installIPA(_ bundleId: String) async throws {""")
