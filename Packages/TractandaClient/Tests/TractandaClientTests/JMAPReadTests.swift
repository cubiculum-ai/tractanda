import Foundation
import Testing

@testable import TractandaClient

private let readItemID = "11111111-1111-4111-8111-111111111111"
private let readRevisionID = "22222222-2222-4222-8222-222222222222"
private let readOtherID = "33333333-3333-4333-8333-333333333333"

private func readRevision() throws -> Revision {
    try Revision(fields: [
        "itemID": .text(readItemID), "revisionID": .text(readRevisionID), "classID": .text("Item"),
        "actor": .text("user:test"), "operationID": .text("fixture"), "requestIdentity": .text("fixture"),
        "schemaVersion": .integer(1), "createdAt": .date("2026-10-26T00:00:00Z"),
        "modifiedAt": .date("2026-10-26T00:00:00Z"), "subject": .text("Read fixture"),
        "literal.a/b~c": .object(["future": .list([.integer(.min), .integer(.max)])]),
    ])
}
private func readState() -> ItemState {
    ItemState(
        itemID: readItemID, stateToken: "fixture-state", status: .ready,
        representativeRevisionID: readRevisionID, frontier: [readRevisionID], detailsComplete: true)
}
private func readJSON<T: Encodable>(_ value: T) throws -> JMAPValue {
    try JMAPValue.decode(JSON.encode(value))
}

