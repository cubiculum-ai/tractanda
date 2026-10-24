import CTractandaPlatform
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class CanonicalMaintenanceJournalTests: XCTestCase {
    private typealias Journal = CanonicalMaintenanceJournal
    private func id(_ n: Int) -> String { String(format: "%08x-0000-1000-8000-000000000001", n) }
    private final class Fixture {
        let directory: URL
        let root: URL
        let journal: URL
        let path: [String]
        let target: URL
        let writer: Int32
        init() throws {
            try AttachmentFixtureCapacity.requireFree()
            directory = try GuardedFixtureDirectory.create(
                prefix: "maintenance-journal-", source: #filePath, test: #function)
            root = directory.appendingPathComponent("canonical")
            journal = directory.appendingPathComponent("audit")
            path = [
                "authority", "locators", "00000001-0000-1000-8000-000000000001",
                "00000002-0000-1000-8000-000000000001",
            ]
            for url in [root, journal] {
                try FileManager.default.createDirectory(
                    at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            target = path.reduce(root) { $0.appendingPathComponent($1) }
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            struct StoreIdentity: Codable {
                let formatVersion: Int
                let storeID: String
            }
            let storeBytes = try JSON.encode(
                StoreIdentity(formatVersion: 1, storeID: "00000006-0000-1000-8000-000000000001"))
            let replicaBytes = try JSON.encode(
                ReplicaIdentity.Record(
                    formatVersion: 1, storeID: "00000006-0000-1000-8000-000000000001",
                    replicaID: "00000007-0000-1000-8000-000000000001"))
            for (name, bytes) in [
                (".tractanda-store-identity.json", storeBytes), (ReplicaIdentity.name, replicaBytes),
            ] {
                let url = root.appendingPathComponent(name)
                try bytes.write(to: url)
                guard chmod(url.path, name == ".tractanda-store-identity.json" ? 0o600 : 0o400) == 0 else {
                    throw TractandaError("testFixture", "Cannot seal identity.")
                }
            }
            let floor = CanonicalReaderRequirement(
                storeID: "00000006-0000-1000-8000-000000000001", minimumReaderLevel: 15,
                recordFormats: [1, 2], capabilities: [AtomicAuthorityCompatibility.capability])
            let floorURL = root.appendingPathComponent(CanonicalReaderRequirement.fileName)
            try JSON.encode(floor).write(to: floorURL)
            guard chmod(floorURL.path, 0o600) == 0 else {
                throw TractandaError("testFixture", "Cannot retain floor.")
            }
            writer = tractanda_lock(root.appendingPathComponent(".writer.lock").path)
            guard writer >= 0 else { throw TractandaError("testFixture", "Writer lock failed.") }
        }
        func seed(_ data: Data) throws {
            try data.write(to: target)
            guard chmod(target.path, 0o400) == 0 else {
                throw TractandaError("testFixture", "Cannot seal fixture.")
            }
        }
        func remove() throws {
            close(writer)
            try FileManager.default.removeItem(at: directory)
        }
    }
    private func plan(_ f: Fixture, before: Data?, after: Data?) -> Journal.Plan {
        .init(
            version: 1, operationID: id(5), storeID: id(6), replicaID: id(7),
            edits: [
                .init(
                    path: f.path, role: .locator, beforeSHA256: before.map(AuthorityRecordCodec.sha256),
                    after: after)
            ])
    }
    private func open(
        _ f: Fixture, _ p: Journal.Plan, limits: Journal.Limits = .init(),
        progress: (() throws -> Void)? = nil
    ) throws -> Journal {
        try .init(
            root: f.root, journal: f.journal, writerDescriptor: f.writer, plan: p, limits: limits,
            progress: progress)
    }
    private func code(_ body: () throws -> Void) -> String? {
        do {
            try body()
            XCTFail("Expected a fail-closed result.")
            return nil
        } catch let error as TractandaError { return error.code } catch {
            XCTFail("Unexpected error \(error)")
            return nil
        }
    }
    func testExactReplacementRetryAndRollbackPreserveOriginalInodeAndBarrier() throws {
        let f = try Fixture()
        defer { try? f.remove() }
        let old = Data("old metadata".utf8)
        let new = Data("new metadata".utf8)
        try f.seed(old)
        let inode = try FileMetadata.read(at: f.target).inode
        let p = plan(f, before: old, after: new)
        var journal: Journal? = try open(f, p)
        XCTAssertEqual(
            code { try Journal.requireOrdinaryOpeningAllowed(root: f.root) }, "maintenanceRequired")
        try journal!.apply(path: f.path, replacement: new)
        try journal!.applyAll()
        XCTAssertEqual(try Data(contentsOf: f.target), new)
        journal = nil
        journal = try open(f, p)
        try journal!.applyAll()
        try journal!.rollback()
        try journal!.rollback()
        XCTAssertEqual(try Data(contentsOf: f.target), old)
        XCTAssertEqual(try FileMetadata.read(at: f.target).inode, inode)
        XCTAssertEqual(code { try journal!.applyAll() }, "maintenanceConflict")
        XCTAssertEqual(
            code { try Journal.requireOrdinaryOpeningAllowed(root: f.root) }, "maintenanceRequired")
        journal = nil
    }
    func testEveryDurableBoundaryResumesWithoutNewIdentityOrLostBytes() throws {
        for boundary in [
            Journal.Boundary.intentDurable, .originalArchived, .replacementPublished, .completionDurable,
        ] {
            let f = try Fixture()
            defer { try? f.remove() }
            let old = Data("before".utf8)
            let new = Data("after".utf8)
            try f.seed(old)
            let p = plan(f, before: old, after: new)
            var journal: Journal? = try open(f, p)
            journal!.boundaryForTesting = { _, reached in
                if reached == boundary {
                    throw TractandaError("injectedCrash", "Private boundary interruption.")
                }
            }
            XCTAssertEqual(code { try journal!.applyAll() }, "injectedCrash")
            journal = nil
            journal = try open(f, p)
            try journal!.applyAll()
            XCTAssertEqual(try Data(contentsOf: f.target), new)
            try journal!.rollback()
            XCTAssertEqual(try Data(contentsOf: f.target), old)
            journal = nil
        }
    }
    func testForbiddenCreateModifyDeleteAndDifferentReplacementDoNotTouchCanonicalFiles() throws {
        let f = try Fixture()
        defer { try? f.remove() }
        let old = Data("old".utf8)
        let new = Data("new".utf8)
        try f.seed(old)
        let journal = try open(f, plan(f, before: old, after: new))
        for path in [
            ["items", "new.tractanda"], ["documents", "content", "payload"], [".peer-credentials", "key"],
            ["authority", "unplanned"],
        ] {
            for replacement in [Data("forbidden".utf8) as Data?, nil] {
                XCTAssertEqual(
                    code { try journal.apply(path: path, replacement: replacement) }, "maintenanceConflict")
                XCTAssertFalse(
                    FileManager.default.fileExists(
                        atPath: path.reduce(f.root) { $0.appendingPathComponent($1) }.path))
            }
        }
        XCTAssertEqual(code { try journal.apply(path: f.path, replacement: old) }, "maintenanceConflict")
        XCTAssertEqual(try Data(contentsOf: f.target), old)
    }
    func testUnknownOccupantAfterInterruptionStopsResumeAndRollback() throws {
        let f = try Fixture()
        defer { try? f.remove() }
        let old = Data("old".utf8)
        let new = Data("new".utf8)
        try f.seed(old)
        let p = plan(f, before: old, after: new)
        var journal: Journal? = try open(f, p)
        journal!.boundaryForTesting = { _, point in
            if point == .originalArchived { throw TractandaError("injectedCrash", "Stop.") }
        }
        XCTAssertEqual(code { try journal!.applyAll() }, "injectedCrash")
        journal = nil
        try f.seed(Data("unknown".utf8))
        journal = try open(f, p)
        XCTAssertEqual(code { try journal!.applyAll() }, "maintenanceConflict")
        journal = nil
        journal = try open(f, p)
        XCTAssertEqual(code { try journal!.rollback() }, "maintenanceConflict")
        XCTAssertEqual(try Data(contentsOf: f.target), Data("unknown".utf8))
        journal = nil
    }
    func testCreationAndDeletionAreExplicitAndRollbackRetainsAllBytes() throws {
        for isCreation in [true, false] {
            let f = try Fixture()
            defer { try? f.remove() }
            let data = Data("metadata".utf8)
            if !isCreation { try f.seed(data) }
            let journal = try open(
                f, plan(f, before: isCreation ? nil : data, after: isCreation ? data : nil))
            try journal.applyAll()
            XCTAssertEqual(FileManager.default.fileExists(atPath: f.target.path), isCreation)
            try journal.rollback()
            XCTAssertEqual(FileManager.default.fileExists(atPath: f.target.path), !isCreation)
            if !isCreation { XCTAssertEqual(try Data(contentsOf: f.target), data) }
        }
    }
    func testPlanTamperUnsafePathAndCapacityFailBeforeTargetMutation() throws {
        let f = try Fixture()
        defer { try? f.remove() }
        let old = Data("old".utf8)
        try f.seed(old)
        var limits = Journal.Limits()
        limits.minimumFreeBytes = UInt64.max
        XCTAssertEqual(
            code { _ = try open(f, plan(f, before: old, after: Data("new".utf8)), limits: limits) },
            "resourceLimit")
        XCTAssertEqual(try Data(contentsOf: f.target), old)
        XCTAssertNoThrow(try Journal.requireOrdinaryOpeningAllowed(root: f.root))
        let unsafe = Journal.Plan(
            version: 1, operationID: id(5), storeID: id(6), replicaID: id(7),
            edits: [.init(path: ["authority", "..", "items"], role: .locator, beforeSHA256: nil, after: old)])
        XCTAssertEqual(code { _ = try open(f, unsafe) }, "maintenanceConflict")
        let journal = try open(f, plan(f, before: old, after: Data("new".utf8)))
        _ = journal
        XCTAssertEqual(try Data(contentsOf: f.target), old)
    }

    func testRealStoreOpeningStopsBeforeRecoveryWhenMaintenanceMarkerExists() throws {
        let fixture = try AtomicAuthorityStoreFixture()
        fixture.source = nil
        let marker = fixture.sourceRoot.appendingPathComponent(Journal.pendingName)
        try Data("pending".utf8).write(to: marker)
        guard chmod(marker.path, 0o400) == 0 else { throw TractandaError("fixture", "Cannot seal marker") }
        let before = try FileManager.default.contentsOfDirectory(atPath: fixture.sourceRoot.path).sorted()
        XCTAssertEqual(
            code {
                _ = try AtomicAuthorityStoreFixture.open(fixture.sourceRoot, accounts: fixture.sourceAccounts)
            }, "maintenanceRequired")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.sourceRoot.path).sorted(), before)
        try fixture.capacity()
    }

    func testSymlinkAndForgedMetadataRoleCannotAuthorizeProtectedPaths() throws {
        let f = try Fixture()
        defer { try? f.remove() }
        let bytes = Data("preserve".utf8)
        let outside = f.directory.appendingPathComponent("outside")
        try bytes.write(to: outside)
        guard chmod(outside.path, 0o400) == 0,
            symlink(outside.path, f.target.path) == 0
        else { throw TractandaError("fixture", "Cannot make link") }
        XCTAssertEqual(
            code { _ = try open(f, plan(f, before: bytes, after: Data("changed".utf8))) },
            "maintenanceConflict")
        XCTAssertEqual(try Data(contentsOf: outside), bytes)
        XCTAssertNoThrow(try Journal.requireOrdinaryOpeningAllowed(root: f.root))
        for protected in [
            ["items", "x"], [".peer-credentials", "key"],
            ["authority", "intake", id(1), "originals", id(2), "0"],
        ] {
            let invalid = Journal.Plan(
                version: 1, operationID: id(5), storeID: id(6), replicaID: id(7),
                edits: [.init(path: protected, role: .packageMetadata, beforeSHA256: nil, after: bytes)])
            XCTAssertEqual(code { _ = try open(f, invalid) }, "maintenanceConflict")
        }
    }

    func testFloor14RefusesMaintenanceWithoutRaisingMarkerOrTouchingData() throws {
        let f = try Fixture()
        defer { try? f.remove() }
        let data = Data("preserved".utf8)
        try f.seed(data)
        let prior = CanonicalReaderRequirement(storeID: id(6), minimumReaderLevel: 14, recordFormats: [1, 2])
        let url = f.root.appendingPathComponent(CanonicalReaderRequirement.fileName)
        let bytes = try JSON.encode(prior)
        try bytes.write(to: url)
        XCTAssertEqual(
            code { _ = try open(f, plan(f, before: data, after: Data("new".utf8))) },
            "atomicAuthorityTransitionRequired")
        XCTAssertEqual(try Data(contentsOf: f.target), data)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertNoThrow(try Journal.requireOrdinaryOpeningAllowed(root: f.root))
    }

    func testInterruptedRollbackResumesOnlyFromRecordedCustody() throws {
        for boundary in [
            Journal.Boundary.rollbackReplacementArchived, .rollbackOriginalRestored,
            .rollbackCompletionDurable,
        ] {
            let f = try Fixture()
            defer { try? f.remove() }
            let old = Data("old".utf8)
            let new = Data("new".utf8)
            try f.seed(old)
            let originalInode = try FileMetadata.read(at: f.target).inode
            let p = plan(f, before: old, after: new)
            var journal: Journal? = try open(f, p)
            try journal!.applyAll()
            journal!.boundaryForTesting = { _, reached in
                if reached == boundary { throw TractandaError("injectedCrash", "Rollback interruption") }
            }
            XCTAssertEqual(code { try journal!.rollback() }, "injectedCrash")
            XCTAssertEqual(code { try journal!.rollback() }, "maintenanceConflict")
            journal = nil
            journal = try open(f, p)
            try journal!.rollback()
            XCTAssertEqual(try Data(contentsOf: f.target), old)
            XCTAssertEqual(try FileMetadata.read(at: f.target).inode, originalInode)
            journal = nil
        }
    }

    func testUnexpectedDeletionReplacementCannotBecomeAnAfterState() throws {
        let f = try Fixture()
        defer { try? f.remove() }
        let old = Data("old".utf8)
        let unexpected = Data("unplanned".utf8)
        try f.seed(old)
        let slot = f.journal.appendingPathComponent("replacement-0")
        try unexpected.write(to: slot)
        guard chmod(slot.path, 0o400) == 0 else { throw TractandaError("fixture", "Cannot seal slot") }
        let journal = try open(f, plan(f, before: old, after: nil))
        XCTAssertEqual(code { try journal.applyAll() }, "maintenanceConflict")
        XCTAssertEqual(try Data(contentsOf: f.target), old)
        XCTAssertEqual(try Data(contentsOf: slot), unexpected)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: f.journal.appendingPathComponent("intent-0.json").path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: f.journal.appendingPathComponent("original-0").path))
    }
    func testProgressSubstitutionCannotRelocateForwardOriginalOrPublishReplacement() throws {
        for staged in [false, true] {
            for directory in [false, true] {
                let f = try Fixture()
                defer { try? f.remove() }
                let old = Data("old".utf8)
                let new = Data("new".utf8)
                let unexpected = Data("unexpected".utf8)
                try f.seed(old)
                let source = staged ? f.journal.appendingPathComponent("replacement-0") : f.target
                let saved = f.directory.appendingPathComponent("preserved-source")
                var armed = false
                var substituted = false
                let journal = try open(
                    f, plan(f, before: old, after: new),
                    progress: {
                        if armed {
                            armed = false
                            guard rename(source.path, saved.path) == 0 else {
                                throw TractandaError("fixture", "Cannot preserve source")
                            }
                            if directory {
                                guard mkdir(source.path, 0o700) == 0 else {
                                    throw TractandaError("fixture", "Cannot substitute kind")
                                }
                            } else {
                                try unexpected.write(to: source)
                                guard chmod(source.path, 0o400) == 0 else {
                                    throw TractandaError("fixture", "Cannot seal substitution")
                                }
                            }
                            substituted = true
                        }
                    })
                journal.boundaryForTesting = { _, boundary in
                    if boundary == (staged ? .originalArchived : .intentDurable) { armed = true }
                }
                XCTAssertEqual(code { try journal.applyAll() }, "maintenanceConflict")
                XCTAssertTrue(substituted)
                XCTAssertEqual(try Data(contentsOf: saved), staged ? new : old)
                XCTAssertEqual(try FileMetadata.read(at: source).type, directory ? .directory : .regular)
                if staged {
                    XCTAssertFalse(FileManager.default.fileExists(atPath: f.target.path))
                    XCTAssertEqual(try Data(contentsOf: f.journal.appendingPathComponent("original-0")), old)
                } else {
                    XCTAssertFalse(
                        FileManager.default.fileExists(
                            atPath: f.journal.appendingPathComponent("original-0").path))
                }
            }
        }
    }
    func testProgressSubstitutionCannotRelocateRollbackReplacementOrRestoreUnknownOriginal() throws {
        for restoringOriginal in [false, true] {
            for directory in [false, true] {
                let f = try Fixture()
                defer { try? f.remove() }
                let old = Data("old".utf8)
                let new = Data("new".utf8)
                let unexpected = Data("unexpected".utf8)
                try f.seed(old)
                let source = restoringOriginal ? f.journal.appendingPathComponent("original-0") : f.target
                let saved = f.directory.appendingPathComponent("preserved-source")
                var armed = false
                var substituted = false
                let journal = try open(
                    f, plan(f, before: old, after: new),
                    progress: {
                        if armed {
                            armed = false
                            guard rename(source.path, saved.path) == 0 else {
                                throw TractandaError("fixture", "Cannot preserve rollback source")
                            }
                            if directory {
                                guard mkdir(source.path, 0o700) == 0 else {
                                    throw TractandaError("fixture", "Cannot substitute rollback kind")
                                }
                            } else {
                                try unexpected.write(to: source)
                                guard chmod(source.path, 0o400) == 0 else {
                                    throw TractandaError("fixture", "Cannot seal rollback substitution")
                                }
                            }
                            substituted = true
                        }
                    })
                try journal.applyAll()
                journal.boundaryForTesting = { _, boundary in
                    if boundary == (restoringOriginal ? .rollbackReplacementArchived : .rollbackIntentDurable)
                    {
                        armed = true
                    }
                }
                XCTAssertEqual(code { try journal.rollback() }, "maintenanceConflict")
                XCTAssertTrue(substituted)
                XCTAssertEqual(try Data(contentsOf: saved), restoringOriginal ? old : new)
                XCTAssertEqual(try FileMetadata.read(at: source).type, directory ? .directory : .regular)
                if restoringOriginal {
                    XCTAssertFalse(FileManager.default.fileExists(atPath: f.target.path))
                } else {
                    XCTAssertFalse(
                        FileManager.default.fileExists(
                            atPath: f.journal.appendingPathComponent("rolled-back-new-0").path))
                }
            }
        }
    }
}
