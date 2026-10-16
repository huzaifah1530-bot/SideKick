import Foundation
import Darwin

@main
struct NetworkIPv4Regression {
    static func info(maskBytes: [UInt8], family: UInt8 = UInt8(AF_INET), declaredLength: Int? = nil,
                     hostLength: UInt8 = UInt8(MemoryLayout<sockaddr_in>.size), hostFamily: UInt8 = UInt8(AF_INET)) -> IPv4Info? {
        var address = sockaddr_in()
        address.sin_len = hostLength
        address.sin_family = hostFamily
        precondition(inet_pton(AF_INET, "10.7.1.1", &address.sin_addr) == 1)
        let length = declaredLength ?? maskBytes.count + 4
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(2, max(length, maskBytes.count + 4)), alignment: MemoryLayout<sockaddr>.alignment)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: max(2, max(length, maskBytes.count + 4)))
        buffer.storeBytes(of: UInt8(length), as: UInt8.self)
        buffer.storeBytes(of: family, toByteOffset: 1, as: UInt8.self)
        for (index, byte) in maskBytes.enumerated() {
            buffer.storeBytes(of: byte, toByteOffset: index + 4, as: UInt8.self)
        }
        return withUnsafeMutablePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { host in
                var entry = ifaddrs()
                entry.ifa_addr = host
                entry.ifa_netmask = buffer.assumingMemoryBound(to: sockaddr.self)
                return IPv4Info(ifa: entry)
            }
        }
    }

    static func main() {
        // Darwin in_socktrim drops trailing zero mask bytes: /8 uses sa_len=5.
        guard info(maskBytes: [255])?.mask == "255.0.0.0" else {
            fputs("REGRESSION: valid compact Darwin /8 mask dropped the IPv4 interface\n", stderr)
            exit(1)
        }
        for family in [UInt8(AF_INET), UInt8(AF_UNSPEC)] {
            precondition(info(maskBytes: [], family: family, declaredLength: 0)?.mask == "0.0.0.0")
            precondition(info(maskBytes: [255, 255, 255], family: family)?.mask == "255.255.255.0")
            precondition(info(maskBytes: [255, 255, 255, 255], family: family)?.mask == "255.255.255.255")
            precondition(info(maskBytes: [255, 255, 255, 0], family: family, declaredLength: 16)?.networkBase == 0x0a070100)
        }
        precondition(info(maskBytes: [], declaredLength: 1) == nil)
        precondition(info(maskBytes: [], declaredLength: 17) == nil)
        precondition(info(maskBytes: [255], family: UInt8(AF_INET6)) == nil)
        precondition(info(maskBytes: [255], hostLength: 5) == nil)
        precondition(info(maskBytes: [255], hostFamily: UInt8(AF_UNSPEC)) == nil)

        var entries: UnsafeMutablePointer<ifaddrs>?
        precondition(getifaddrs(&entries) == 0)
        defer { freeifaddrs(entries) }
        var cursor = entries
        var sawLoopback = false
        while let entry = cursor?.pointee {
            if String(cString: entry.ifa_name) == "lo0", entry.ifa_addr?.pointee.sa_family == UInt8(AF_INET) {
                precondition(IPv4Info(ifa: entry)?.host == "127.0.0.1", "Live Darwin loopback IPv4 must survive scanning")
                sawLoopback = true
            }
            cursor = entry.ifa_next
        }
        precondition(sawLoopback, "Expected live Darwin IPv4 loopback")
        print("IPv4 regression: compact/full masks, bounds, unsupported family and live loopback passed")
    }
}
