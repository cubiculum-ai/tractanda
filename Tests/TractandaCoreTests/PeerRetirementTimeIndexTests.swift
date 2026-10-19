import Foundation
import XCTest

@testable import TractandaCore

final class PeerRetirementTimeIndexTests: XCTestCase {
    private func fixture(_ body: (ItemIndex) throws -> Void) throws {
        try AttachmentFixtureCapacity.requireFree()
        let root = (try GuardedFixtureDirectory.parent()).appendingPathComponent(
            "peer-time-index-" + Identifier.make())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try ItemIndex(path: root.appendingPathComponent("index.sqlite").path, create: true)
        defer { index.close() }
        index.graphReserveBytes = UInt64(AttachmentFixtureCapacity.reserveBytes)
        try index.initializeAuthoritySchema()
        // This is a disposable derived-index fixture (estimated below4MiB), never a canonical authority publication.
        try body(index)
        let files = try XCTUnwrap(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]))
        var size = 0
        for case let file as URL in files {
            size += (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        XCTAssertLessThan(size, 4 * 1024 * 1024)
        try AttachmentFixtureCapacity.requireFree(at: root)
    }

    func testSimultaneousAuthorityEventsRetainPREAuthorityButEqualDataIsRemoved() throws {
        try fixture { index in
            let event = "f286e000-c88f-11f1-8000-001122334455"
            let origin = "f286dfff-c88f-11f1-8000-001122334455"
            let time = "2026-10-15T12:00:00.0000000Z"
            let binding = try AuthorityBinding(recordID: event, sha256: String(repeating: "a", count: 64))
            try index.retainPeerRetirement(binding, origins: [origin], effectiveAt: time)
            let ticks = try RevisionTimestamp(time).ticks
            XCTAssertTrue(try index.peerAuthorityTimePermits(origin: origin, ticks: ticks - 1))
            XCTAssertTrue(try index.peerAuthorityTimePermits(origin: origin, ticks: ticks))
            XCTAssertFalse(try index.peerAuthorityTimePermits(origin: origin, ticks: ticks + 1))
            XCTAssertEqual(try index.peerRetirementCauses(revisionID: event, origin: origin), [binding])
        }
    }

    func testLaterRemovalCannotWidenEarliestActiveCutoff() throws {
        try fixture { index in
            let origin = "f286dfff-c88f-11f1-8000-001122334455"
            let first = try AuthorityBinding(
                recordID: "f286e000-c88f-11f1-8000-001122334455", sha256: String(repeating: "a", count: 64))
            let second = try AuthorityBinding(
                recordID: "f286e001-c88f-11f1-8000-001122334455", sha256: String(repeating: "b", count: 64))
            try index.retainPeerRetirement(
                second, origins: [origin], effectiveAt: "2026-10-15T12:00:00.0000001Z")
            try index.retainPeerRetirement(
                first, origins: [origin], effectiveAt: "2026-10-15T12:00:00.0000000Z")
            XCTAssertEqual(
                try index.peerRetirementCauses(revisionID: first.recordID, origin: origin), [first])
            XCTAssertEqual(
                try index.peerRetirementCauses(revisionID: second.recordID, origin: origin), [first, second])
            XCTAssertFalse(
                try index.peerReviewCoversCurrentRetirements(
                    revisionID: second.recordID, origin: origin, covered: [first]))
            XCTAssertFalse(
                try index.peerReviewCoversCurrentRetirements(
                    revisionID: second.recordID, origin: origin,
                    covered: [.init(recordID: second.recordID, sha256: first.sha256), first]))
            XCTAssertTrue(
                try index.peerReviewCoversCurrentRetirements(
                    revisionID: second.recordID, origin: origin, covered: [second, first]))
        }
    }

    func testRetiredDecisionStillHoldsItsEarlierIssuedResolutionByExactDependency() throws {
        try fixture { index in
            let c = "f286dfff-c88f-11f1-8000-001122334455"
            let root = "f286e000-c88f-11f1-8000-001122334455"
            let d = "f286e001-c88f-11f1-8000-001122334455"
            let origin = "f286a000-c88f-11f1-8000-001122334455"
            let b = "f286a001-c88f-11f1-8000-001122334455"
            let item = "f286a002-c88f-11f1-8000-001122334455"
            let sha = String(repeating: "a", count: 64)
            let removal = try AuthorityBinding(recordID: root, sha256: sha)
            try index.retainPeerRetirement(
                removal, origins: [origin],
                effectiveAt: "2026-10-15T12:00:00.0000000Z")
            let issued = try PeerLifecycle.revisionTicks(d)
            // Disposable derived facts only: no fabricated canonical root or publication.
            try index.execute(
                "INSERT INTO authority_objects VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                [d, "authority", "1", sha, "fixture", origin, "", "", "reviewDecision", "", String(issued)])
            try index.execute(
                "INSERT INTO authority_review_event VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
                [d, sha, item, b, sha, b, sha, "reviewDecision", c, sha, b, sha])
            try index.execute(
                "INSERT INTO authority_review_applied VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                [d, sha, c, sha, b, sha, origin, "admin", "fixture", "", "0"])
            XCTAssertFalse(
                try PeerLifecycle.revisionIsRemoved(
                    revisionID: c, effectiveAt: "2026-10-15T12:00:00.0000000Z"))
            let rows = try index.peerRetiredReviewPage(origin: origin, cutoff: issued - 1)
            XCTAssertEqual(rows.map(\.decision), [d])
            XCTAssertEqual(rows.map(\.resolution), [c])
            XCTAssertTrue(try index.peerRetiredReviewPage(origin: origin, cutoff: issued).isEmpty)
            XCTAssertEqual(try index.peerRetirementCauses(revisionID: c, origin: origin), [removal])
            XCTAssertFalse(
                try index.peerReviewCoversCurrentRetirements(revisionID: c, origin: origin, covered: []))
            XCTAssertTrue(
                try index.peerReviewCoversCurrentRetirements(
                    revisionID: c, origin: origin, covered: [removal]))
        }
    }
}