@Test func jmapReadIntegerFixturesPreserveEntireInt64Domain() throws {
    let fixtures: [(Int64, String)] = [
        (.min, ##"{"type":"integer","value":"-9223372036854775808"}"##),
        (0, ##"{"type":"integer","value":"0"}"##),
        (.max, ##"{"type":"integer","value":"9223372036854775807"}"##),
        (9_007_199_254_740_993, ##"{"type":"integer","value":"9007199254740993"}"##),
    ]
    for (integer, fixture) in fixtures {
        let wire = JMAPItemValue(.integer(integer))
        #expect(try readJSON(wire) == JMAPValue.decode(Data(fixture.utf8)))
        #expect(try JSON.decode(JMAPItemValue.self, Data(fixture.utf8)).value == .integer(integer))
        let canonical = try readJSON(ItemValue.integer(integer))
        #expect(canonical["value"] == .number(try JMAPNumber(String(integer))))
    }
}
@Test func jmapReadIntegerFixturesRejectNoncanonicalAndOverflowStrings() throws {
    for text in ["+1", "01", "-0", "1.0", "1e3", "", " 1", "9223372036854775808", "-9223372036854775809"] {
        let fixture = try JSONSerialization.data(withJSONObject: ["type": "integer", "value": text])
        #expect(throws: (any Error).self) { try JSON.decode(JMAPItemValue.self, fixture) }
    }
    #expect(throws: (any Error).self) {
        try JSON.decode(JMAPItemValue.self, Data(##"{"type":"integer","value":42}"##.utf8))
    }
}
@Test func jmapReadNestedUnknownFieldsAndLiteralKeysRoundtrip() throws {
    let fixture = Data(
        ##"{"type":"object","value":{"literal.a/b~c":{"type":"list","value":[{"type":"integer","value":"9223372036854775807"},{"type":"text","value":"future field"}]}}}"##
            .utf8)
    let value = try JSON.decode(JMAPItemValue.self, fixture)
    #expect(value.value.map?["literal.a/b~c"]?.array?.first == .integer(.max))
    #expect(try readJSON(value) == JMAPValue.decode(fixture))
}
@Test func jmapReadNonintegerTagsRetainTheirSemantics() throws {
    let values: [ItemValue] = [
        .text("text"), .real(2.5), .boolean(false), .date("2026-10-26T00:00:00Z"),
        .reference(ItemReference(readItemID, revisionID: readRevisionID)), .bytes(Data([0, 255])),
    ]
    for value in values {
        #expect(try readJSON(JMAPItemValue(value)) == readJSON(value))
        #expect(try JSON.decode(JMAPItemValue.self, JSON.encode(JMAPItemValue(value))).value == value)
    }
}
@Test func jmapReadCanonicalRevisionBytesRemainIdenticalAfterWireRoundtrip() throws {
    let revision = try readRevision()
    let before = try JSON.encode(revision)
    let item = try JMAPItemRecord(revision, resolution: readState())
    let decoded = try JSON.decode(JMAPItemRecord.self, JSON.encode(item))
    #expect(try JSON.encode(decoded.canonicalRevision()) == before)
    #expect(try JSON.encode(revision) == before)
    let wire = try readJSON(item)
    #expect(wire["fields"]?["schemaVersion"]?["value"] == .string("1"))
    #expect(try JMAPValue.decode(before)["fields"]?["schemaVersion"]?["value"] == .number(JMAPNumber("1")))
}
@Test func jmapReadItemAndRevisionUseDistinctStableIdentities() throws {
    let revision = try readRevision()
    let item = try readJSON(JMAPItemRecord(revision, resolution: readState()))
    let historical = try readJSON(JMAPRevisionRecord(revision))
    #expect(item["id"] == .string(readItemID))
    #expect(item["revisionId"] == .string(readRevisionID))
    #expect(historical["id"] == .string(readRevisionID))
    #expect(historical["itemId"] == .string(readItemID))
    #expect(
        try JSON.decode(JMAPRevisionRecord.self, JSON.encode(JMAPRevisionRecord(revision)))
            .canonicalRevision() == revision)
}
@Test func jmapReadPropertiesSelectDTOAndAlwaysIncludeID() throws {
    let revision = try readRevision()
    let item = try readJSON(
        JMAPItemRecord(revision, resolution: readState(), properties: ["revisionId", "revisionId"]))
    let expected = try JMAPValue.decode(
        Data("{\"id\":\"\(readItemID)\",\"revisionId\":\"\(readRevisionID)\"}".utf8))
    #expect(item == expected)
    let historical = try readJSON(JMAPRevisionRecord(revision, properties: []))
    #expect(historical.members?.count == 1)
    #expect(historical["id"] == .string(readRevisionID))
    #expect(throws: TractandaError("invalidArguments", "Unknown read object property.")) {
        try JMAPReadProperties(["subject"], record: .item)
    }
}
@Test func jmapReadSelectedFieldsDecodeWithoutUnselectedIdentityProjections() throws {
    let record = try JMAPItemRecord(readRevision(), resolution: readState(), properties: ["fields"])
    let decoded = try JSON.decode(JMAPItemRecord.self, JSON.encode(record))
    #expect(decoded.id == readItemID)
    #expect(decoded.fields?["revisionID"]?.string == readRevisionID)
    #expect(decoded.revisionID == nil)
    #expect(throws: (any Error).self) { try decoded.canonicalRevision() }
    let historical = try JMAPRevisionRecord(readRevision(), properties: ["fields"])
    #expect(try JSON.decode(JMAPRevisionRecord.self, JSON.encode(historical)).fields == historical.fields)
}
@Test func jmapReadUnresolvedItemHasAuthorizedFrontierAndExplicitNullContent() throws {
    let state = ItemState(
        itemID: readItemID, stateToken: "conflicted", status: .conflicted,
        frontier: [readRevisionID, readOtherID], conflictingFields: ["body"], detailsComplete: true)
    let record = try JMAPItemRecord(unresolved: state)
    let wire = try readJSON(record)
    #expect(wire["id"] == .string(readItemID))
    #expect(wire["revisionId"] == .null)
    #expect(wire["formatVersion"] == .null)
    #expect(wire["fields"] == .null)
    #expect(wire["resolution"]?["frontier"] == .array([.string(readRevisionID), .string(readOtherID)]))
    #expect(try JSON.decode(JMAPItemRecord.self, JSON.encode(record)).resolution == state)
    #expect(throws: (any Error).self) { try record.canonicalRevision() }
}
@Test func jmapReadUnresolvedRejectsSyntheticOrStaleRepresentativeContent() throws {
    let state = ItemState(
        itemID: readItemID, stateToken: "review", status: .reviewRequired, detailsComplete: false)
    #expect(throws: (any Error).self) {
        try JMAPItemRecord(readRevision(), resolution: state)
    }
    #expect(throws: (any Error).self) {
        try JMAPItemRecord(
            id: readItemID, revisionID: readRevisionID, formatVersion: 1, fields: nil, resolution: state)
    }
    #expect(throws: (any Error).self) { try JMAPItemRecord(unresolved: readState()) }
}
@Test func jmapReadRejectsConflictingReadOnlyIdentities() throws {
    let revision = try readRevision()
    #expect(throws: (any Error).self) {
        try JMAPItemRecord(
            id: readOtherID, revisionID: readRevisionID, formatVersion: 1, fields: revision.fields,
            resolution: nil)
    }
    #expect(throws: (any Error).self) {
        try JMAPRevisionRecord(id: readOtherID, itemID: readItemID, formatVersion: 1, fields: revision.fields)
    }
}
@Test func jmapReadGetNormalizesEmptyDuplicateAndNullIDsWithConfiguredLimit() throws {
    #expect(try JMAPGetIDs.normalize([], maximum: 1).isEmpty)
    #expect(
        try JMAPGetIDs.normalize([readItemID, readItemID, readOtherID], maximum: 2) == [
            readItemID, readOtherID,
        ])
    #expect(throws: (any Error).self) { try JMAPGetIDs.normalize(nil, maximum: 2) }
    #expect(throws: TractandaError("requestTooLarge", "The requested IDs exceed maxObjectsInGet.")) {
        try JMAPGetIDs.normalize([readItemID, readOtherID], maximum: 1)
    }
}
@Test func jmapReadStandardComparatorDefaultsAndExplicitCategoryAxis() throws {
    let comparator = try JSON.decode(JMAPReadComparator.self, Data(##"{"property":"subject"}"##.utf8))
    #expect(comparator.isAscending)
    #expect(try comparator.itemSort(supportedCollations: []) == ItemSort(property: "subject"))
    let category = try ItemSort(categoryRootID: readItemID, isAscending: false)
    let wire = try readJSON(JMAPReadComparator(category))
    #expect(wire["property"] == .string("categoryMembership"))
    #expect(wire["categoryRootId"] == .string(readItemID))
    #expect(
        try JSON.decode(JMAPReadComparator.self, JSON.encode(JMAPReadComparator(category))).itemSort(
            supportedCollations: []) == category)
}
@Test func jmapReadComparatorRejectsUnsupportedCollationAndInvalidAxis() throws {
    let comparator = try JMAPReadComparator(property: "subject", collation: "unsupported")
    #expect(throws: TractandaError("unsupportedSort", "Unsupported comparator collation.")) {
        try comparator.itemSort(supportedCollations: [])
    }
    #expect(throws: (any Error).self) {
        try JMAPReadComparator(property: "subject", categoryRootID: readItemID)
    }
    #expect(throws: (any Error).self) { try JMAPReadComparator(property: "categoryMembership") }
}

