import XCTest

@testable import TractandaCore

/// Inert shape inputs only: no Store, canonical publication, accepted rows or authority fixture.
final class AtomicAuthorityReviewControlSummaryTests: XCTestCase {
    private typealias Summary = AuthorityStore.ReviewControlSummary
    private typealias Delta = AuthorityStore.DispositionDelta
    private typealias Support = LogicalControlSource.Support
    private typealias Format = AtomicAuthorityFormat
    private let createdAt = "2026-10-23T16:00:00.000Z"
    private func id(_ n: Int) -> String { String(format: "%08x-0000-1000-8000-000000000001", n) }
    private func binding(_ n: Int) throws -> AuthorityBinding {
        try .init(recordID: id(n), sha256: String(repeating: "a", count: 64))
    }
    private func delta(
        _ n: Int, eligible: Bool = true, actor: String? = nil, cause: Int = 50,
        evidence: Bool = true, item: Int = 20, policies: [String]? = nil
    ) throws -> Delta {
        .init(
            target: try .init(itemID: id(item), revisionID: id(n), sha256: String(repeating: "b", count: 64)),
            eligible: eligible, actor: actor ?? (n == 21 ? "user:contributor" : "user:administrator"),
            policyIDs: policies ?? [id(40)], causes: [try binding(cause)],
            evidence: evidence ? try binding(n + 100) : nil)
    }
    private func pair() throws -> [Delta] { try [delta(21), delta(22)] }
    private func support(_ delta: Delta, ordinal: Int64) throws -> Support {
        .init(
            ordinal: ordinal, fingerprint: AuthorityRecordCodec.sha256(try JSON.encode(delta.itemValue)),
            delta: delta)
    }
    private func supports(_ deltas: [Delta]) throws -> [Support] {
        try deltas.enumerated().map { try support($0.element, ordinal: Int64($0.offset)) }
    }
    private func legacy(
        _ deltas: [Delta], parents: [AuthorityBinding]? = nil, previous: AuthorityBinding? = nil,
        omitPrevious: Bool = false, actor: String = "administrator"
    ) throws -> AuthorityStore.VerifiedControlPlan {
        let parents = try parents ?? [binding(30)]
        let previous = omitPrevious ? nil : try previous ?? binding(30)
        let record = try AuthorityRecord(
            recordID: id(10), storeID: id(1), originReplicaID: id(2), kind: .controlCommit,
            parentAuthorityIDs: parents.map(\.recordID), actorPrincipal: actor, createdAt: createdAt,
            payload: [
                "controls": .list(parents.map(\.itemValue)),
                "localParent": .list(previous.map { [$0.itemValue] } ?? []),
                "bootstrap": .list([try binding(3).itemValue]), "deltas": .list(deltas.map(\.itemValue)),
            ])
        return try .init(control: AuthorityRecordCodec.decode(AuthorityRecordCodec.encode(record)))
    }
    private func atomic(
        _ deltas: [Delta], parentEntries: Int64 = 1, effectEntries: Int64 = 2,
        effectTargets: Int64 = 2, parentByteExtra: Int64 = 0, effectByteExtra: Int64 = 0,
        actor: String = "administrator"
    ) throws -> AtomicControlStage {
        func stream(
            _ values: [ItemValue], section: Format.Section, part: Int, entries: Int64,
            targets: Int64, extra: Int64
        ) throws -> ItemValue {
            let bytes =
                try values.reduce(Int64(0)) {
                    $0 + Int64(try AtomicAuthorityEntryStream.frame($1, section: section).count)
                } + extra
            let reference = try Format.Reference(
                value: .object([
                    "binding": try binding(part).itemValue, "encodedBytes": .integer(4096),
                    "level": .integer(0), "firstLeaf": .integer(0), "leafCount": .integer(1),
                    "byteOffset": .integer(0), "byteCount": .integer(bytes),
                ]))
            return .object([
                "root": .list([reference.itemValue]), "byteCount": .integer(bytes),
                "entryCount": .integer(entries), "targetCount": .integer(targets), "leafCount": .integer(1),
            ])
        }
        let parents = try stream(
            [binding(30).itemValue], section: .parents, part: 31,
            entries: parentEntries, targets: 0, extra: parentByteExtra)
        let effects = try stream(
            deltas.map(\.itemValue), section: .effects, part: 32,
            entries: effectEntries, targets: effectTargets, extra: effectByteExtra)
        let record = try Format.Record(
            value: .object([
                "profile": .text(Format.profile), "kind": .text("atomicControl"),
                "recordID": .text(id(10)), "controlID": .text(id(10)), "storeID": .text(id(1)),
                "originReplicaID": .text(id(2)), "actorPrincipal": .text(actor),
                "createdAt": .date(createdAt),
                "payload": .object([
                    "previous": .list([try binding(30).itemValue]),
                    "bootstrap": .list([try binding(3).itemValue]),
                    "parents": parents, "effects": effects, "partCount": .integer(2),
                    "partBytes": .integer(8192),
                ]),
            ]))
        return try .init(rootBytes: Format.Codec.encode(record))
    }
    private func summary(_ stage: AtomicControlStage, deltas: [Delta]) throws -> Summary {
        try .init(atomic: stage, parents: [binding(30)], supports: supports(deltas))
    }

