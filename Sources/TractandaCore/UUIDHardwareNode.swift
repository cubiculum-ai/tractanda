import CTractandaPlatform
import Foundation

#if os(macOS)
    import IOKit
#endif

/// A hardware-reported or explicitly configured permanent MAC used by the UUIDv1 issuer.
public struct UUIDHardwareNode: Sendable, Encodable {
    public let node: UInt64
    public let interfaceName: String?
    public let source: String
    public let isBuiltIn: Bool

    public var address: String {
        (0..<6).map { String(format: "%02x", (node >> ((5 - $0) * 8)) & 0xFF) }.joined(separator: ":")
    }

    private static let cached: Result<UUIDHardwareNode, any Error> = Result { try discover() }

    /// Fixed for the process lifetime. Containers can receive their host's permanent MAC explicitly.
    public static func current() throws -> UUIDHardwareNode { try cached.get() }

    private static func isHardwareAddress(_ node: UInt64) -> Bool {
        node > 0 && node < (1 << 48) && node & (3 << 40) == 0
    }

    static func select(_ candidates: [UUIDHardwareNode]) -> UUIDHardwareNode? {
        candidates.filter { isHardwareAddress($0.node) }.min {
            let aIsEn0 = $0.interfaceName == "en0"
            let bIsEn0 = $1.interfaceName == "en0"
            if aIsEn0 != bIsEn0 { return aIsEn0 }
            if $0.isBuiltIn != $1.isBuiltIn { return $0.isBuiltIn }
            return ($0.interfaceName ?? "") < ($1.interfaceName ?? "")
        }
    }

    private static func discover() throws -> UUIDHardwareNode {
        if let configured = ProcessInfo.processInfo.environment["TRACTANDA_UUID_NODE"] {
            let compact = configured.replacingOccurrences(of: ":", with: "")
            guard compact.utf8.count == 12, compact.allSatisfy(\.isHexDigit),
                let node = UInt64(compact, radix: 16), isHardwareAddress(node)
            else {
                throw TractandaError(
                    "invalidUUIDNode",
                    "TRACTANDA_UUID_NODE must be a globally administered, unicast hardware MAC.")
            }
            return UUIDHardwareNode(
                node: node, interfaceName: nil, source: "configured hardware MAC", isBuiltIn: false)
        }
        #if os(macOS)
            var iterator: io_iterator_t = 0
            guard
                IOServiceGetMatchingServices(
                    kIOMainPortDefault, IOServiceMatching("IOEthernetInterface"), &iterator) == KERN_SUCCESS
            else {
                throw TractandaError("uuidNodeUnavailable", "Cannot enumerate hardware network interfaces.")
            }
            defer { IOObjectRelease(iterator) }
            var candidates: [UUIDHardwareNode] = []
            while true {
                let service = IOIteratorNext(iterator)
                guard service != 0 else { break }
                defer { IOObjectRelease(service) }
                guard
                    let name = IORegistryEntryCreateCFProperty(
                        service, "BSD Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                        as? String,
                    let data = IORegistryEntrySearchCFProperty(
                        service, kIOServicePlane, "IOMACAddress" as CFString,
                        kCFAllocatorDefault,
                        IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
                        as? Data,
                    data.count == 6
                else { continue }
                let node = data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                guard isHardwareAddress(node) else { continue }
                let builtIn =
                    IORegistryEntryCreateCFProperty(service, "IOBuiltin" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? Bool ?? false
                candidates.append(
                    UUIDHardwareNode(
                        node: node, interfaceName: name,
                        source: "IOKit IOMACAddress", isBuiltIn: builtIn))
            }
            if let selected = select(candidates) { return selected }
        #elseif os(Linux)
            var bytes = [UInt8](repeating: 0, count: 6)
            var name = [CChar](repeating: 0, count: 256)
            if tractanda_uuid_hardware_node(&bytes, &name, name.count) == 0 {
                let node = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                let interfaceName = String(
                    decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                return UUIDHardwareNode(
                    node: node, interfaceName: interfaceName,
                    source: "ETHTOOL_GPERMADDR", isBuiltIn: false)
            }
        #endif
        throw TractandaError(
            "uuidNodeUnavailable",
            "No permanent hardware MAC is available. Configure TRACTANDA_UUID_NODE with the issuer host's hardware MAC; no randomized substitute is selected."
        )
    }
}
