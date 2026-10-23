import CTractandaPlatform
import XCTest

@testable import TractandaCore

/// Genuine native initialized source plus explicit quiescent transition; no authority bypass.
final class AtomicAuthorityStoreFixture {
    let directory: URL
    let sourceRoot: URL
    let sourceAccounts = PeerIntakeStoreTests.Accounts()
    var source: ItemStore!
    var storeID = ""
    init(support: CanonicalFormatSupport = .current) throws {
        try AttachmentFixtureCapacity.requireFree()
        directory = try GuardedFixtureDirectory.create(
            prefix: "atomic-local-writer-", source: #filePath, test: #function)
        sourceRoot = directory.appendingPathComponent("source")
        source = try ItemStore.createInitialized(
            root: sourceRoot, accounts: sourceAccounts,
            initialAccessConfiguration: .object([
                "profile": .text(AccessConfiguration.profile),
                "users": .list([.text("admin"), .text("alice"), .text("bob")]),
            ]), actorUID: tractanda_uid(), operationID: UUID.makeVersion1().uuidString.lowercased(),
            canonicalFormatSupport: support)
        storeID = try CanonicalReaderRequirement.storeIdentity(
            root: sourceRoot, ownerUID: tractanda_uid())
        try capacity()
    }
    func capacity() throws {
        try AttachmentFixtureCapacity.requireFree(at: directory)
        var bytes: UInt64 = 0
        let all = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)!
        for case let url as URL in all {
            let metadata = try FileMetadata.read(at: url)
            if metadata.type == .regular {
                guard
                    metadata.size <= AttachmentFixtureCapacity.fixtureCapBytes
                        - min(bytes, AttachmentFixtureCapacity.fixtureCapBytes)
                else { throw TractandaError("resourceLimit", "Atomic native fixture cap") }
                bytes += metadata.size
            }
        }
    }
    deinit {
        source = nil
        if let all = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let url as URL in all {
                if let metadata = try? FileMetadata.read(at: url), metadata.type == .regular {
                    _ = chmod(url.path, 0o600)
                }
            }
        }
        try? FileManager.default.removeItem(at: directory)
    }
    static func transition(_ root: URL) throws {
        let writer = tractanda_lock(root.appendingPathComponent(".writer.lock").path)
        guard writer >= 0 else { throw TractandaError("fixture", "Store did not release its real writer") }
        defer { tractanda_unlock(writer) }
        let prior = try XCTUnwrap(CanonicalReaderRequirement.load(root: root, ownerUID: tractanda_uid()))
        _ = try CanonicalReaderRequirement.transitionToAtomicAuthority(
            root: root, ownerUID: tractanda_uid(), writerDescriptor: writer,
            expectedRequirement: prior,
            expectedRequirementSHA256: AuthorityRecordCodec.sha256(
                Data(contentsOf: root.appendingPathComponent(CanonicalReaderRequirement.fileName))),
            support: AtomicAuthorityCompatibility.support)
    }
    static func open(_ root: URL, accounts: any AccountDirectory) throws -> ItemStore {
        try ItemStore(
            root: root, accounts: accounts, revisionProjectionEnabled: true,
            authorityIntakeEnabled: true, firstSourceOperation: nil,
            canonicalFormatSupport: AtomicAuthorityCompatibility.support)
    }
    func activateAndOpen() throws {
        source = nil
        try Self.transition(sourceRoot)
        source = try Self.open(sourceRoot, accounts: sourceAccounts)
    }
}
