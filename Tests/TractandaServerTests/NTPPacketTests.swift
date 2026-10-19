import XCTest

@testable import TractandaServer

final class NTPPacketTests: XCTestCase {
    private let nonce: UInt64 = 0x0123_4567_89ab_cdef
    private let sent = 1_700_000_000.0

    func testRequestCarriesClientHeaderAndUnpredictableTransmitNonce() {
        let request = NTPPacket.request(nonce: nonce)

        XCTAssertEqual(request.count, 48)
        XCTAssertEqual(request[0], 0x23)
        XCTAssertEqual(Array(request[40..<48]), [0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef])
        XCTAssertTrue(request[1..<40].allSatisfy { $0 == 0 })
    }

    func testFourTimestampEquationAndRootUncertainty() throws {
        let response = packet(receive: sent + 0.1, transmit: sent + 0.15)

        let sample = try NTPPacket.sample(
            response: response, nonce: nonce, sentWall: sent, receivedWall: sent + 0.4,
            elapsed: 0.4, timeout: 1)

        // T1=0, T2=.1, T3=.15, T4=.4: offset=((T2-T1)+(T3-T4))/2=-.075.
        XCTAssertEqual(sample.offset, -0.075, accuracy: 0.00001)
        // Delay=.4-(.15-.1)=.35; uncertainty=.35/2 + .04/2 + .02 + .001.
        XCTAssertEqual(sample.uncertainty, 0.216, accuracy: 0.00002)
    }

    func testNTPSecondsUnfoldAcross2036EraRollover() throws {
        let rollover = 2_085_978_496.0
        let response = packet(receive: rollover - 0.05, transmit: rollover + 0.05)

        let sample = try NTPPacket.sample(
            response: response, nonce: nonce, sentWall: rollover - 0.15,
            receivedWall: rollover + 0.25, elapsed: 0.4, timeout: 1)

        // T1=-.15, T2=-.05, T3=+.05, T4=+.25 around rollover; 32-bit seconds wrap between T2/T3.
        XCTAssertEqual(sample.offset, -0.05, accuracy: 0.00002)
        XCTAssertEqual(sample.uncertainty, 0.191, accuracy: 0.00002)
    }

    func testRejectsMalformedHeaderFieldsAndOriginateNonce() {
        var malformed = packet()
        malformed.append(0)
        assertRejected(malformed)

        for (index, value) in [(0, UInt8(0x23)), (0, 0x14), (0, 0x2c), (0, 0xe4), (1, 0), (1, 16)] {
            var response = packet()
            response[index] = value
            assertRejected(response)
        }

        var wrongNonce = packet()
        put64(nonce ^ 1, into: &wrongNonce, at: 24)
        assertRejected(wrongNonce)

        var zeroReceive = packet()
        put64(0, into: &zeroReceive, at: 32)
        assertRejected(zeroReceive)

        var zeroTransmit = packet()
        put64(0, into: &zeroTransmit, at: 40)
        assertRejected(zeroTransmit)
    }

    func testRejectsWallStepsInEitherDirection() {
        let response = packet(receive: sent + 0.1, transmit: sent + 0.15)
        for step in [-0.101, 0.101] {
            XCTAssertThrowsError(
                try NTPPacket.sample(
                    response: response, nonce: nonce, sentWall: sent, receivedWall: sent + 0.4 + step,
                    elapsed: 0.4, timeout: 1))
        }
    }

    func testRejectsImpossibleElapsedAndServerProcessingIntervals() throws {
        let normal = packet(receive: sent + 0.1, transmit: sent + 0.15)
        for (elapsed, timeout) in [(0.0, 1.0), (1.1, 1.0)] {
            XCTAssertThrowsError(
                try NTPPacket.sample(
                    response: normal, nonce: nonce, sentWall: sent, receivedWall: sent + elapsed,
                    elapsed: elapsed, timeout: timeout))
        }

        let serverTookTooLong = packet(receive: sent + 0.1, transmit: sent + 0.6)
        XCTAssertThrowsError(
            try NTPPacket.sample(
                response: serverTookTooLong, nonce: nonce, sentWall: sent, receivedWall: sent + 0.4,
                elapsed: 0.4, timeout: 1))

        let reversedServerTimes = packet(receive: sent + 0.2, transmit: sent + 0.1)
        XCTAssertThrowsError(
            try NTPPacket.sample(
                response: reversedServerTimes, nonce: nonce, sentWall: sent, receivedWall: sent + 0.4,
                elapsed: 0.4, timeout: 1))

        var negativeRootDelay = packet()
        put32(UInt32(bitPattern: Int32(-0.04 * 65_536)), into: &negativeRootDelay, at: 4)
        let clampedSample = try NTPPacket.sample(
            response: negativeRootDelay, nonce: nonce, sentWall: sent, receivedWall: sent + 0.4,
            elapsed: 0.4, timeout: 1)
        XCTAssertEqual(clampedSample.uncertainty, 0.196, accuracy: 0.00002)
    }

    func testRejectsNonfiniteTimeInputs() {
        let response = packet()
        for values in [
            (Double.infinity, sent + 0.4, 0.4, 1.0),
            (sent, Double.nan, 0.4, 1.0),
            (sent, sent + 0.4, Double.infinity, 1.0),
            (sent, sent + 0.4, 0.4, Double.nan),
        ] {
            XCTAssertThrowsError(
                try NTPPacket.sample(
                    response: response, nonce: nonce, sentWall: values.0, receivedWall: values.1,
                    elapsed: values.2, timeout: values.3))
        }
    }

    private func assertRejected(_ response: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(
            try NTPPacket.sample(
                response: response, nonce: nonce, sentWall: sent, receivedWall: sent + 0.4,
                elapsed: 0.4, timeout: 1), file: file, line: line)
    }

    private func packet(receive: Double = 1_700_000_000.1, transmit: Double = 1_700_000_000.15) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 48)
        bytes[0] = 0x24  // LI=0, version=4, server mode=4.
        bytes[1] = 2
        put32(UInt32(bitPattern: Int32(0.04 * 65_536)), into: &bytes, at: 4)
        put32(UInt32(0.02 * 65_536), into: &bytes, at: 8)
        put64(nonce, into: &bytes, at: 24)
        putTimestamp(receive, into: &bytes, at: 32)
        putTimestamp(transmit, into: &bytes, at: 40)
        return bytes
    }

    private func putTimestamp(_ unix: Double, into bytes: inout [UInt8], at index: Int) {
        let ntp = unix + 2_208_988_800
        let seconds = UInt32(Int64(floor(ntp)) % 4_294_967_296)
        let fraction = UInt32((ntp - floor(ntp)) * 4_294_967_296)
        put32(seconds, into: &bytes, at: index)
        put32(fraction, into: &bytes, at: index + 4)
    }

    private func put32(_ value: UInt32, into bytes: inout [UInt8], at index: Int) {
        for offset in 0..<4 { bytes[index + offset] = UInt8(truncatingIfNeeded: value >> (24 - offset * 8)) }
    }

    private func put64(_ value: UInt64, into bytes: inout [UInt8], at index: Int) {
        for offset in 0..<8 { bytes[index + offset] = UInt8(truncatingIfNeeded: value >> (56 - offset * 8)) }
    }
}
