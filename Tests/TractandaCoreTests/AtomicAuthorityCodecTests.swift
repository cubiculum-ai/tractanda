import XCTest

@testable import TractandaCore

/// Pure, inert format checks: no Store, authority acceptance, capabilities or filesystem publication.
final class AtomicAuthorityCodecTests: XCTestCase {
    private typealias Format = AtomicAuthorityFormat
    private func id(_ n: Int) -> String { String(format: "%08x-0000-1000-8000-000000000001", n) }
    private func binding(_ n: Int) -> AuthorityBinding {
        try! .init(recordID: id(n), sha256: String(repeating: "a", count: 64))
    }
    private func record(_ kind: Format.Kind, _ n: Int, payload: [String: ItemValue]) throws -> Format.Record {
        try .init(
            value: .object([
                "profile": .text(Format.profile), "kind": .text(kind.rawValue),
                "recordID": .text(id(n)), "controlID": .text(id(1)), "storeID": .text(id(2)),
                "originReplicaID": .text(id(3)), "actorPrincipal": .text("rcfa"),
                "createdAt": .date("2026-10-23T09:00:00.000Z"), "payload": .object(payload),
            ]))
    }
    private func part(_ ordinal: Int, bytes: Data = Data([65])) throws -> Format.Record {
        try record(
            .atomicControlPart, 1000 + ordinal,
            payload: [
                "section": .text("effects"), "ordinal": .integer(Int64(ordinal)),
                "byteOffset": .integer(Int64(ordinal)), "bytes": .bytes(bytes),
            ])
    }
    private func index(_ n: Int, level: Int64, leaves: Int64, children: [Format.Reference]) throws
        -> Format.Record
    {
        try record(
            .atomicControlIndex, n,
            payload: [
                "section": .text("effects"), "level": .integer(level),
                "totalLeaves": .integer(leaves), "children": .list(children.map(\.itemValue)),
            ])
    }
    private func replacing(_ value: ItemValue, _ key: String, with replacement: ItemValue) -> ItemValue {
        var p = value.map!
        p[key] = replacement
        return .object(p)
    }
    private func emptyStream() -> ItemValue {
        .object([
            "root": .list([]), "byteCount": .integer(0), "entryCount": .integer(0),
            "targetCount": .integer(0), "leafCount": .integer(0),
        ])
    }
    private func largeEffect() throws -> ItemValue {
        AuthorityStore.DispositionDelta(
            target: try .init(itemID: id(10), revisionID: id(11), sha256: String(repeating: "f", count: 64)),
            eligible: false, actor: String(repeating: "\\", count: 256),
            policyIDs: (0..<AuthorityRecord.maximumEntries).map { id(2000 + $0) },
            causes: try (0..<AuthorityRecord.maximumEntries).map { binding(3000 + $0) },
            evidence: binding(4000)
        ).itemValue
    }
    func testStrictRoundTripAndPhysicalEnvelopeBound() throws {
        let value = try part(0, bytes: Data(repeating: 255, count: Format.maximumChunkBytes))
        let encoded = try Format.Codec.encode(value)
        XCTAssertLessThanOrEqual(encoded.count, Format.maximumEnvelopeBytes)
        XCTAssertEqual(try Format.Codec.decode(encoded), value)
        XCTAssertThrowsError(try part(0, bytes: Data(repeating: 0, count: Format.maximumChunkBytes + 1)))
        var changed = encoded
        changed.append(32)
        XCTAssertThrowsError(try Format.Codec.decode(changed))
        XCTAssertThrowsError(
            try Format.Record(value: replacing(value.itemValue, "surprise", with: .boolean(true))))
        XCTAssertThrowsError(
            try Format.Record(value: replacing(value.itemValue, "profile", with: .text("future"))))
        let mismatched = Data(
            String(decoding: encoded, as: UTF8.self).replacingOccurrences(
                of: "X-Store-ID: " + id(2), with: "X-Store-ID: " + id(99)
            ).utf8)
        XCTAssertThrowsError(try Format.Codec.decode(mismatched))
    }
    func test129TinyLeavesHaveUniformLevelsAndOneBoundedUnaryTail() throws {
        var records = try (0..<129).map { try part($0) }
        let refs = try records.map { try $0.reference() }
        let full = try index(500, level: 1, leaves: 129, children: Array(refs[..<64]))
        let second = try index(501, level: 1, leaves: 129, children: Array(refs[64..<128]))
        let tail = try index(502, level: 1, leaves: 129, children: [refs[128]])
        let top = try index(
            503, level: 2, leaves: 129, children: [full.reference(), second.reference(), tail.reference()])
        records += [full, second, tail, top]
        let rootReference = try top.reference()
        XCTAssertEqual(rootReference.level, 2)
        XCTAssertEqual(rootReference.leafCount, 129)
        XCTAssertEqual(rootReference.byteCount, 129)
        XCTAssertEqual(try Format.level(leaves: 129), 2)
        XCTAssertEqual(try Format.level(leaves: 64), 1)
        let aggregate = try records.reduce(0) { $0 + (try Format.Codec.encode($1)).count }
        print(
            "ATOMIC_INERT_TREE leaves=129 physicalParts=\(records.count) aggregateEnvelopeBytes=\(aggregate)")
        XCTAssertLessThan(aggregate, 1024 * 1024)
        for value in records { XCTAssertEqual(try Format.Codec.decode(Format.Codec.encode(value)), value) }
        XCTAssertThrowsError(try index(504, level: 1, leaves: 1, children: [refs[0]]))
        XCTAssertThrowsError(try index(505, level: 2, leaves: 129, children: [full.reference(), refs[128]]))
    }
    func testByteRangesAreContiguousAndNotEntryOrdinalRanges() throws {
        let a = try part(0, bytes: Data([1, 2, 3])).reference()
        var b = try part(1).reference().itemValue
        b = replacing(b, "byteOffset", with: .integer(3))
        let good = try Format.Reference(value: b)
        XCTAssertNoThrow(try index(500, level: 1, leaves: 2, children: [a, good]))
        let overlapping = try Format.Reference(value: replacing(b, "byteOffset", with: .integer(2)))
        XCTAssertThrowsError(try index(500, level: 1, leaves: 2, children: [a, overlapping]))
        XCTAssertThrowsError(try index(500, level: 1, leaves: 2, children: [good, a]))
        XCTAssertThrowsError(try index(500, level: 1, leaves: 2, children: [a, a]))
        let selfReference = try Format.Reference(
            value: replacing(
                a.itemValue, "binding", with: binding(500).itemValue))
        XCTAssertThrowsError(try index(500, level: 1, leaves: 2, children: [selfReference, good]))
    }
    func testRootSummaryIsInertAndExactZeroStreamIsUnambiguous() throws {
        let root = try record(
            .atomicControl, 1,
            payload: [
                "previous": .list([]), "bootstrap": .list([]), "parents": emptyStream(),
                "effects": emptyStream(), "partCount": .integer(0), "partBytes": .integer(0),
            ])
        XCTAssertEqual(try Format.Codec.decode(Format.Codec.encode(root)), root)
        XCTAssertThrowsError(try root.reference())
        XCTAssertThrowsError(
            try Format.Stream(
                value: replacing(emptyStream(), "byteCount", with: .integer(1)), section: .parents))
        let bad = replacing(
            root.itemValue, "payload",
            with: replacing(
                .object(root.payload), "previous", with: .list([binding(1).itemValue])))
        XCTAssertThrowsError(try Format.Record(value: bad))
        let v4Store = replacing(
            root.itemValue, "storeID", with: .text("00000001-0000-4000-8000-000000000001"))
        XCTAssertNoThrow(try Format.Record(value: v4Store), "Match legacy authority StoreID validation")
        XCTAssertEqual(CanonicalFormatSupport.current.readerLevel, 14, "No format activation in this slice")
        XCTAssertFalse(CanonicalFormatSupport.current.capabilities.contains(Format.profile))
    }
    func testValidSemanticEntryCrossesPhysicalLeaves() throws {
        let value = try largeEffect()
        let framed = try AtomicAuthorityEntryStream.frame(value, section: .effects)
        XCTAssertGreaterThan(framed.count, Format.maximumChunkBytes)
        XCTAssertThrowsError(
            try part(0, bytes: framed), "A valid effect is not required to fit one physical leaf")
        print(
            "ATOMIC_INERT_ENTRY rawBytes=\(framed.count - 8) physicalEnvelopeLimit=\(Format.maximumEnvelopeBytes)"
        )
        XCTAssertEqual(framed.count - 8, try AtomicAuthorityEntryStream.maximumEntryBytes(.effects))
        var decoder = try AtomicAuthorityEntryStream.Decoder(
            section: .effects, expectedBytes: UInt64(framed.count), expectedEntries: 1, expectedTargets: 1)
        var actual: [ItemValue] = []
        var offset = 0
        for count in [1, 2, 4, 1] {
            try decoder.append(framed.subdata(in: offset..<(offset + count))) { actual.append($0) }
            offset += count
            XCTAssertTrue(actual.isEmpty)
        }
        while offset < framed.count {
            let end = min(offset + 4093, framed.count)
            try decoder.append(framed.subdata(in: offset..<end)) { actual.append($0) }
            offset = end
        }
        try decoder.finish()
        XCTAssertEqual(actual, [value])
    }
    func testDifferentSupportContextsForOneTargetSurviveFraming() throws {
        let a = AuthorityStore.DispositionDelta(
            target: try .init(itemID: id(10), revisionID: id(11), sha256: String(repeating: "f", count: 64)),
            eligible: true, actor: "user:rcfa", policyIDs: [], causes: [binding(20)])
        let b = AuthorityStore.DispositionDelta(
            target: a.target, eligible: true, actor: a.actor, policyIDs: [], causes: [binding(21)])
        let values = try [a.itemValue, b.itemValue].sorted {
            AuthorityRecordCodec.sha256(try JSON.encode($0))
                < AuthorityRecordCodec.sha256(try JSON.encode($1))
        }
        let stream = try values.reduce(into: Data()) {
            $0.append(try AtomicAuthorityEntryStream.frame($1, section: .effects))
        }
        var decoder = try AtomicAuthorityEntryStream.Decoder(
            section: .effects, expectedBytes: UInt64(stream.count), expectedEntries: 2, expectedTargets: 1)
        var seen: [ItemValue] = []
        try decoder.append(stream) { seen.append($0) }
        try decoder.finish()
        XCTAssertEqual(seen, values, "Framing cannot discard causes or decide authorization")
        let repeated = try AtomicAuthorityEntryStream.frame(values[0], section: .effects)
        var duplicate = try AtomicAuthorityEntryStream.Decoder(
            section: .effects, expectedBytes: UInt64(repeated.count * 2), expectedEntries: 2,
            expectedTargets: 1)
        XCTAssertThrowsError(try duplicate.append(repeated + repeated) { _ in })
    }
    func testDeclaredLengthIsRejectedBeforeEntryAllocationAndFailureIsTerminal() throws {
        var decoder = try AtomicAuthorityEntryStream.Decoder(
            section: .effects, expectedBytes: 1024, expectedEntries: 1, expectedTargets: 1)
        XCTAssertThrowsError(try decoder.append(Data(repeating: 255, count: 8)) { _ in })
        XCTAssertTrue(decoder.failed)
        XCTAssertThrowsError(try decoder.append(Data()) { _ in })
        XCTAssertThrowsError(
            try AtomicAuthorityEntryStream.frame(
                replacing(try largeEffect(), "actor", with: .text(String(repeating: "x", count: 257))),
                section: .effects))
        XCTAssertThrowsError(
            try Format.Reference(
                value: replacing(
                    try part(0).reference().itemValue, "byteOffset", with: .integer(Int64.max))))
        let effect = try largeEffect()
        let repeated = binding(20).itemValue
        XCTAssertThrowsError(
            try AtomicAuthorityEntryStream.frame(
                replacing(effect, "causes", with: .list([repeated, repeated])), section: .effects))
        XCTAssertThrowsError(
            try AtomicAuthorityEntryStream.frame(
                replacing(effect, "evidence", with: .list([binding(20).itemValue, binding(21).itemValue])),
                section: .effects))
        XCTAssertThrowsError(
            try Format.Reference(
                value: replacing(
                    try part(0).reference().itemValue, "byteCount",
                    with: .integer(Int64(Format.maximumChunkBytes + 1)))))
        XCTAssertThrowsError(
            try AtomicAuthorityEntryStream.frame(
                replacing(effect, "causes", with: .list([binding(21).itemValue, binding(20).itemValue])),
                section: .effects))
    }
    func testTruncationCountsTrailingBytesAndNoncanonicalEntryAreRejected() throws {
        let frame = try AtomicAuthorityEntryStream.frame(binding(10).itemValue, section: .parents)
        var short = try AtomicAuthorityEntryStream.Decoder(
            section: .parents, expectedBytes: UInt64(frame.count), expectedEntries: 1, expectedTargets: 0)
        try short.append(frame.dropLast()) { _ in }
        XCTAssertThrowsError(try short.finish())
        var trailing = try AtomicAuthorityEntryStream.Decoder(
            section: .parents, expectedBytes: UInt64(frame.count), expectedEntries: 1, expectedTargets: 0)
        XCTAssertThrowsError(try trailing.append(frame + Data([0])) { _ in })
        let data = Data(" ".utf8) + (try JSON.encode(binding(10).itemValue))
        var length = UInt64(data.count).bigEndian
        let noncanonical = withUnsafeBytes(of: &length) { Data($0) } + data
        var decoder = try AtomicAuthorityEntryStream.Decoder(
            section: .parents, expectedBytes: UInt64(noncanonical.count), expectedEntries: 1,
            expectedTargets: 0)
        XCTAssertThrowsError(try decoder.append(noncanonical) { _ in })
    }
    func testRealTaskCancellationIsCheckedWithoutProgressCallback() async throws {
        let frame = try AtomicAuthorityEntryStream.frame(binding(10).itemValue, section: .parents)
        let value = try part(0)
        let encoded = try Format.Codec.encode(value)
        let task = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            var streamCancelled = false
            var codecCancelled = false
            do {
                var decoder = try AtomicAuthorityEntryStream.Decoder(
                    section: .parents, expectedBytes: UInt64(frame.count), expectedEntries: 1,
                    expectedTargets: 0)
                try decoder.append(frame) { _ in }
            } catch is CancellationError { streamCancelled = true } catch {}
            do { _ = try Format.Codec.decode(encoded) } catch is CancellationError {
                codecCancelled = true
            } catch {}
            return streamCancelled && codecCancelled
        }
        let cancelled = await task.value
        XCTAssertTrue(cancelled)
    }
}