@Test func jmapReadUnresolvedRetainsDiagnosticLocatorWithoutExposingStaleContent() throws {
    let state = ItemState(
        itemID: readItemID, stateToken: "blocked", status: .unmaterializable,
        representativeRevisionID: readRevisionID, frontier: [readRevisionID, readOtherID],
        detailsComplete: true,
        resource: ItemStateResource(code: "resourceLimit", phase: .publication, message: "Fixture"))
    let record = try JMAPItemRecord(unresolved: state)
    let wire = try readJSON(record)
    #expect(wire["revisionId"] == .null)
    #expect(wire["formatVersion"] == .null)
    #expect(wire["fields"] == .null)
    #expect(wire["resolution"]?["representativeRevisionID"] == .string(readRevisionID))
    let decoded = try JSON.decode(JMAPItemRecord.self, JSON.encode(record))
    #expect(decoded.resolution == state)
    #expect(throws: (any Error).self) { try decoded.canonicalRevision() }
}

@Test func jmapReadIDsAcceptValidUnknownOpaqueAndCaseDistinctIDs() throws {
    #expect(
        try JMAPGetIDs.normalize(["opaque_ID-1", "Opaque_ID-1", readItemID.uppercased()], maximum: 3) == [
            "opaque_ID-1", "Opaque_ID-1", readItemID.uppercased(),
        ])
    for id in ["", "space name", "has/slash", "has=pad", String(repeating: "x", count: 256), "é"] {
        #expect(throws: (any Error).self) { try JMAPGetIDs.validate(id) }
    }
}