    func testLegacySummaryPreservesExactOriginalAndTypedReviewPair() throws {
        let deltas = try pair()
        let plan = try legacy(deltas)
        let value = try Summary(legacy: plan)
        XCTAssertEqual(value.kind, .legacy)
        XCTAssertEqual(value.originalBytes, plan.control.originalBytes)
        XCTAssertEqual(value.binding, plan.binding)
        XCTAssertEqual(value.origin, id(2))
        XCTAssertEqual(value.actor, "administrator")
        XCTAssertEqual(value.createdAt, createdAt)
        XCTAssertEqual(value.previous, try binding(30))
        XCTAssertEqual(value.bootstrap, try binding(3))
        XCTAssertEqual(value.parents, try [binding(30)])
        XCTAssertEqual(value.deltas, deltas)
        XCTAssertEqual(try Summary(legacy: plan), value)
    }
    func testAtomicSummaryPreservesExactRootWithoutSynthesizingLegacyOriginal() throws {
        let deltas = try pair()
        let stage = try atomic(deltas)
        let value = try summary(stage, deltas: deltas)
        XCTAssertEqual(value.kind, .atomic)
        XCTAssertEqual(value.originalBytes, stage.rootBytes)
        XCTAssertEqual(value.binding, stage.header.binding)
        XCTAssertEqual(value.origin, id(2))
        XCTAssertEqual(value.actor, "administrator")
        XCTAssertEqual(value.createdAt, createdAt)
        XCTAssertEqual(value.previous, try binding(30))
        XCTAssertEqual(value.bootstrap, try binding(3))
        XCTAssertEqual(value.parents, try [binding(30)])
        XCTAssertEqual(value.deltas, deltas)
        XCTAssertNotEqual(value.originalBytes, try legacy(deltas).control.originalBytes)
        XCTAssertEqual(try summary(stage, deltas: deltas), value)
    }
    func testLegacyRejectsNonReviewPairPreviousAndDecisionCauseShapes() throws {
        XCTAssertThrowsError(try Summary(legacy: legacy([delta(21)])))
        XCTAssertThrowsError(try Summary(legacy: legacy([delta(21), delta(22, eligible: false)])))
        XCTAssertThrowsError(try Summary(legacy: legacy(pair(), omitPrevious: true)))
        XCTAssertThrowsError(try Summary(legacy: legacy(pair(), parents: [binding(30), binding(35)])))
        XCTAssertThrowsError(try Summary(legacy: legacy([delta(21), delta(22, cause: 51)])))
        XCTAssertThrowsError(try Summary(legacy: legacy([delta(21), delta(22, evidence: false)])))
        XCTAssertThrowsError(try Summary(legacy: legacy([delta(21), delta(22, item: 25)])))
    }
    func testAtomicRejectsDifferentPREOrdinalFingerprintAndPair() throws {
        let deltas = try pair()
        let stage = try atomic(deltas)
        XCTAssertThrowsError(try Summary(atomic: stage, parents: [binding(35)], supports: supports(deltas)))
        XCTAssertThrowsError(
            try Summary(
                atomic: stage, parents: [binding(30)],
                supports: [support(deltas[0], ordinal: 1), support(deltas[1], ordinal: 0)]))
        let wrong = Support(ordinal: 0, fingerprint: String(repeating: "f", count: 64), delta: deltas[0])
        XCTAssertThrowsError(
            try Summary(
                atomic: stage, parents: [binding(30)], supports: [wrong, support(deltas[1], ordinal: 1)]))
        for bad in try [
            [delta(21)], [delta(21), delta(21)], [delta(21), delta(22, eligible: false)],
            [delta(21), delta(22, cause: 51)], [delta(21), delta(22, evidence: false)],
            [delta(21), delta(22, item: 25)], [delta(21, cause: 10), delta(22, cause: 10)],
            [delta(21, cause: 30), delta(22, cause: 30)],
        ] {
            XCTAssertThrowsError(try summary(stage, deltas: bad))
        }
    }
    func testAtomicRequiresExactStreamCountsAndEncodedEntryBytes() throws {
        let deltas = try pair()
        for stage in try [
            atomic(deltas, parentEntries: 2), atomic(deltas, effectEntries: 3),
            atomic(deltas, effectTargets: 1), atomic(deltas, parentByteExtra: 1),
            atomic(deltas, effectByteExtra: 1),
        ] {
            XCTAssertThrowsError(try summary(stage, deltas: deltas))
        }
    }
    func testExistingActorPolicyAndOriginalByteLimitsRemainStrict() throws {
        let deltas = try pair()
        let stage = try atomic(deltas)
        XCTAssertThrowsError(try summary(stage, deltas: [delta(21, actor: ""), delta(22)]))
        XCTAssertThrowsError(
            try summary(stage, deltas: [delta(21, actor: String(repeating: "a", count: 257)), delta(22)]))
        XCTAssertThrowsError(try summary(stage, deltas: [delta(21, policies: [id(40), id(40)]), delta(22)]))
        XCTAssertThrowsError(try atomic(deltas, actor: String(repeating: "a", count: 257)))
        XCTAssertThrowsError(try legacy(deltas, actor: String(repeating: "a", count: 257)))
        XCTAssertThrowsError(
            try AtomicControlStage(rootBytes: Data(repeating: 0, count: Format.maximumEnvelopeBytes + 1)))
        XCTAssertThrowsError(
            try AuthorityRecordCodec.decode(Data(repeating: 0, count: AuthorityRecord.maximumBytes + 1)))
        var altered = stage.rootBytes
        altered.append(32)
        XCTAssertThrowsError(try AtomicControlStage(rootBytes: altered))
    }
    func testBoundedMaximumPolicyAndEscapedActorValuesRetainEveryField() throws {
        let policies = (0..<AuthorityRecord.maximumEntries).map { id(1000 + $0) }
        let deltas = try [
            delta(21, actor: String(repeating: "\\", count: 256), policies: policies),
            delta(22, actor: "uid:51001", policies: policies),
        ]
        let stage = try atomic(deltas, actor: String(repeating: "é", count: 128))
        let value = try summary(stage, deltas: deltas)
        XCTAssertEqual(value.deltas, deltas)
        XCTAssertEqual(value.actor.utf8.count, 256)
        XCTAssertLessThanOrEqual(value.originalBytes.count, Format.maximumEnvelopeBytes)
        XCTAssertEqual(try Summary(legacy: legacy(deltas)).deltas, deltas)
    }
}
