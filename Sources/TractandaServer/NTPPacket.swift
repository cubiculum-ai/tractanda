import Foundation
import TractandaCore

/// Unauthenticated NTP drift evidence, not a trustworthy-time or server identity proof.
enum NTPPacket {
    enum Invalid: Error { case packet, time }
    static let localTimestampAllowance: Double = 0.001
    static let maximumWallStep: Double = 0.1
    private static let epoch: Double = 2_208_988_800
    private static let era: Double = 4_294_967_296

    static func request(nonce: UInt64) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 48)
        bytes[0] = 0x23  // LI=0, version=4, client mode=3.
        for index in 0..<8 { bytes[40 + index] = UInt8(truncatingIfNeeded: nonce >> (56 - index * 8)) }
        return bytes
    }

    static func sample(
        response: [UInt8], nonce: UInt64, sentWall: Double, receivedWall: Double,
        elapsed: Double, timeout: Double
    ) throws -> PeerClockHealth.Sample {
        guard response.count == 48, response[0] >> 6 != 3,
            [3, 4].contains((response[0] >> 3) & 7), response[0] & 7 == 4,
            (1...15).contains(response[1]), word64(response, 24) == nonce,
            word64(response, 32) != 0, word64(response, 40) != 0
        else { throw Invalid.packet }
        guard sentWall.isFinite, receivedWall.isFinite, elapsed.isFinite, timeout.isFinite,
            elapsed > 0, elapsed <= timeout, timeout > 0
        else { throw Invalid.time }
        let projectedReceive = sentWall + elapsed
        guard projectedReceive.isFinite, abs(receivedWall - projectedReceive) <= maximumWallStep else {
            throw Invalid.time
        }
        let receive = try timestamp(response, 32, near: projectedReceive)
        let transmit = try timestamp(response, 40, near: projectedReceive)
        let processing = transmit - receive
        let delay = elapsed - processing
        guard processing >= 0, delay >= -localTimestampAllowance else { throw Invalid.time }
        let rootDelay = Double(Int32(bitPattern: word32(response, 4))) / 65_536
        let dispersion = Double(word32(response, 8)) / 65_536
        let offset = ((receive - sentWall) + (transmit - projectedReceive)) / 2
        let uncertainty = max(0, delay) / 2 + max(0, rootDelay) / 2 + dispersion + localTimestampAllowance
        guard offset.isFinite, uncertainty.isFinite else { throw Invalid.time }
        return .init(offset: offset, uncertainty: uncertainty)
    }

    private static func timestamp(_ bytes: [UInt8], _ index: Int, near unix: Double) throws -> Double {
        let seconds = Double(word32(bytes, index))
        let fraction = Double(word32(bytes, index + 4)) / era
        let approximateNTP = unix + epoch
        let eraNumber = ((approximateNTP - seconds) / era).rounded()
        let value = eraNumber * era + seconds + fraction - epoch
        // Date arithmetic remains precise to a millisecond within this representable range.
        guard approximateNTP.isFinite, abs(approximateNTP) < 1e12, value.isFinite,
            abs(value - unix) <= era / 2
        else { throw Invalid.time }
        return value
    }
    private static func word32(_ bytes: [UInt8], _ index: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(bytes[index + $1]) }
    }
    private static func word64(_ bytes: [UInt8], _ index: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { ($0 << 8) | UInt64(bytes[index + $1]) }
    }
}
