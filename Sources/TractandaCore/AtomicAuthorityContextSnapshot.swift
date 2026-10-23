import CSQLite
import Foundation

/// Captures historical input descriptors only. The caller owns the lifetime writer and current
/// authority decision; this helper never accepts a control or exports private configuration.
enum AtomicAuthorityContextSnapshot {
    private struct Input: Encodable {
        let rootID: String
        let packageID: String
        let physicalManifestSHA256: String
        let configuration: AtomicAuthorityAcceptance.ConfigurationReference
        let contextSHA256: String
        let requestPrincipal: String
        let validationPurpose: AtomicAuthorityAcceptance.ValidationPurpose
    }

    static func prepare(
        index: ItemIndex, coordinator: PeerIntakeCoordinator, rootID: String, packageID: String,
        privateRoot: URL, maximumStoredBytes: UInt64, requestPrincipal: String,
        expectedContextSHA256: String, currentContext: () throws -> String,
        validationPurpose: AtomicAuthorityAcceptance.ValidationPurpose = .authenticatedRequest,
        progress: (() throws -> Void)? = nil
    ) throws -> AtomicAuthorityAcceptance.Context {
        _ = try AuthorityRecord.persistentID(.text(rootID))
        _ = try AuthorityRecord.persistentID(.text(packageID))
        _ = try AuthorityRecord.text(.text(requestPrincipal))
        _ = try AuthorityRecord.digest(.text(expectedContextSHA256))
        let limits = coordinator.journal.limits
        var work = 0
        func tick() throws {
            try Task.checkCancellation()
            guard work < limits.maximumWork else {
                throw TractandaError("resourceLimit", "Atomic context capture work allowance exhausted.")
            }
            work += 1
            try progress?()
        }
        let readBudget = coordinator.admissionReadBudget()
        func configuration() throws -> (
            AtomicAuthorityAcceptance.ConfigurationReference, AuthorityStore.Configuration
        ) {
            var latest: String?
            var entries = 0
            try coordinator.journal.files.withDirectoryEntries(path: [".peer-configuration"]) { name in
                try tick()
                guard entries < 100_000 else {
                    throw TractandaError("resourceLimit", "Atomic context configuration history exceeded.")
                }
                entries += 1
                let reference = AtomicAuthorityAcceptance.ConfigurationReference(
                    fileName: name, sha256: expectedContextSHA256)
                try reference.validate()
                if latest == nil || name > latest! { latest = name }
                return true
            }
            guard let latest else {
                throw AtomicAuthorityFormat.invalid(
                    "Atomic context requires canonical configuration history.")
            }
            let bytes = try coordinator.journal.files.read(
                path: [".peer-configuration", latest], maximumBytes: PeerPackage.maximumPageBytes,
                readBudget: readBudget)
            let value = try PeerPackage.decode(AuthorityStore.Configuration.self, bytes)
            guard value.profile == "tractanda.peer-configuration.v1", value.bootstrap != nil,
                value == (try coordinator.configuration(readBudget: readBudget))
            else { throw AtomicAuthorityFormat.invalid("Atomic context canonical configuration differs.") }
            try value.validateCredentialBindings()
            let reference = AtomicAuthorityAcceptance.ConfigurationReference(
                fileName: latest, sha256: AuthorityRecordCodec.sha256(bytes))
            try reference.validate()
            return (reference, value)
        }
        try tick()
        guard try currentContext() == expectedContextSHA256 else {
            throw AtomicAuthorityFormat.invalid("Atomic context changed before capture.")
        }
        guard let publication = try coordinator.journal.publication(packageID, readBudget: readBudget),
            publication.packageID == packageID, publication.context.storeID == coordinator.storeID
        else {
            throw AtomicAuthorityFormat.invalid("Atomic context requires a completed physical publication.")
        }
        let (configurationReference, configured) = try configuration()
        func requireCurrent() throws {
            try tick()
            guard try currentContext() == expectedContextSHA256,
                try configuration().0 == configurationReference,
                let current = try coordinator.journal.publication(packageID, readBudget: readBudget),
                current == publication
            else {
                throw AtomicAuthorityFormat.invalid(
                    "Atomic context/source publication changed during capture.")
            }
        }
        try index.initializeAtomicAuthorityAcceptedSchema()
        let token = "atomic-context:" + (try UUID.makeVersion1().uuidString.lowercased())
        try index.authorityBeginWalk(token: token)
        do {
            func add(_ binding: AuthorityBinding, descriptor: PeerPackage.Object? = nil) throws {
                try tick()
                guard let retained = try index.retainedAuthorityObject(id: binding.recordID),
                    retained.descriptor.kind == .authority, retained.descriptor.part == nil,
                    retained.descriptor.sha256 == binding.sha256,
                    descriptor.map({ $0 == retained.descriptor }) ?? true
                else {
                    throw AtomicAuthorityFormat.invalid(
                        "Atomic context original is missing or has conflicting identity/hash.")
                }
                try retained.descriptor.validate()
                _ = try index.authorityVisitOnce(token: token, id: binding.recordID)
            }
            guard let bootstrap = configured.bootstrap else {
                throw AtomicAuthorityFormat.invalid("Atomic context lacks its configured bootstrap.")
            }
            try add(.init(recordID: bootstrap.recordID, sha256: bootstrap.sha256))
            var after: String?
            while true {
                let page = try index.atomicCurrentHeadPage(afterRecordID: after, limit: 128)
                if page.isEmpty { break }
                for binding in page {
                    try add(binding)
                    after = binding.recordID
                }
            }
            try coordinator.journal.files.withDirectoryEntries(path: [PeerOriginAdmission.directory]) {
                origin in
                try tick()
                _ = try AuthorityRecord.persistentID(.text(origin))
                guard let decision = try coordinator.originDecision(origin, readBudget: readBudget) else {
                    throw AtomicAuthorityFormat.invalid("Atomic context canonical admission disappeared.")
                }
                try decision.approval.validate()
                try add(
                    .init(recordID: decision.approval.id, sha256: decision.approval.sha256),
                    descriptor: decision.approval)
                try add(decision.issuerAdmission)
                return true
            }
            for activation in configured.lifecycle?.retirements ?? [] { try add(activation.root) }
            try coordinator.foreignRetirements { activation in try add(activation.root) }
            var retirementCursor: AuthorityBinding?
            while true {
                let page = try index.atomicContextRetirementPage(after: retirementCursor)
                if page.isEmpty { break }
                for binding in page {
                    try add(binding)
                    retirementCursor = binding
                }
            }
            let count = try index.atomicContextWalkCount(token: token)
            guard count > 0, count <= Int64(limits.maximumObjects) else {
                throw TractandaError("resourceLimit", "Atomic context original count exceeded.")
            }
            try requireCurrent()
            let input = Input(
                rootID: rootID, packageID: packageID,
                physicalManifestSHA256: publication.manifestDigest, configuration: configurationReference,
                contextSHA256: expectedContextSHA256, requestPrincipal: requestPrincipal,
                validationPurpose: validationPurpose)
            let archive = try PeerLocalPackageArchive(
                root: privateRoot,
                limits: .init(
                    maximumStoredBytes: maximumStoredBytes, maximumObjects: limits.maximumObjects,
                    maximumWork: limits.maximumWork, maximumDepth: limits.maximumDepth,
                    minimumFreeBytes: limits.reserveBytes), progress: tick)
            var cursor: String?
            var descriptors: [String] = []
            var position = 0
            var emitted: Int64 = 0
            let manifest = try archive.build(
                storeID: coordinator.storeID, packageID: rootID,
                inputIdentity: AuthorityRecordCodec.sha256(JSON.encode(input))
            ) {
                if position == descriptors.count {
                    descriptors = try index.atomicContextWalkPage(token: token, after: cursor)
                    position = 0
                    if descriptors.isEmpty { return nil }
                }
                try tick()
                let id = descriptors[position]
                position += 1
                cursor = id
                guard let retained = try index.retainedAuthorityObject(id: id),
                    retained.descriptor.kind == .authority
                else {
                    throw AtomicAuthorityFormat.invalid(
                        "Atomic context descriptor disappeared during framing.")
                }
                emitted = try AtomicAuthorityFormat.sum(emitted, 1)
                return retained.descriptor
            }
            guard emitted == count else {
                throw AtomicAuthorityFormat.invalid("Atomic context descriptor count changed during framing.")
            }
            try requireCurrent()
            try archive.forEachIndexObject(manifest) { object, bytes in
                try tick()
                try coordinator.journal.stageAtomicContextPage(
                    packageID: packageID, rootID: rootID, object: object, bytes: bytes)
            }
            try requireCurrent()
            let result = AtomicAuthorityAcceptance.Context(
                configuration: configurationReference, authorities: manifest,
                authorityCount: count, requestPrincipal: requestPrincipal,
                validationPurpose: validationPurpose)
            try result.validate(storeID: coordinator.storeID, rootID: rootID)
            try index.authorityEndWalk(token: token)
            return result
        } catch {
            let original = error
            do { try index.authorityEndWalk(token: token) } catch {
                throw TractandaError(
                    "recoveryRequired",
                    "Private atomic context walk cleanup failed; retain its index recovery state.")
            }
            throw original
        }
    }
}

