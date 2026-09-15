import CTractandaPlatform
import Foundation

/// Decoded RFC 9562 UUIDv1 fields. A node identifies the issuer, not the content's author.
public struct UUIDVersion1Components: Equatable, Sendable, Encodable {
    public static let unixEpochOffset: UInt64 = 0x01B2_1DD2_1381_4000
    public static let ticksPerSecond: UInt64 = 10_000_000
    public let timestamp: UInt64
    public let clockSequence: UInt16
    public let node: UInt64

    /// The original 60-bit Gregorian timestamp is retained without floating-point conversion.
    public init(timestamp: UInt64, clockSequence: UInt16, node: UInt64) throws {
        guard timestamp < (1 << 60), clockSequence < (1 << 14), node < (1 << 48) else {
            throw TractandaError(
                "invalidUUID", "UUIDv1 requires a 60-bit timestamp, 14-bit clock sequence and 48-bit node.")
        }
        self.timestamp = timestamp
        self.clockSequence = clockSequence
        self.node = node
    }

    public init(_ uuid: UUID) throws {
        var raw = uuid.uuid
        let bytes = withUnsafeBytes(of: &raw) { Array($0) }
        guard bytes[6] >> 4 == 1, bytes[8] & 0xC0 == 0x80 else {
            throw TractandaError("invalidUUID", "Expected an RFC UUID version 1.")
        }
        let low = bytes[0..<4].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let middle = (UInt64(bytes[4]) << 8) | UInt64(bytes[5])
        let high = (UInt64(bytes[6] & 0x0F) << 8) | UInt64(bytes[7])
        try self.init(
            timestamp: (high << 48) | (middle << 32) | low,
            clockSequence: (UInt16(bytes[8] & 0x3F) << 8) | UInt16(bytes[9]),
            node: bytes[10..<16].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
    }

    public var uuid: UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        func put(_ value: UInt64, at start: Int, count: Int) {
            for offset in 0..<count {
                bytes[start + offset] = UInt8(truncatingIfNeeded: value >> ((count - offset - 1) * 8))
            }
        }
        put(timestamp & 0xFFFF_FFFF, at: 0, count: 4)
        put((timestamp >> 32) & 0xFFFF, at: 4, count: 2)
        put(((timestamp >> 48) & 0x0FFF) | 0x1000, at: 6, count: 2)
        put(UInt64(clockSequence) | 0x8000, at: 8, count: 2)
        put(node, at: 10, count: 6)
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }

    public var date: Date {
        let ticks = Int64(timestamp) - Int64(Self.unixEpochOffset)
        return Date(timeIntervalSince1970: Double(ticks) / Double(Self.ticksPerSecond))
    }

    public var nodeAddress: String {
        (0..<6).map { String(format: "%02x", (node >> ((5 - $0) * 8)) & 0xFF) }.joined(separator: ":")
    }

    /// RFC-generated node values set the multicast bit. A clear bit is not proof of hardware authenticity.
    public var isGeneratedNode: Bool { node & (1 << 40) != 0 }

    public var isLocallyAdministeredNode: Bool { node & (1 << 41) != 0 }

    /// Timestamp text keeps all seven fractional digits represented by UUIDv1's 100 ns ticks.
    public var timestampUTC: String {
        let ticks = Int64(timestamp) - Int64(Self.unixEpochOffset)
        let divisor = Int64(Self.ticksPerSecond)
        let seconds = ticks >= 0 ? ticks / divisor : (ticks - divisor + 1) / divisor
        let fraction = ticks - seconds * divisor
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let whole = formatter.string(from: Date(timeIntervalSince1970: Double(seconds)))
        return String(whole.dropLast()) + String(format: ".%07lldZ", fraction)
    }
}

extension UUID {
    /// Generate UUIDv1 using the platform time/clock sequence and the selected permanent hardware MAC.
    /// macOS supplies this in libc; Debian supplies libuuid. Random capabilities use a separate API.
    public static func makeVersion1() throws -> UUID {
        let node = try UUIDHardwareNode.current().node
        var bytes = [UInt8](repeating: 0, count: 16)
        guard tractanda_uuid_v1(&bytes) == 0 else {
            throw TractandaError("uuidGenerationFailed", "The platform could not generate a time-based UUID.")
        }
        let uuid = UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
        let components = try UUIDVersion1Components(uuid)
        return try UUIDVersion1Components(
            timestamp: components.timestamp, clockSequence: components.clockSequence, node: node
        ).uuid
    }

    public var version1Components: UUIDVersion1Components? { try? UUIDVersion1Components(self) }
}
