import CTractandaPlatform
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Internal first-source initialization only. Neither a client import nor enrollment authority.
/// Development conversion is a separate test-only caller, stopped and bounded before capture.
enum InitialAuthorityBootstrap {
    static let receiptName = ".tractanda-first-source.json"
    static let completeName = ".tractanda-first-source-complete.json"
    static let maximumReceiptBytes = 64 * 1024 * 1024
    struct Limits: Codable, Equatable {
        var maximumRecords = 8192
        var maximumBytes = 128 * 1024 * 1024
        var maximumWork = 262144
        var reserveBytes: UInt64 = 10 * 1024 * 1024 * 1024
        func validate() throws {
            guard maximumRecords > 0, maximumRecords <= 32768, maximumBytes > 0,
                maximumBytes <= 16 * 1024 * 1024 * 1024, maximumWork > 0, maximumWork <= 10_000_000,
                reserveBytes >= 10 * 1024 * 1024 * 1024
            else { throw failure("resourceLimit", "First-source admitted totals are invalid.") }
        }
    }
    struct Original: Codable, Equatable {
        let path: String
        let itemID: String
        let revisionID: String
        let sha256: String
        let length: Int
        let currentAccessConfiguration: Bool
        let mode: UInt32
        let uid: UInt32
        let packageID: String
        let framingID: String
    }
    struct Inventory: Codable, Equatable {
        let storeIdentity: Data
        let replicaIdentity: Data
        let originals: [Original]
    }
    struct Allocation: Codable, Equatable {
        let recordID: String
        let packageID: String
        let framingID: String
    }
    struct FoundingPolicy: Codable, Equatable {
        let original: Original
        let bytes: Data
    }
    struct Request: Codable, Equatable {
        let profile: String
        let operationID: String
        let initializationKey: String?
        let actorUID: UInt32
        let initialAccessConfiguration: ItemValue?
        let inventory: Inventory?
        let limits: Limits
        let rootID: String
        let pages: [Allocation]
        let indexID: String
        let packageID: String
        let framingID: String
        let createdAt: String
        let actor: String
        let freshStoreID: String?
        let freshReplicaID: String?
        let foundingPolicy: FoundingPolicy?

