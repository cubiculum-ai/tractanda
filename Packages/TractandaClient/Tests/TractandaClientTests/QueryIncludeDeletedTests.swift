import Foundation
import Testing

@testable import TractandaClient

@Test func itemQueryIncludeDeletedRoundTripsAndDefaultsOff() throws {
    let query = ItemQuery(expression: "subject == 'memory'", includeDeleted: true)
    let data = try JSONEncoder().encode(query)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let filter = try #require(object["filter"] as? [String: Any])
    #expect(filter["includeDeleted"] as? Bool == true)
    #expect(try JSONDecoder().decode(ItemQuery.self, from: data) == query)
    let defaultData = try JSONEncoder().encode(ItemQuery())
    let defaultObject = try #require(JSONSerialization.jsonObject(with: defaultData) as? [String: Any])
    let defaultFilter = try #require(defaultObject["filter"] as? [String: Any])
    #expect(defaultFilter["includeDeleted"] == nil)
    #expect(try JSONDecoder().decode(ItemQuery.self, from: defaultData).includeDeleted == false)
}
