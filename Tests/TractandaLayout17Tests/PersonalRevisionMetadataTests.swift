import Crypto
import Foundation
import TractandaClient
import TractandaCore
import XCTest

@testable import TractandaLayout17

final class PersonalRevisionMetadataTests: XCTestCase {
    func testDescriptorKeyMatchesExistingPersonalPeerFormat() throws {
        let id = "00000000-0000-1000-8000-000000000001"
        let item = "00000000-0000-1000-8000-000000000002"
        let parent = "00000000-0000-1000-8000-000000000003"
        let hash = String(repeating: "a", count: 64)
        let old = try PersonalObjectDescriptor(
            kind: .revision, id: id, byteCount: 320,
            sha256: hash, itemID: item, parentRevisionIDs: [parent])
        let oldBytes = try JSON.encode(old)
        let parsed = try PersonalRevisionDescriptor.decode(JSONSerialization.jsonObject(with: oldBytes))
        XCTAssertEqual(try JSON.encode(parsed), oldBytes)
        XCTAssertEqual(
            try parsed.key, SHA256.hash(data: oldBytes).map { String(format: "%02x", $0) }.joined())
    }

    func testUnknownOrMalformedRevisionDescriptorsAreRejected() throws {
        let id = "00000000-0000-1000-8000-000000000001"
        let value: [String: Any] = [
            "kind": "revision", "id": id, "byteCount": 1,
            "sha256": String(repeating: "a", count: 64), "itemID": id, "parentRevisionIDs": [],
        ]
        XCTAssertNoThrow(try PersonalRevisionDescriptor.decode(value))
        var unknown = value
        unknown["attachment"] = [:]
        XCTAssertThrowsError(try PersonalRevisionDescriptor.decode(unknown))
        var invalid = value
        invalid["sha256"] = "bad"
        XCTAssertThrowsError(try PersonalRevisionDescriptor.decode(invalid))
    }

    func testTemporaryMapAcceptsLargeValidCanonicalDescriptor() throws {
        let parents = (0..<400).map { String(format: "00000000-0000-1000-8000-%012x", $0 + 100) }.sorted()
        let descriptor = PersonalRevisionDescriptor(
            kind: "revision", id: "00000000-0000-1000-8000-000000000001",
            byteCount: 100, sha256: String(repeating: "a", count: 64),
            itemID: "00000000-0000-1000-8000-000000000002", parentRevisionIDs: parents)
        let bytes = try JSON.encode(descriptor)
        XCTAssertGreaterThan(bytes.count, 16 * 1024)
        let map = try TransientDescriptorMap()
        let key = try descriptor.key
        try map.canonical(
            oldKey: key, newKey: key, revision: descriptor.id, path: "fixture", newDescriptor: bytes)
        XCTAssertEqual(try map.descriptor(oldKey: key, staged: false), descriptor)
    }
}