        static func make(
            operationID: String, actorUID: UInt32, policy: ItemValue?,
            inventory: Inventory?, limits: Limits = .init(), actor: String,
            initializationKey: String? = nil
        ) throws -> Self {
            _ = try AuthorityRecord.persistentID(.text(operationID))
            try limits.validate()
            guard (inventory == nil) != (policy == nil) else {
                throw failure("Expected fresh policy or conversion inventory.")
            }
            if let policy { _ = try AccessConfiguration(policy) }
            func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
            let createdAt = Timestamp.now()
            let storeID = try inventory == nil ? id() : nil
            let replicaID = try inventory == nil ? id() : nil
            let founding = try policy.map {
                try InitialAuthorityBootstrap.foundingPolicy(
                    policy: $0, operationID: operationID,
                    actorUID: actorUID, actor: actor, origin: replicaID!, createdAt: createdAt,
                    itemID: id(), revisionID: id(), packageID: id(), framingID: id())
            }
            return try .init(
                profile: "tractanda.first-source.v2", operationID: operationID,
                initializationKey: initializationKey, actorUID: actorUID, initialAccessConfiguration: policy,
                inventory: inventory, limits: limits,
                rootID: id(),
                pages: (0..<max(1, ((inventory?.originals.count ?? 0) + 127) / 128)).map { _ in
                    try Allocation(recordID: id(), packageID: id(), framingID: id())
                }, indexID: id(), packageID: id(), framingID: id(),
                createdAt: createdAt, actor: actor, freshStoreID: storeID,
                freshReplicaID: replicaID, foundingPolicy: founding)
        }
    }
    struct Completion: Codable, Equatable { let requestDigest: String }
    static func failure(_ message: String) -> TractandaError {
        failure("firstSourceConflict", message)
    }
    static func failure(_ code: String, _ message: String) -> TractandaError {
        TractandaError(code, message)
    }
    static func files(_ root: URL) -> DocumentContentFiles {
        DocumentContentFiles(root: root, ownerUID: tractanda_uid(), minimumFreeBytes: 0)
    }
    /// Real current-format initial content. It is admitted by the initial cut, not authored-A.
    private static func foundingPolicy(
        policy: ItemValue, operationID: String, actorUID: UInt32,
        actor: String, origin: String, createdAt: String, itemID: String, revisionID: String,
        packageID: String, framingID: String
    ) throws -> FoundingPolicy {
        guard actor == "uid:\(actorUID)", Timestamp.parse(createdAt) != nil else {
            throw failure("Invalid founding policy actor/time.")
        }
        let commit = CommitRequest(
            classID: AccessConfiguration.classID,
            changes: ["accessConfiguration": policy, "subject": .text("Store access configuration")],
            operationID: operationID)
        var fields: [String: ItemValue] = [
            "itemID": .text(itemID), "revisionID": .text(revisionID),
            "classID": .text(AccessConfiguration.classID), "schemaVersion": .integer(1),
            "createdAt": .date(createdAt), "modifiedAt": .date(createdAt), "actor": .text(actor),
            "operationID": .text(operationID),
            "requestIdentity": .text(try JSON.encode(commit).base64EncodedString()),
            "accessConfiguration": policy, "subject": .text("Store access configuration"),
        ]
        let plain = try Revision(fields: fields)
        fields["revisionAncestry"] = try RevisionProvenance(
            kind: .authored, originReplicaID: origin,
            parents: [], writtenFields: RevisionMerge.semanticFields(plain).keys.sorted(),
            unsetFields: [], frontier: []
        ).itemValue
        let revision = try Revision(fields: fields, formatVersion: 2)
        try ItemSemantics.validate(revision)
        let bytes = try RecordCodec.encode(revision)
        guard bytes.count <= PooledCanonicalRecord.maximumRecordBytes else {
            throw failure("resourceLimit", "Founding policy exceeds its original byte window.")
        }
        let minute = String(createdAt.prefix(16)).replacingOccurrences(of: "-", with: "/")
            .replacingOccurrences(of: "T", with: "/").replacingOccurrences(of: ":", with: "/")
        return .init(
            original: .init(
                path: "items/\(minute)/\(itemID)/\(revisionID).tractanda",
                itemID: itemID, revisionID: revisionID, sha256: AuthorityRecordCodec.sha256(bytes),
                length: bytes.count, currentAccessConfiguration: true, mode: UInt32(S_IFREG) | 0o400,
                uid: actorUID,
                packageID: packageID, framingID: framingID), bytes: bytes)
    }
    static func admittedOriginals(_ request: Request) -> [Original] {
        request.inventory?.originals ?? request.foundingPolicy.map { [$0.original] } ?? []
    }
    static func requireFreshCreator(
        _ request: Request, ownerUID: UInt32,
        accounts: any AccountDirectory
    ) throws {
        guard request.inventory == nil, request.actorUID == ownerUID,
            request.actor == "uid:\(ownerUID)", let value = request.initialAccessConfiguration
        else {
            throw failure("Fresh policy requires the exact owning creator.")
        }
        _ = try accounts.user(forUID: request.actorUID)
        let configuration = try AccessConfiguration(value)
        try configuration.validate(
            using: PrincipalResolver(directory: accounts, configuration: configuration))
    }
    /// Under Store's lifetime writer, before the sole initial-state capture. No eligibility grant.
    static func stageFoundingPolicy(
        root: URL, ownerUID: UInt32, request: Request,
        accounts: any AccountDirectory, progress: ((String) throws -> Void)?
    ) throws {
        guard let founding = request.foundingPolicy, let storeID = request.freshStoreID,
            let replicaID = request.freshReplicaID
        else { return }
        let files = files(root)
        let path = founding.original.path.split(separator: "/").map(String.init)
        let originalExists = FileManager.default.fileExists(
            atPath: root.appendingPathComponent(founding.original.path).path)
        let captured = [
            ".authority-initial-capture.json", ".authority-initial-state.json",
            ".authority-initial-state-sealed.json",
        ].contains { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
        let modern =
            try CanonicalReaderRequirement.load(root: root, ownerUID: ownerUID)?.recordFormats.contains(2)
            == true
        let identity = try ReplicaIdentity.initialize(
            root: root, storeID: storeID, ownerUID: ownerUID,
            hasModernOrigins: modern || originalExists || captured,
            allocate: { UUID(uuidString: replicaID)! })
        guard identity.replicaID == replicaID else { throw failure("Founding policy replica differs.") }
        if originalExists {
            guard try readOriginal(root: root, original: founding.original) == founding.bytes else {
                throw failure("Reserved founding policy bytes changed.")
            }
        } else {
            guard !captured else { throw failure("Captured founding policy is missing.") }
            try progress?("beforeFoundingPolicy")
            try requireFreshCreator(request, ownerUID: ownerUID, accounts: accounts)
            try capacity(root: root, limits: request.limits)
            try CanonicalReaderRequirement.beforePublication(root: root, ownerUID: ownerUID, format: 2)
            try StoreCheckpoint.markDirty(root: root)
            try files.writeImmutable(
                founding.bytes, path: path, maximumBytes: PooledCanonicalRecord.maximumRecordBytes)
            try progress?("afterFoundingPolicy")
        }
        if try !completed(root: root, request: request) {
            try validateOriginalInventory(root: root, request: request)
        }
    }
    static func load(root: URL) throws -> Request? {
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        guard
            let bytes = try files(root).readIfPresent(path: [receiptName], maximumBytes: maximumReceiptBytes)
        else { return nil }
        let request = try JSON.decode(Request.self, bytes)
        guard try JSON.encode(request) == bytes, request.profile == "tractanda.first-source.v2",
            (request.inventory == nil) != (request.initialAccessConfiguration == nil)
        else { throw failure("Invalid first-source receipt.") }
        try request.limits.validate()
        if let key = request.initializationKey {
            guard request.inventory == nil, !key.isEmpty, key.utf8.count <= 200, !key.contains("\0")
            else { throw failure("Invalid fresh initialization key.") }
        }
        if request.inventory == nil {
            guard let storeID = request.freshStoreID, let replicaID = request.freshReplicaID,
                storeID != replicaID, let founding = request.foundingPolicy,
                request.actor == "uid:\(request.actorUID)",
                founding
                    == (try foundingPolicy(
                        policy: request.initialAccessConfiguration!,
                        operationID: request.operationID, actorUID: request.actorUID, actor: request.actor,
                        origin: replicaID, createdAt: request.createdAt, itemID: founding.original.itemID,
                        revisionID: founding.original.revisionID, packageID: founding.original.packageID,
                        framingID: founding.original.framingID)),
                founding.bytes.count <= request.limits.maximumBytes
            else { throw failure("Fresh operation lacks its exact founding policy/identity commitments.") }
        } else if request.freshStoreID != nil || request.freshReplicaID != nil
            || request.foundingPolicy != nil
        {
            throw failure("Conversion cannot allocate replacement identities.")
        }
        let allocations =
            [
                request.operationID, request.rootID, request.indexID,
                request.packageID, request.framingID,
            ] + [request.freshStoreID, request.freshReplicaID].compactMap({ $0 })
            + request.pages.flatMap({ [$0.recordID, $0.packageID, $0.framingID] })
        let foundingIDs =
            request.foundingPolicy.map {
                [
                    $0.original.itemID, $0.original.revisionID,
                    $0.original.packageID, $0.original.framingID,
                ]
            } ?? []
        let ids = allocations + foundingIDs
        guard Set(ids).count == ids.count else { throw failure("Repeated first-source allocation.") }
        for id in ids {
            _ = try AuthorityRecord.persistentID(.text(id))
        }
        return request
    }
    static func digest(_ request: Request) throws -> String {
        AuthorityRecordCodec.sha256(try JSON.encode(request))
    }
    static func completed(root: URL, request: Request) throws -> Bool {
        guard let bytes = try files(root).readIfPresent(path: [completeName], maximumBytes: 4096)
        else { return false }
        guard try JSON.decode(Completion.self, bytes) == Completion(requestDigest: digest(request)) else {
            throw failure("Completion belongs to another operation.")
        }
        return true
    }
    /// Called only after acquiring Store's lifetime writer. No global bypass or ambient flag.
    static func requireOpeningAllowed(
        root: URL, ownerUID: UInt32, request: Request?,
        accounts: any AccountDirectory
    ) throws {
        if let old = try load(root: root) {
            if let request {
                guard old == request else { throw failure("First-source inputs changed.") }
                if request.inventory != nil {
                    try validateOriginalInventory(root: root, request: request)
                    let policy = try request.inventory!.originals.first(where: \.currentAccessConfiguration)
                        .map {
                            let revision = try RecordCodec.decode(readOriginal(root: root, original: $0))
                            guard let value = revision.fields["accessConfiguration"] else {
                                throw failure("Missing committed administration policy.")
                            }
                            return try AccessConfiguration(value)
                        }
                    try RebuildAdministratorPolicy(ownerUID: ownerUID, configuration: policy)
                        .authorize(uid: request.actorUID, accounts: accounts)
                }
            } else if try !completed(root: root, request: old) {
                throw failure(
                    "firstSourcePending", "First-source initialization is pending; use its exact operation.")
            }
            if let storeID = old.freshStoreID, let replicaID = old.freshReplicaID {
                if FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(".tractanda-store-identity.json").path)
                {
                    let value =
                        try JSONSerialization.jsonObject(with: storeIdentityBytes(root: root))
                        as? [String: Any]
                    guard value?["storeID"] as? String == storeID else {
                        throw failure("Fresh StoreID allocation was replaced.")
                    }
                }
                if let actual = try ReplicaIdentity.load(root: root, storeID: storeID, ownerUID: ownerUID) {
                    guard actual.replicaID == replicaID else {
                        throw failure("Fresh ReplicaID allocation was replaced.")
                    }
                }
            }
            return
        }
        guard let request else { return }
        guard request.inventory == nil, request.initialAccessConfiguration != nil else {
            throw failure("Conversion must be preflighted under ordinary current-policy administration.")
        }
        // Before any Store identity, directory or bootstrap may be created, reject all foreign state.
        try POSIXDirectory.withEntries(at: root) { name in
            guard name == ".writer.lock" else {
                throw failure("Fresh creation needs an empty dedicated root.")
            }
            return true
        }
        try capacity(root: root, limits: request.limits)
        try files(root).writeImmutable(
            JSON.encode(request), path: [receiptName], maximumBytes: maximumReceiptBytes)
    }
    static func capacity(root: URL, limits: Limits, available: (() throws -> UInt64)? = nil) throws {
        try limits.validate()
        let free: UInt64
        if let available {
            free = try available()
        } else {
            var value = statvfs()
            guard statvfs(root.path, &value) == 0, value.f_frsize > 0 else {
                throw failure("resourceLimit", "Cannot determine actual first-source filesystem capacity.")
            }
            let result = UInt64(value.f_bavail).multipliedReportingOverflow(by: UInt64(value.f_frsize))
            guard !result.overflow else { throw failure("resourceLimit", "Capacity overflow.") }
            free = result.partialValue
        }
        // Fixed ceiling covers originals, receipts and temporary derived work; never consume reserve.
        let estimate = UInt64(limits.maximumBytes).multipliedReportingOverflow(by: 4)
        let temporary = estimate.partialValue.addingReportingOverflow(32 * 1024 * 1024)
        let required = limits.reserveBytes.addingReportingOverflow(temporary.partialValue)
        guard !estimate.overflow, !temporary.overflow, !required.overflow, free >= required.partialValue
        else {
            throw failure("resourceLimit", "First-source work would consume the actual free-space reserve.")
        }
    }
    static func descriptor(_ bytes: Data, kind: PeerPackage.Kind, id: String) -> PeerPackage.Object {
        .init(kind: kind, id: id, length: bytes.count, sha256: AuthorityRecordCodec.sha256(bytes))
    }
    static func verifyPublication(
        _ objects: [(PeerPackage.Object, Data)], package: String,
        framing: String, path: String?, context: PeerPackage.Context, request: Request,
        coordinator: PeerIntakeCoordinator
    ) throws -> PeerIntakeJournal.Publication {
        let expectedPage = try JSON.encode(PeerPackage.Page(objects: objects.map(\.0), children: []))
        let expectedFraming = descriptor(expectedPage, kind: .index, id: framing)
        let begin = try coordinator.journal.beginRecord(package)
        let requestDigest = try digest(request)
        let manifestDigest = try AuthorityRecordCodec.sha256(JSON.encode(begin.manifest))
        guard let accepted = try coordinator.journal.publication(package),
            accepted.context == context, accepted.contextToken == requestDigest,
            accepted.localItemPath == path, begin.context == context,
            begin.manifest.packageID == package, begin.manifest.storeID == context.storeID,
            accepted.manifestDigest == manifestDigest,
            begin.manifest.root == expectedFraming,
            try coordinator.journal.object(expectedFraming, packageID: package) == expectedPage
        else { throw failure("Initial publication differs from its exact local operation.") }
        for (descriptor, bytes) in objects {
            guard try coordinator.journal.object(descriptor, packageID: package) == bytes else {
                throw failure("Initial publication object differs from its reserved original.")
            }
        }
        return accepted
    }
    static func records(root: URL, request: Request, storeID: String, origin: String, actor: String) throws
        -> [AuthorityRecord]
    {
        let entries = try admittedOriginals(request).map { original -> ItemValue in
            let bytes = try readOriginal(root: root, original: original)
            let revision = try RecordCodec.decode(bytes)
            return .object([
                "target": try AuthorityStore.Target(
                    itemID: revision.itemID, revisionID: revision.revisionID,
                    sha256: original.sha256
                ).itemValue,
                "frontier": .list(
                    (try revision.provenance?.kind == .automaticMerge
                        ? revision.provenance!.frontier : [revision.revisionID]).map(ItemValue.text)),
            ])
        }.sorted {
            $0.map!["target"]!.map!["revisionID"]!.string! < $1.map!["target"]!.map!["revisionID"]!.string!
        }
        guard request.pages.count == max(1, (entries.count + 127) / 128) else {
            throw failure("Bootstrap page allocations differ from admitted inventory.")
        }
        var pages: [AuthorityRecord] = []
        for (offset, allocation) in request.pages.enumerated() {
            pages.append(
                try AuthorityRecord(
                    recordID: allocation.recordID, storeID: storeID, originReplicaID: origin,
                    kind: .bootstrapPage, actorPrincipal: actor, createdAt: request.createdAt,
                    payload: [
                        "manifestID": .text(request.rootID),
                        "entries": .list(
                            Array(entries[(offset * 128)..<min((offset + 1) * 128, entries.count)])),
                    ]))
        }
        func binding(_ record: AuthorityRecord) throws -> ItemValue {
            try AuthorityBinding(
                recordID: record.recordID,
                sha256: AuthorityRecordCodec.sha256(AuthorityRecordCodec.encode(record))
            ).itemValue
        }
        pages.sort { $0.recordID < $1.recordID }
        let index = try AuthorityRecord(
            recordID: request.indexID, storeID: storeID, originReplicaID: origin,
            kind: .bootstrapIndex, parentAuthorityIDs: pages.map(\.recordID), actorPrincipal: actor,
            createdAt: request.createdAt,
            payload: ["manifestID": .text(request.rootID), "children": .list(try pages.map(binding))])
        let policies = try admittedOriginals(request).compactMap { original -> ItemValue? in
            let bytes = try readOriginal(root: root, original: original)
            let revision = try RecordCodec.decode(bytes)
            guard original.currentAccessConfiguration, revision.classID == AccessConfiguration.classID else {
                return nil
            }
            return try AuthorityStore.Target(
                itemID: revision.itemID, revisionID: revision.revisionID,
                sha256: original.sha256
            ).itemValue
        }.sorted { $0.map!["revisionID"]!.string! < $1.map!["revisionID"]!.string! }
        let root = try AuthorityRecord(
            recordID: request.rootID, storeID: storeID, originReplicaID: origin,
            kind: .bootstrap, parentAuthorityIDs: [index.recordID], actorPrincipal: actor,
            createdAt: request.createdAt,
            payload: [
                "pages": .list([try binding(index)]), "initial": .boolean(true),
                "administrationPolicies": .list(policies),
            ])
        return pages + [index, root]
    }
}

