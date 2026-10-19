import CTractandaPlatform
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Local private identity: retained by restores, excluded from peer replication packages.
enum ReplicaIdentity {
    static let name = ".tractanda-replica-identity.json"
    struct Record: Codable, Equatable {
        let formatVersion: Int
        let storeID: String
        let replicaID: String
    }

    static func load(root: URL, storeID: String, ownerUID: UInt32, readBudget: ((Int) throws -> Void)? = nil)
        throws -> Record?
    {
        let files = DocumentContentFiles(root: root, ownerUID: ownerUID, minimumFreeBytes: 0)
        guard let bytes = try files.readIfPresent(path: [name], maximumBytes: 4096, readBudget: readBudget)
        else { return nil }
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            Set(object.keys) == ["formatVersion", "storeID", "replicaID"]
        else { throw TractandaError("invalidReplicaIdentity", "Invalid local replica identity keys.") }
        let record = try JSON.decode(Record.self, bytes)
        guard record.formatVersion == 1, record.storeID == storeID, record.replicaID != storeID,
            let uuid = UUID(uuidString: record.replicaID), uuid.version1Components != nil,
            uuid.uuidString.lowercased() == record.replicaID
        else {
            throw TractandaError(
                "invalidReplicaIdentity", "Local replica identity does not match this store.")
        }
        return record
    }

    /// The Store owns the root writer lock and has authenticated write authority before calling.
    static func initialize(
        root: URL, storeID: String, ownerUID: UInt32, hasModernOrigins: Bool,
        allocate: () throws -> UUID = UUID.makeVersion1
    ) throws -> Record {
        if let existing = try load(root: root, storeID: storeID, ownerUID: ownerUID) { return existing }
        guard !hasModernOrigins else {
            throw TractandaError(
                "missingReplicaIdentity", "Modern history requires its retained local replica identity.")
        }
        let record = try fresh(storeID: storeID, allocate: allocate)
        let files = DocumentContentFiles(root: root, ownerUID: ownerUID, minimumFreeBytes: 0)
        try files.writeImmutable(JSON.encode(record), path: [name], maximumBytes: 4096)
        return record
    }

    /// Explicit clone preparation only. Callers must hold the cloned root's writer lock;
    /// ordinary opens/restores never rotate identity. There is no shipped clone command yet.
    static func replaceForExplicitClone(
        root: URL, storeID: String, ownerUID: UInt32, allocate: () throws -> UUID = UUID.makeVersion1
    ) throws -> Record {
        let existing = try load(root: root, storeID: storeID, ownerUID: ownerUID)
        let record = try fresh(storeID: storeID, allocate: allocate)
        guard existing?.replicaID != record.replicaID else {
            throw TractandaError("identifierCollision", "Clone identity repeated the previous replica.")
        }
        let files = DocumentContentFiles(root: root, ownerUID: ownerUID, minimumFreeBytes: 0)
        let temporary = ".replica-clone-" + UUID().uuidString.lowercased()
        try files.writeImmutable(JSON.encode(record), path: [temporary], maximumBytes: 4096)
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else {
            throw TractandaError("invalidReplicaIdentity", "Cannot open private replica root.")
        }
        defer {
            _ = temporary.withCString { unlinkat(directory, $0, 0) }
            _ = close(directory)
        }
        guard try load(root: root, storeID: storeID, ownerUID: ownerUID) == existing else {
            throw TractandaError(
                "invalidReplicaIdentity", "Replica identity changed during clone preparation.")
        }
        let renamed = temporary.withCString { source in
            name.withCString { renameat(directory, source, directory, $0) }
        }
        guard renamed == 0, fsync(directory) == 0 else {
            throw TractandaError("invalidReplicaIdentity", "Cannot durably replace cloned replica identity.")
        }
        return record
    }

    private static func fresh(storeID: String, allocate: () throws -> UUID) throws -> Record {
        let uuid = try allocate()
        guard uuid.version1Components != nil, uuid.uuidString.lowercased() != storeID else {
            throw TractandaError("identifierCollision", "Replica allocation must issue a distinct UUIDv1.")
        }
        return Record(formatVersion: 1, storeID: storeID, replicaID: uuid.uuidString.lowercased())
    }
}
