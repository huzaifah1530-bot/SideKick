"""Exercise the actual inserted IDevice lookup against a small native-ABI fixture."""
from pathlib import Path
import subprocess

def verify_lookup(checkout: Path, compiler: str):
    source = (checkout / 'Dependencies/minimuxer/DeviceGateway/idevice/IdeviceGateway.swift').read_text(encoding='utf-8')
    method = source[source.index('    public func lookupInstalledAppName('):source.index('    public func installIpa(')]
    fixture = r"""
import Foundation
typealias plist_t = UnsafeMutableRawPointer
struct FakeFFIError { }
enum Code { case serviceError }
struct IdeviceGatewayError: Error { init(_ code: Code, reason: String) { } }
var hasApp = true
var failLookup = false
var returnedIdentifier = "com.example.app"
var returnedName: String? = "Native App"
var queriedIdentifier = ""
var freedPlists = 0
var freedArrays = 0
var freedErrors = 0
func installation_proxy_connect_rsd() { }
func installation_proxy_connect() { }
func installation_proxy_client_free() { }
func idevice_error_free(_ error: FakeFFIError) { freedErrors += 1 }
func installation_proxy_get_apps(_ client: Int, _ applicationType: UnsafePointer<CChar>?,
    _ identifiers: UnsafeMutablePointer<UnsafePointer<CChar>?>, _ count: Int,
    _ result: UnsafeMutablePointer<UnsafeMutableRawPointer?>, _ length: UnsafeMutablePointer<Int>) -> FakeFFIError? {
    precondition(applicationType == nil && count == 1)
    queriedIdentifier = String(cString: identifiers[0]!)
    if failLookup { return FakeFFIError() }
    if hasApp {
        let array = UnsafeMutablePointer<plist_t?>.allocate(capacity: 1)
        array.initialize(to: UnsafeMutableRawPointer(bitPattern: 0x100))
        result.pointee = UnsafeMutableRawPointer(array)
        length.pointee = 1
    } else {
        // Rust's empty boxed slice is non-null but is not a malloc allocation.
        result.pointee = UnsafeMutableRawPointer(bitPattern: 8)
        length.pointee = 0
    }
    return nil
}
func idevice_plist_array_free(_ pointer: UnsafeMutablePointer<plist_t?>, _ count: Int) { freedPlists += 1 }
func idevice_outer_slice_free(_ pointer: UnsafeMutableRawPointer, _ count: Int) {
    freedArrays += 1
    if count > 0 {
        let array = pointer.assumingMemoryBound(to: plist_t?.self)
        array.deinitialize(count: count)
        array.deallocate()
    }
}
func plist_dict_get_item(_ value: plist_t, _ key: String) -> plist_t? {
    if key == "CFBundleIdentifier" { return UnsafeMutableRawPointer(bitPattern: 0x101) }
    if key == "CFBundleDisplayName", returnedName != nil { return UnsafeMutableRawPointer(bitPattern: 0x102) }
    return nil
}
func withFFIDispatch<T>(on queue: Int, _ operation: () throws -> T) async rethrows -> T { try operation() }
struct NativeOperations { let queue = 0 }
final class LookupGateway {
    let nativeOperations = NativeOperations()
    func getErrorMessage(from error: FakeFFIError) -> String { "Disconnected" }
    func getRustPlistString(_ pointer: plist_t) -> String? {
        Int(bitPattern: pointer) == 0x101 ? returnedIdentifier : returnedName
    }
    func performWithEitherService<T>(connectRP: () -> Void, connectLockdown: () -> Void,
        cleanup: () -> Void, serviceName: String, operation: (Int) throws -> T) rethrows -> T {
        precondition(serviceName == "instproxy")
        return try operation(1)
    }
METHOD
}
@main struct Main {
    static func main() async throws {
        let gateway = LookupGateway()
        let nativeName = try await gateway.lookupInstalledAppName(bundleId: "com.example.app")
        precondition(nativeName == "Native App" && queriedIdentifier == "com.example.app")
        precondition(freedPlists == 1 && freedArrays == 1)
        hasApp = false
        let missing = try await gateway.lookupInstalledAppName(bundleId: "com.example.new")
        precondition(missing == nil && freedPlists == 2 && freedArrays == 2)
        failLookup = true
        do {
            _ = try await gateway.lookupInstalledAppName(bundleId: "com.example.app")
            fatalError("Lookup failure was incorrectly treated as app absence")
        } catch { }
        precondition(freedErrors == 1)
        failLookup = false
        hasApp = true
        returnedName = nil
        let fallback = try await gateway.lookupInstalledAppName(bundleId: "com.example.app")
        precondition(fallback == "com.example.app")
        returnedName = "Unrelated app"
        returnedIdentifier = "com.unrelated"
        let unmatched = try await gateway.lookupInstalledAppName(bundleId: "com.example.app")
        precondition(unmatched == nil)
    }
}
""".replace('METHOD', method)
    path = checkout / 'InstallLookup.swift'
    path.write_text(fixture, encoding='utf-8')
    binary = checkout / 'install-lookup'
    subprocess.run([compiler, '-swift-version', '5', '-parse-as-library', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