extension InitialAuthorityBootstrap {
    static func storeIdentityBytes(root: URL) throws -> Data {
        let path = root.appendingPathComponent(".tractanda-store-identity.json")
        let before = try FileMetadata.read(at: path)
        try PrivateConfiguration.validate(path, directory: false)
        guard before.size > 0, before.size <= 4096 else { throw failure("Invalid logical identity size.") }
        let bytes = try Data(contentsOf: path)
        guard try FileMetadata.read(at: path) == before else { throw failure("Logical identity changed.") }
        return bytes
    }
    static func readOriginal(root: URL, original: Original) throws -> Data {
        guard original.length > 0, original.length <= PooledCanonicalRecord.maximumRecordBytes,
            CanonicalRecordPath.validate(
                original.path, itemID: original.itemID, revisionID: original.revisionID)
        else { throw failure("Invalid reserved original path/length.") }
        let path = original.path.split(separator: "/").map(String.init)
        let bytes = try files(root).read(path: path, maximumBytes: original.length)
        let metadata = try FileMetadata.read(at: root.appendingPathComponent(original.path))
        guard bytes.count == original.length, AuthorityRecordCodec.sha256(bytes) == original.sha256,
            metadata.mode == original.mode, metadata.uid == original.uid,
            metadata.type == .regular, metadata.size == UInt64(original.length)
        else { throw failure("Reserved original bytes or permissions changed.") }
        return bytes
    }
    /// Independent filesystem walk bounds constructor capture and detects catalogue omissions.
    /// The actual immutable file is verified again at each retain, not copied into the receipt.
    static func validateOriginalInventory(
        root: URL, request: Request,
        progress: (() throws -> Void)? = nil
    ) throws {
        let files = files(root)
        if let inventory = request.inventory {
            guard try storeIdentityBytes(root: root) == inventory.storeIdentity else {
                throw failure("Logical identity changed after preflight.")
            }
            let replica = try files.readIfPresent(
                path: [".tractanda-replica-identity.json"], maximumBytes: 4096)
            guard replica == inventory.replicaIdentity else {
                throw failure("Local identity changed after preflight.")
            }
        } else {
            let identity =
                try JSONSerialization.jsonObject(with: storeIdentityBytes(root: root)) as? [String: Any]
            guard let storeID = request.freshStoreID, identity?["storeID"] as? String == storeID,
                let replica = try ReplicaIdentity.load(
                    root: root, storeID: storeID, ownerUID: request.actorUID),
                replica.replicaID == request.freshReplicaID
            else { throw failure("Fresh identities changed after allocation.") }
        }
        let originals = admittedOriginals(request)
        guard originals.count <= request.limits.maximumRecords else {
            throw failure("resourceLimit", "First-source total record limit exceeded.")
        }
        var expected: [String: Original] = [:]
        for original in originals {
            guard expected.updateValue(original, forKey: original.path) == nil else {
                throw failure("Repeated original path in first-source receipt.")
            }
        }
        var work = 0
        var count = 0
        var total = 0
        func walk(_ directory: URL, depth: Int) throws {
            guard depth <= 8 else { throw failure("resourceLimit", "Initial inventory depth exceeded.") }
            try POSIXDirectory.withEntries(at: directory) { name in
                work += 1
                guard work <= request.limits.maximumWork else {
                    throw failure("resourceLimit", "Initial inventory work exceeded.")
                }
                try progress?()
                try capacity(root: root, limits: request.limits)
                let child = directory.appendingPathComponent(name)
                let metadata = try FileMetadata.read(at: child)
                if metadata.type == .directory {
                    try walk(child, depth: depth + 1)
                } else if metadata.type == .regular, name.hasSuffix(".tractanda") {
                    let path = String(child.path.dropFirst(root.path.count + 1))
                    guard let original = expected[path], count < request.limits.maximumRecords,
                        metadata.size <= UInt64(request.limits.maximumBytes - total)
                    else {
                        throw failure("resourceLimit", "Unadmitted or excessive initial canonical inventory.")
                    }
                    _ = try readOriginal(root: root, original: original)
                    count += 1
                    total += Int(metadata.size)
                } else {
                    throw failure("Unsafe initial canonical inventory.")
                }
                return true
            }
        }
        try walk(root.appendingPathComponent("items"), depth: 0)
        guard count == expected.count else { throw failure("Initial inventory is incomplete.") }
    }
}