extension ItemIndex {
    fileprivate func atomicContextRetirementPage(after: AuthorityBinding?) throws -> [AuthorityBinding] {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            let s = try corpusPrepare(
                "SELECT DISTINCT retirement,digest FROM peer_lifecycle_retired"
                    + (after == nil ? "" : " WHERE retirement>? OR (retirement=? AND digest>?)")
                    + " ORDER BY retirement,digest LIMIT 128",
                after.map { [$0.recordID, $0.recordID, $0.sha256] } ?? [])
            defer { sqlite3_finalize(s) }
            var result: [AuthorityBinding] = []
            while true {
                try checkCatalogueScanProgress()
                let status = catalogueStep(s)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW else { throw graphSQLiteError() }
                result.append(try .init(recordID: atomicContextText(s, 0), sha256: atomicContextText(s, 1)))
            }
        }
    }
    fileprivate func atomicContextWalkCount(token: String) throws -> Int64 {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            let s = try corpusPrepare(
                "SELECT COUNT(*) FROM authority_walk WHERE token=? AND object<>''", [token])
            defer { sqlite3_finalize(s) }
            guard catalogueStep(s) == SQLITE_ROW else { throw graphSQLiteError() }
            return sqlite3_column_int64(s, 0)
        }
    }
    fileprivate func atomicContextWalkPage(token: String, after: String?) throws -> [String] {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            let s = try corpusPrepare(
                "SELECT object FROM authority_walk WHERE token=? AND object>? ORDER BY object LIMIT 128",
                [token, after ?? ""])
            defer { sqlite3_finalize(s) }
            var result: [String] = []
            while true {
                try checkCatalogueScanProgress()
                let status = catalogueStep(s)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW else { throw graphSQLiteError() }
                result.append(try AuthorityRecord.persistentID(.text(atomicContextText(s, 0))))
            }
        }
    }
    private func atomicContextText(_ statement: OpaquePointer, _ column: Int32) throws -> String {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT, count > 0, count <= 256,
            let bytes = sqlite3_column_text(statement, column),
            let result = String(data: Data(bytes: bytes, count: count), encoding: .utf8)
        else { throw AtomicAuthorityFormat.invalid("Malformed atomic context descriptor cursor text.") }
        return result
    }
}
