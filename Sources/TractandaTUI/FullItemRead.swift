import Foundation
import TractandaCore

/// Full-content TUI browsing adapter. Selected DTO projections never use this canonical conversion.
struct FullItemRead: Decodable, Sendable {
    let list: [Revision]
    let notFound: [String]
    let unresolved: [ItemUnresolvedState]?
    let remainingIDs: [String]?
    let oversizedIDs: [String]?
    let state: String
    init(from decoder: any Decoder) throws {
        let result = try JMAPItemGetResponse(from: decoder).canonicalResult()
        list = result.list
        notFound = result.notFound
        unresolved = result.unresolved
        remainingIDs = result.remainingIDs
        oversizedIDs = result.oversizedIDs
        state = result.state
    }
}
