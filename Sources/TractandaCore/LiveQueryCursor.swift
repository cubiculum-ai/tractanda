import Crypto
import Foundation

/// Authenticated continuity token. It binds a page request but carries no authorization.
struct LiveQueryCursor: Codable {
    let domain: String
    let version: Int
    let storeID: String
    let actorUID: UInt32
    let queryDigest: String
    let state: String
    let orderField: String
    let boundary: Double
    let boundaryID: String
    let position: Int
    let totalReference: String
    let previous: Bool
    let evaluatedAt: String
    let timeZone: String

    private static let key = SymmetricKey(size: .bits256)
    static let tokenDomain = "tractanda.live-query-cursor.v1"
    private final class TotalCache: @unchecked Sendable {
        struct Entry {
            let total: Int
            let storeID: String
            let actorUID: UInt32
            let queryDigest: String
            let state: String
        }
        let lock = NSLock()
        var entries: [String: Entry] = [:]
        var order: [String] = []
    }
    private static let totalCache = TotalCache()

    static func retainTotal(total: Int, storeID: String, actorUID: UInt32, queryDigest: String, state: String)
        -> String
    {
        totalCache.lock.lock()
        defer { totalCache.lock.unlock() }
        if totalCache.entries.count >= 256, let oldest = totalCache.order.first {
            totalCache.entries.removeValue(forKey: oldest)
            totalCache.order.removeFirst()
        }
        let reference = Identifier.make()
        totalCache.entries[reference] = TotalCache.Entry(
            total: total, storeID: storeID, actorUID: actorUID, queryDigest: queryDigest, state: state)
        totalCache.order.append(reference)
        return reference
    }

    static func exactTotal(
        reference: String, storeID: String, actorUID: UInt32, queryDigest: String, state: String
    ) -> Int? {
        totalCache.lock.lock()
        defer { totalCache.lock.unlock() }
        guard let entry = totalCache.entries[reference], entry.storeID == storeID, entry.actorUID == actorUID,
            entry.queryDigest == queryDigest, entry.state == state
        else { return nil }
        return entry.total
    }

    static func encode(_ cursor: Self) throws -> String {
        guard cursor.domain == tokenDomain, cursor.version == 1 else { throw invalid() }
        let payload = try JSON.encode(cursor)
        guard let sealed = try AES.GCM.seal(payload, using: key).combined else { throw invalid() }
        return sealed.base64EncodedString()
    }

    static func decode(_ token: String) throws -> Self {
        guard token.utf8.count <= 8_192 else { throw invalid() }
        guard let combined = Data(base64Encoded: token),
            let box = try? AES.GCM.SealedBox(combined: combined),
            let payload = try? AES.GCM.open(box, using: key),
            let cursor = try? JSON.decode(Self.self, payload),
            cursor.domain == tokenDomain, cursor.version == 1,
            ["createdAt", "modifiedAt"].contains(cursor.orderField),
            cursor.boundary.isFinite, cursor.position >= 0,
            (try? Identifier.validate(cursor.boundaryID)) != nil
        else { throw invalid() }
        return cursor
    }

    static func digest(_ arguments: [String: Any]) throws -> String {
        let selected = arguments.filter {
            !["cursor", "position", "limit", "at", "timeZone"].contains($0.key)
        }
        let bytes = try JSONSerialization.data(
            withJSONObject: selected, options: [.sortedKeys, .fragmentsAllowed])
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func invalid() -> TractandaError {
        TractandaError("invalidCursor", "The live query cursor is invalid or no longer current.")
    }
}
