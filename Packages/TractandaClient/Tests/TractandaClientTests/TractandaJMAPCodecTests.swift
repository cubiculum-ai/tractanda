import Foundation
import Testing

@testable import TractandaClient

@Test func jmapDeclaredCodecPreservesCanonicalIdentityAndInt64() throws {
    let canonical = try JMAPValue.decode(
        Data(
            ##"{"changes":{"n":{"type":"integer","value":9223372036854775807},"nested":{"type":"list","value":[{"type":"integer","value":-9223372036854775808}]}},"operationID":"exact"}"##
                .utf8))
    let wire = try TractandaJMAPCodec.argumentsToWire(method: "TractandaItem/commit", arguments: canonical)
    #expect(wire["changes"]?["n"]?["value"]?.text == "9223372036854775807")
    #expect(
        try TractandaJMAPCodec.argumentsFromWire(method: "TractandaItem/commit", arguments: wire) == canonical
    )
}
@Test func jmapDeclaredCodecLeavesEchoAndUnknownJSONExact() throws {
    let arbitrary = try JMAPValue.decode(
        Data(
            ##"{"itemID":"#unknown","changes":{"n":{"type":"integer","value":9223372036854775807}},"n":1.125e200}"##
                .utf8))
    for method in ["Core/echo", "Future/method"] {
        #expect(try TractandaJMAPCodec.argumentsFromWire(method: method, arguments: arbitrary) == arbitrary)
        #expect(try TractandaJMAPCodec.argumentsToWire(method: method, arguments: arbitrary) == arbitrary)
    }
}
@Test func jmapDeclaredCreationIDsOnlyResolveDeclaredIDPositions() throws {
    let value = try JMAPValue.decode(
        Data(
            ##"{"itemID":"#new","changes":{"literal":{"type":"text","value":"#new"},"reference":{"type":"reference","value":{"itemID":"#new"}}},"operationID":"#new"}"##
                .utf8))
    let id = "11111111-1111-4111-8111-111111111111"
    let result = try TractandaJMAPCodec.argumentsFromWire(
        method: "TractandaItem/commit", arguments: value, createdIDs: ["new": id])
    #expect(result["itemID"]?.text == id)
    #expect(result["changes"]?["reference"]?["value"]?["itemID"]?.text == id)
    #expect(result["changes"]?["literal"]?["value"]?.text == "#new")
    #expect(result["operationID"]?.text == "#new")
}
@Test func jmapDeclaredCodecRejectsNumericWireTaggedIntegerAndDoesNotDoubleConvertReads() throws {
    let old = try JMAPValue.decode(Data(##"{"changes":{"n":{"type":"integer","value":42}}}"##.utf8))
    #expect(throws: (any Error).self) {
        try TractandaJMAPCodec.argumentsFromWire(method: "TractandaItem/commit", arguments: old)
    }
    let dto = try JMAPValue.decode(
        Data(##"{"list":[{"id":"fixture","fields":{"n":{"type":"integer","value":"42"}}}]}"##.utf8))
    #expect(try TractandaJMAPCodec.extensionResultToWire(method: "TractandaItem/get", result: dto) == dto)
    #expect(try TractandaJMAPCodec.extensionResultFromWire(method: "TractandaItem/get", result: dto) == dto)
}
