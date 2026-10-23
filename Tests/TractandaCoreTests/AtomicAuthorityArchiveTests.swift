import CTractandaPlatform
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class AtomicAuthorityArchiveTests: XCTestCase {
    private typealias Archive = AtomicAuthorityArchive
    private typealias Format = AtomicAuthorityFormat
    private func id(_ n: Int) -> String { String(format: "%08x-0000-1000-8000-000000000001", n) }
    private func binding(_ n: Int) -> AuthorityBinding {
        try! .init(recordID: id(n), sha256: String(repeating: "a", count: 64))
    }
    private func context(previous: AuthorityBinding? = nil, input: String = String(repeating: "b", count: 64))
        throws -> Archive.Context
    {
        try .init(
            rootID: id(1), storeID: id(2), origin: id(3), actor: "rcfa",
            createdAt: "2026-10-23T10:00:00.000Z", inputIdentity: input, previous: previous)
    }
    private func effect(_ n: Int = 0, large: Bool = false) -> ItemValue {
        AuthorityStore.DispositionDelta(
            target: try! .init(
                itemID: id(10 + n), revisionID: id(100 + n), sha256: String(repeating: "f", count: 64)),
            eligible: false, actor: large ? String(repeating: "\\", count: 256) : "user:rcfa",
            policyIDs: large ? (0..<256).map { id(2000 + $0) } : [],
            causes: large ? (0..<256).map { binding(3000 + $0) } : [], evidence: binding(4000)
        ).itemValue
    }
    private final class Fixture {
        let directory: URL
        let root: URL
        init() throws {
            try AttachmentFixtureCapacity.requireFree()
            directory = try GuardedFixtureDirectory.create(
                prefix: "atomic-archive-", source: #filePath, test: #function)
            root = directory.appendingPathComponent("archive")
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        func archive(
            chunk: Int = Format.maximumChunkBytes, maximum: UInt64 = 24 * 1024 * 1024,
            progress: (() throws -> Void)? = nil
        ) throws -> Archive {
            try .init(
                root: root, limits: .init(maximumStoredBytes: maximum, maximumParts: 4096), chunkBytes: chunk,
                progress: progress)
        }
        func remove(file: StaticString = #filePath, line: UInt = #line) {
            if let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) {
                for case let url as URL in entries {
                    var s = stat()
                    if lstat(url.path, &s) == 0, s.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) {
                        _ = chmod(url.path, 0o600)
                    }
                }
            }
            XCTAssertNoThrow(try FileManager.default.removeItem(at: directory), file: file, line: line)
        }
    }
    private func build(
        _ archive: Archive, _ context: Archive.Context, _ value: ItemValue,
        parents: [ItemValue] = []
    ) throws -> Archive.Handle {
        var p = parents.makeIterator()
        var emitted = false
        return try archive.build(
            context: context, parents: { p.next() },
            effects: {
                guard !emitted else { return nil }
                emitted = true
                return value
            })
    }
    private func root(_ f: Fixture) throws -> Format.Record {
        try Format.Codec.decode(Data(contentsOf: f.root.appendingPathComponent("root")))
    }
    private func replace(_ value: ItemValue, _ key: String, _ replacement: ItemValue) -> ItemValue {
        var p = value.map!
        p[key] = replacement
        return .object(p)
    }
    private func write(_ data: Data, _ url: URL) throws {
        XCTAssertEqual(chmod(url.path, 0o600), 0)
        try data.write(to: url)
        XCTAssertEqual(chmod(url.path, 0o400), 0)
    }
    private func rootHandle(_ f: Fixture, _ value: ItemValue) throws -> Archive.Handle {
        let record = try Format.Record(value: value)
        let data = try Format.Codec.encode(record)
        try write(data, f.root.appendingPathComponent("root"))
        return .init(
            binding: try .init(recordID: record.recordID, sha256: AuthorityRecordCodec.sha256(data)),
            encodedBytes: data.count)
    }
    private func rootWith(_ original: Format.Record, stream: Format.Stream, reference: Format.Reference)
        -> ItemValue
    {
        let changed = replace(stream.itemValue, "root", .list([reference.itemValue]))
        return replace(original.itemValue, "payload", replace(.object(original.payload), "effects", changed))
    }

    func testUnreceivedDeclaredPartResumesExactParserPrefixWithoutRehydration() throws {
        let f = try Fixture()
        defer { f.remove() }
        let source = try f.archive(chunk: 97)
        let handle = try build(source, context(), effect())
        let bytes = try Data(contentsOf: f.root.appendingPathComponent("root"))
        let destination = f.directory.appendingPathComponent("incoming")
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        var reads: [String: Int] = [:]
        var available = false
        var blocked: AuthorityBinding?
        let incoming = try Archive(
            root: destination,
            limits: .init(maximumStoredBytes: 4 * 1024 * 1024, maximumParts: 4096),
            canonicalPartLoader: { binding, _ in
                if blocked == nil && reads.count == 1 { blocked = binding }
                if !available && blocked == binding {
                    throw Archive.PartUnavailable(binding: binding)
                }
                reads[binding.recordID, default: 0] += 1
                return try Data(contentsOf: f.root.appendingPathComponent("parts/" + binding.recordID))
            }, canonicalRootLoader: { bytes })
        let bound = try incoming.bindCanonicalRoot(bytes)
        XCTAssertEqual(bound, handle)
        let reader = try incoming.beginValidation(bound)
        defer { try? reader.close() }
        let window = Archive.Window(maximumParts: 1, maximumBytes: Format.maximumEnvelopeBytes)
        var facts = 0
        XCTAssertNil(try reader.stageAvailableWindow(window: window) { _ in facts += 1 })
        let prefixReads = reads
        XCTAssertNil(try reader.stageAvailableWindow(window: window) { _ in facts += 1 })
        XCTAssertNotNil(reader.waitingForPart)
        XCTAssertEqual(reads, prefixReads)
        XCTAssertNil(try reader.stageAvailableWindow(window: window) { _ in facts += 1 })
        XCTAssertEqual(reads, prefixReads, "A missing suffix cannot restart a verified prefix")
        available = true
        var result: Archive.Structure?
        while result == nil {
            result = try reader.stageAvailableWindow(window: window) { _ in facts += 1 }
        }
        XCTAssertNil(reader.waitingForPart)
        XCTAssertEqual(facts, 1)
        XCTAssertEqual(Int64(reads.count), result?.parts)
        XCTAssertTrue(reads.values.allSatisfy { $0 == 1 })
    }

    func testUnavailableSignalDoesNotHideWrongReferenceOrStrictClosureFailure() throws {
        let f = try Fixture()
        defer { f.remove() }
        let source = try f.archive(chunk: 97)
        _ = try build(source, context(), effect())
        let bytes = try Data(contentsOf: f.root.appendingPathComponent("root"))
        let destination = f.directory.appendingPathComponent("incoming")
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        var wrong = true
        let incoming = try Archive(
            root: destination,
            limits: .init(maximumStoredBytes: 4 * 1024 * 1024, maximumParts: 4096),
            canonicalPartLoader: { binding, _ in
                throw Archive.PartUnavailable(binding: wrong ? self.binding(9999) : binding)
            }, canonicalRootLoader: { bytes })
        let handle = try incoming.bindCanonicalRoot(bytes)
        var reader = try incoming.beginValidation(handle)
        XCTAssertThrowsError(try reader.stageAvailableWindow(window: .init()) { _ in })
        try reader.close()
        wrong = false
        reader = try incoming.beginValidation(handle)
        XCTAssertThrowsError(try reader.step(window: .init()))
        try reader.close()
    }

    func testDiskStreaming129LeavesAndBoundedValidationWindows() throws {
        let f = try Fixture()
        defer { f.remove() }
        let a = try f.archive(chunk: 983)
        let value = effect(large: true)
        let handle = try build(a, context(), value)
        let reader = try a.beginValidation(handle)
        defer { try? reader.close() }
        var result: Archive.Structure?
        while result == nil {
            result = try reader.step(
                window: .init(maximumParts: 1, maximumBytes: Format.maximumEnvelopeBytes))
        }
        XCTAssertEqual(result?.parts, 133)
        XCTAssertEqual(result?.supportFacts, 1)
        XCTAssertEqual(result?.targets, 1)
        XCTAssertGreaterThan(reader.steps, 129)
        try reader.close()
        var actual: [ItemValue] = []
        try a.forEachEntry(handle, section: .effects) { actual.append($0) }
        XCTAssertEqual(actual, [value])
        print(
            "ATOMIC_ARCHIVE_129 parts=\(result!.parts) bytes=\(result!.encodedPartBytes) windows=\(reader.steps)"
        )
    }
    func testExactRetryRetainsRootTimeIDsAndImmutableBytes() throws {
        let f = try Fixture()
        defer { f.remove() }
        let a = try f.archive()
        let c = try context(previous: binding(50))
        let handle = try build(a, c, effect(), parents: [binding(50).itemValue])
        let before = try FileMetadata.read(at: f.root.appendingPathComponent("root"))
        let retried = try build(a, c, effect(), parents: [binding(50).itemValue])
        XCTAssertEqual(handle, retried)
        XCTAssertEqual(try FileMetadata.read(at: f.root.appendingPathComponent("root")), before)
        XCTAssertEqual(try a.validate(handle).parentEntries, 1)
        XCTAssertThrowsError(
            try build(
                a, context(previous: binding(50), input: String(repeating: "c", count: 64)), effect(),
                parents: [binding(50).itemValue]))
        XCTAssertThrowsError(try build(a, c, effect(1), parents: [binding(50).itemValue]))
        XCTAssertNoThrow(try a.validate(handle), "Failed retry never replaces a completed root")
        XCTAssertEqual(try root(f).itemValue.map?["createdAt"], .date(c.createdAt))
    }
    func testInterruptedConstructionResumesSameReservedMaterial() throws {
        let f = try Fixture()
        defer { f.remove() }
        var boundaries = 0
        let interrupted = try f.archive(
            chunk: 1024,
            progress: {
                boundaries += 1
                if boundaries == 6 { throw CancellationError() }
            })
        let c = try context()
        let value = effect(large: true)
        XCTAssertThrowsError(try build(interrupted, c, value)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("root").path))
        let parts = f.root.appendingPathComponent("parts")
        let retained = try FileManager.default.contentsOfDirectory(at: parts, includingPropertiesForKeys: nil)
        XCTAssertFalse(retained.isEmpty)
        let old = try retained.map { ($0, try Data(contentsOf: $0)) }
        let resumed = try f.archive(chunk: 1024)
        let handle = try build(resumed, c, value)
        for (path, bytes) in old { XCTAssertEqual(try Data(contentsOf: path), bytes) }
        XCTAssertEqual(try resumed.validate(handle).supportFacts, 1)
        XCTAssertEqual(try root(f).recordID, c.rootID)
    }
    func testMissingOrTamperedFinalPartHasNoConsumerCallback() throws {
        for missing in [true, false] {
            let f = try Fixture()
            defer { f.remove() }
            let a = try f.archive(chunk: 4096)
            let handle = try build(a, context(), effect(large: true))
            let files = try FileManager.default.contentsOfDirectory(
                at: f.root.appendingPathComponent("parts"), includingPropertiesForKeys: nil)
            let victim = try XCTUnwrap(files.sorted { $0.path < $1.path }.last)
            if missing {
                try FileManager.default.removeItem(at: victim)
            } else {
                var data = try Data(contentsOf: victim)
                data[data.count - 2] ^= 1
                try write(data, victim)
            }
            var callbacks = 0
            XCTAssertThrowsError(try a.forEachEntry(handle, section: .effects) { _ in callbacks += 1 })
            XCTAssertEqual(callbacks, 0, "Complete closure validation must precede consumer facts")
        }
    }
    func testReboundHashStillCannotChangeRootIssuerOrSection() throws {
        for field in ["controlID", "originReplicaID", "section"] {
            let f = try Fixture()
            defer { f.remove() }
            let a = try f.archive()
            _ = try build(a, context(), effect())
            let r = try root(f)
            let stream = try Format.Stream(value: r.payload["effects"]!, section: .effects)
            let old = try XCTUnwrap(stream.root)
            let path = f.root.appendingPathComponent("parts/" + old.binding.recordID)
            let part = try Format.Codec.decode(Data(contentsOf: path))
            let changed: ItemValue
            if field == "section" {
                changed = replace(
                    part.itemValue, "payload", replace(.object(part.payload), field, .text("parents")))
            } else {
                changed = replace(part.itemValue, field, .text(id(99)))
            }
            let modified = try Format.Record(value: changed)
            let bytes = try Format.Codec.encode(modified)
            try write(bytes, path)
            let reference = try modified.reference()
            let newHandle = try rootHandle(f, rootWith(r, stream: stream, reference: reference))
            var callbacks = 0
            XCTAssertThrowsError(try a.forEachEntry(newHandle, section: .effects) { _ in callbacks += 1 })
            XCTAssertEqual(callbacks, 0)
        }
    }
    func testAggregateCountsAndMissingPreviousAreCheckedBeyondCodec() throws {
        for missingPrevious in [false, true] {
            let f = try Fixture()
            defer { f.remove() }
            let a = try f.archive()
            _ = try build(a, context(previous: binding(50)), effect(), parents: [binding(50).itemValue])
            let r = try root(f)
            var payload = r.payload
            if missingPrevious {
                payload["previous"] = .list([binding(51).itemValue])
            } else {
                payload["partCount"] = .integer(payload["partCount"]!.integerValue! + 1)
            }
            let newHandle = try rootHandle(f, replace(r.itemValue, "payload", .object(payload)))
            XCTAssertThrowsError(try a.validate(newHandle))
        }
    }
    func testPrivateCustodyRejectsHardlinksSymlinksAndMutableMode() throws {
        for attack in ["hardlink", "symlink", "mode"] {
            let f = try Fixture()
            defer { f.remove() }
            let a = try f.archive()
            let handle = try build(a, context(), effect())
            let r = try root(f)
            let stream = try Format.Stream(value: r.payload["effects"]!, section: .effects)
            let victim = f.root.appendingPathComponent("parts/" + stream.root!.binding.recordID)
            let external = f.directory.appendingPathComponent("external")
            if attack == "hardlink" {
                XCTAssertEqual(link(victim.path, external.path), 0)
            } else if attack == "symlink" {
                try Data(contentsOf: victim).write(to: external)
                try FileManager.default.removeItem(at: victim)
                XCTAssertEqual(symlink(external.path, victim.path), 0)
            } else {
                XCTAssertEqual(chmod(victim.path, 0o600), 0)
            }
            XCTAssertThrowsError(try a.validate(handle))
        }
    }
    func testGlobalLeafAliasAndForgedCycleNeverComplete() throws {
        for cycle in [false, true] {
            let f = try Fixture()
            defer { f.remove() }
            let a = try f.archive(chunk: 983)
            _ = try build(a, context(), effect(large: true))
            let r = try root(f)
            let stream = try Format.Stream(value: r.payload["effects"]!, section: .effects)
            let topReference = try XCTUnwrap(stream.root)
            let topPath = f.root.appendingPathComponent("parts/" + topReference.binding.recordID)
            let top = try Format.Codec.decode(Data(contentsOf: topPath))
            var children = top.payload["children"]!.array!
            let changedTop: ItemValue
            if cycle {
                let ref = try Format.Reference(value: children[0])
                children[0] = replace(
                    ref.itemValue, "binding",
                    bindingValue(id: top.recordID, sha: String(repeating: "b", count: 64)))
                changedTop = replace(
                    top.itemValue, "payload", replace(.object(top.payload), "children", .list(children)))
            } else {
                let first = try Format.Reference(value: children[0])
                let second = try Format.Reference(value: children[1])
                let firstPart = try Format.Codec.decode(
                    Data(contentsOf: f.root.appendingPathComponent("parts/" + first.binding.recordID)))
                let secondPath = f.root.appendingPathComponent("parts/" + second.binding.recordID)
                let secondPart = try Format.Codec.decode(Data(contentsOf: secondPath))
                var secondChildren = secondPart.payload["children"]!.array!
                let firstLeaf = try Format.Reference(value: firstPart.payload["children"]!.array![0])
                // Keep byte/leaf ranges locally valid but alias an ID from another branch.
                secondChildren[0] = replace(secondChildren[0], "binding", firstLeaf.binding.itemValue)
                let newSecond = try Format.Record(
                    value: replace(
                        secondPart.itemValue, "payload",
                        replace(.object(secondPart.payload), "children", .list(secondChildren))))
                try write(Format.Codec.encode(newSecond), secondPath)
                children[1] = try newSecond.reference().itemValue
                changedTop = replace(
                    top.itemValue, "payload", replace(.object(top.payload), "children", .list(children)))
            }
            // Intentionally encode a malicious canonical JSON body without the typed factory;
            // the reader must reject the forged cycle rather than recurse or report completion.
            let oldBytes = try Data(contentsOf: topPath)
            let split = try XCTUnwrap(oldBytes.range(of: Data("\r\n\r\n".utf8)))
            var newBytes = Data(oldBytes[..<split.upperBound])
            newBytes.append(try JSON.encode(changedTop))
            newBytes.append(10)
            try write(newBytes, topPath)
            let rebound = try Format.Reference(
                value: replace(
                    replace(
                        topReference.itemValue, "binding",
                        bindingValue(id: top.recordID, sha: AuthorityRecordCodec.sha256(newBytes))),
                    "encodedBytes", .integer(Int64(newBytes.count))))
            let handle = try rootHandle(f, rootWith(r, stream: stream, reference: rebound))
            var callbacks = 0
            XCTAssertThrowsError(try a.forEachEntry(handle, section: .effects) { _ in callbacks += 1 }) {
                error in
                if !cycle {
                    XCTAssertTrue(String(describing: error).contains("Duplicated/cyclic atomic part"))
                }
            }
            XCTAssertEqual(callbacks, 0)
        }
    }
    private func bindingValue(id: String, sha: String) -> ItemValue {
        try! AuthorityBinding(recordID: id, sha256: sha).itemValue
    }
    func testLeaseReplacementFailsBeforeFurtherValidation() throws {
        let f = try Fixture()
        defer { f.remove() }
        let a = try f.archive(chunk: 512)
        let handle = try build(a, context(), effect())
        let reader = try a.beginValidation(handle)
        _ = try reader.step(window: .init(maximumParts: 1, maximumBytes: Format.maximumEnvelopeBytes))
        let path = f.root.appendingPathComponent(".archive.lock")
        try FileManager.default.moveItem(at: path, to: f.directory.appendingPathComponent("held-old-lock"))
        try Data().write(to: path)
        XCTAssertEqual(chmod(path.path, 0o600), 0)
        XCTAssertThrowsError(try reader.step(window: .init()))
        XCTAssertThrowsError(try reader.close(), "Changed lease cannot acknowledge scratch cleanup")
        XCTAssertNoThrow(try a.validate(handle), "Next valid lease reclaims only abandoned private markers")
    }
    func testFreshLeaseRefreshesStaleQuotaAndSerializesMarkerWriters() throws {
        let f = try Fixture()
        defer { f.remove() }
        let first = try f.archive(chunk: 4096)
        let staleSmall = try f.archive(chunk: 4096, maximum: 64 * 1024)
        let second = try f.archive(chunk: 4096)
        let c = try context()
        let value = effect(large: true)
        let handle = try build(first, c, value)
        XCTAssertThrowsError(try build(staleSmall, c, value)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
        }
        let reader = try first.beginValidation(handle)
        XCTAssertThrowsError(
            try second.beginValidation(handle), "Validation writes scratch and requires exclusive lease")
        try reader.close()
        XCTAssertNoThrow(try second.validate(handle))
    }
    func testAbandonmentAndRecognizedStartupScratchCleanupPreserveRoot() throws {
        let f = try Fixture()
        defer { f.remove() }
        let a = try f.archive(chunk: 512)
        let handle = try build(a, context(), effect())
        let original = try Data(contentsOf: f.root.appendingPathComponent("root"))
        var reader: Archive.Reader? = try a.beginValidation(handle)
        _ = try reader?.step(window: .init(maximumParts: 1, maximumBytes: Format.maximumEnvelopeBytes))
        reader = nil
        let work = f.root.appendingPathComponent("read-work")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: work.path).isEmpty)
        let abandoned = work.appendingPathComponent(id(7777))
        try FileManager.default.createDirectory(
            at: abandoned, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let marker = abandoned.appendingPathComponent(id(7778))
        try Data([1]).write(to: marker)
        XCTAssertEqual(chmod(marker.path, 0o400), 0)
        XCTAssertNoThrow(try a.validate(handle))
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("root")), original)
        let unknown = work.appendingPathComponent(id(7779))
        try FileManager.default.createDirectory(
            at: unknown, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let retained = unknown.appendingPathComponent("not-a-marker")
        try Data("KEEP".utf8).write(to: retained)
        XCTAssertEqual(chmod(retained.path, 0o400), 0)
        XCTAssertThrowsError(try a.validate(handle))
        XCTAssertEqual(
            try Data(contentsOf: retained), Data("KEEP".utf8), "Cleanup must not delete unknown data")
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("root")), original)
    }
    private func publicationDescriptors(_ archive: Archive, _ handle: Archive.Handle) throws -> [PeerPackage
        .Object]
    {
        var objects: [PeerPackage.Object] = []
        var bytes = 0
        try archive.forEachUntrustedLocalObject(handle) { object, data in
            bytes += data.count
            guard objects.count < 64, bytes < 1024 * 1024 else {
                throw TractandaError("resourceLimit", "Tiny publication reader fixture bound")
            }
            objects.append(object)
        }
        return objects
    }
    func testScopedPublicationReaderUsesTwoCensusesForOneOrManyObjects() throws {
        let f = try Fixture()
        defer { f.remove() }
        let a = try f.archive(chunk: 97)
        let handle = try build(a, context(), effect())
        let objects = try publicationDescriptors(a, handle)
        XCTAssertGreaterThan(objects.count, 3)
        for count in [1, objects.count] {
            let before = a.inventoryRecountsForTesting
            try a.withUntrustedLocalObjectReader(handle) { reader in
                for expected in objects.prefix(count) {
                    let bytes = try reader.object(expected: expected)
                    XCTAssertEqual(bytes.count, expected.length)
                    XCTAssertEqual(AuthorityRecordCodec.sha256(bytes), expected.sha256)
                }
            }
            XCTAssertEqual(
                a.inventoryRecountsForTesting - before, 2,
                "Full inventories must be constant per scope, never per object")
        }
    }
    func testScopedReaderRejectsAlteredLaterPartOrDescriptorAndCannotIgnoreFailure() throws {
        for alterBody in [false, true] {
            let f = try Fixture()
            defer { f.remove() }
            let a = try f.archive(chunk: 97)
            let handle = try build(a, context(), effect())
            let objects = try publicationDescriptors(a, handle)
            let leaves = try objects.filter { object in
                guard object.id != handle.binding.recordID else { return false }
                return try Format.Codec.decode(
                    Data(contentsOf: f.root.appendingPathComponent("parts/" + object.id))
                ).kind == .atomicControlPart
            }
            let first = try XCTUnwrap(leaves.first)
            let later = try XCTUnwrap(leaves.dropFirst().first)
            XCTAssertThrowsError(
                try a.withUntrustedLocalObjectReader(handle) { reader in
                    _ = try reader.object(expected: first)
                    let expected: PeerPackage.Object
                    if alterBody {
                        let path = f.root.appendingPathComponent("parts/" + later.id)
                        let record = try Format.Codec.decode(Data(contentsOf: path))
                        guard case .bytes(let originalChunk)? = record.payload["bytes"] else {
                            throw TractandaError("fixture", "Expected a real local leaf chunk")
                        }
                        var chunk = originalChunk
                        chunk[0] ^= 1
                        let changed = try Format.Record(
                            value: replace(
                                record.itemValue, "payload",
                                replace(.object(record.payload), "bytes", .bytes(chunk))))
                        try write(Format.Codec.encode(changed), path)
                        expected = later
                    } else {
                        expected = .init(
                            kind: later.kind, id: later.id, length: later.length + 1, sha256: later.sha256)
                    }
                    XCTAssertThrowsError(try reader.object(expected: expected))
                    XCTAssertThrowsError(
                        try reader.object(expected: first), "A failed read poisons the scope")
                })
        }
    }
    func testScopedReaderDetectsRootLeaseAndDirectoryReplacementAfterCallback() throws {
        for replacement in ["root", "lease", "directory"] {
            let f = try Fixture()
            defer { f.remove() }
            let a = try f.archive(chunk: 512)
            let handle = try build(a, context(), effect())
            let objects = try publicationDescriptors(a, handle)
            XCTAssertThrowsError(
                try a.withUntrustedLocalObjectReader(handle) { reader in
                    _ = try reader.object(expected: XCTUnwrap(objects.first))
                    switch replacement {
                    case "root":
                        let old = try root(f)
                        let changed = try Format.Record(
                            value: replace(old.itemValue, "actorPrincipal", .text("changed")))
                        try write(Format.Codec.encode(changed), f.root.appendingPathComponent("root"))
                    case "lease":
                        let path = f.root.appendingPathComponent(".archive.lock")
                        try FileManager.default.moveItem(
                            at: path, to: f.directory.appendingPathComponent("held-old-lock"))
                        try Data().write(to: path)
                        XCTAssertEqual(chmod(path.path, 0o600), 0)
                    default:
                        try FileManager.default.moveItem(
                            at: f.root, to: f.directory.appendingPathComponent("held-old-root"))
                        try FileManager.default.createDirectory(
                            at: f.root, withIntermediateDirectories: false,
                            attributes: [.posixPermissions: 0o700])
                    }
                    // No further read: scope completion itself must recheck the callback boundary.
                })
        }
    }
    func testThrowingScopePreservesPrimaryErrorClosesEscapedReaderAndReleasesLease() throws {
        let f = try Fixture()
        defer { f.remove() }
        let a = try f.archive(chunk: 512)
        let handle = try build(a, context(), effect())
        let expected = try XCTUnwrap(publicationDescriptors(a, handle).first)
        let interrupted = TractandaError("fixtureInterrupted", "Keep the original callback error")
        var escaped: Archive.UntrustedLocalObjectReader?
        XCTAssertThrowsError(
            try a.withUntrustedLocalObjectReader(handle) { reader -> Void in
                escaped = reader
                _ = try reader.object(expected: expected)
                throw interrupted
            }
        ) { XCTAssertEqual($0 as? TractandaError, interrupted) }
        XCTAssertThrowsError(try XCTUnwrap(escaped).object(expected: expected))
        XCTAssertNoThrow(
            try a.withUntrustedLocalObjectReader(handle) { reader in
                _ = try reader.object(expected: expected)
            })
        let work = f.root.appendingPathComponent("read-work")
        if FileManager.default.fileExists(atPath: work.path) {
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: work.path).isEmpty)
        }
    }
    func testFinalCensusRejectsUnknownFileGrowthWithoutDeletingUnknownData() throws {
        let f = try Fixture()
        defer { f.remove() }
        let maximum: UInt64 = 1024 * 1024
        let a = try f.archive(chunk: 512, maximum: maximum)
        let handle = try build(a, context(), effect())
        let expected = try XCTUnwrap(publicationDescriptors(a, handle).first)
        let original = try Data(contentsOf: f.root.appendingPathComponent("root"))
        let unknown = f.root.appendingPathComponent("caller-unknown")
        XCTAssertThrowsError(
            try a.withUntrustedLocalObjectReader(handle) { reader in
                _ = try reader.object(expected: expected)
                // Sparse tiny fixture growth tests actual inventory accounting without filling disk.
                XCTAssertTrue(
                    FileManager.default.createFile(
                        atPath: unknown.path, contents: Data(), attributes: [.posixPermissions: 0o600]))
                let file = try FileHandle(forWritingTo: unknown)
                try file.truncate(atOffset: maximum)
                try file.close()
                XCTAssertEqual(chmod(unknown.path, 0o400), 0)
            }
        ) { XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit") }
        XCTAssertEqual(try FileMetadata.read(at: unknown).size, maximum)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("root")), original)
    }
    func testScopedReaderRejectsReentrantProgressReadEvenIfCallbackCatchesIt() throws {
        let f = try Fixture()
        defer { f.remove() }
        var captured: Archive.UntrustedLocalObjectReader?
        var expected: PeerPackage.Object?
        var attempted = false
        let a = try f.archive(progress: {
            if let captured, let expected, !attempted {
                attempted = true
                XCTAssertThrowsError(try captured.object(expected: expected))
            }
        })
        let handle = try build(a, context(), effect())
        expected = try XCTUnwrap(publicationDescriptors(a, handle).first)
        XCTAssertThrowsError(
            try a.withUntrustedLocalObjectReader(handle) { reader in
                captured = reader
                _ = try reader.object(expected: XCTUnwrap(expected))
            })
        XCTAssertTrue(attempted)
    }
    func testActualTaskCancellationReleasesScopedReaderLeaseBeforeCallback() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let a = try f.archive(chunk: 512)
        let handle = try build(a, context(), effect())
        let descriptor = PeerPackage.Object(
            kind: .authority, id: handle.binding.recordID,
            length: handle.encodedBytes, sha256: handle.binding.sha256)
        let root = f.root
        let task = Task {
            let archive = try Archive(
                root: root, limits: .init(maximumStoredBytes: 24 * 1024 * 1024, maximumParts: 4096))
            let handle = Archive.Handle(
                binding: try .init(recordID: descriptor.id, sha256: descriptor.sha256),
                encodedBytes: descriptor.length)
            withUnsafeCurrentTask { $0?.cancel() }
            var entered = false
            do {
                try archive.withUntrustedLocalObjectReader(handle) { reader in
                    entered = true
                    _ = try reader.object(expected: descriptor)
                }
                return false
            } catch is CancellationError {
                return !entered
            }
        }
        let cancelled = try await task.value
        XCTAssertTrue(cancelled)
        XCTAssertNoThrow(
            try a.withUntrustedLocalObjectReader(handle) { reader in
                _ = try reader.object(expected: descriptor)
            })
    }
    func testCapacityAndCancellationLeaveNoRootAndNoRuntimeChanges() throws {
        let f = try Fixture()
        defer { f.remove() }
        XCTAssertThrowsError(
            try Archive(
                root: f.root, limits: .init(maximumStoredBytes: 1024 * 1024, maximumParts: 100),
                availableBytes: { 0 }))
        let tiny = try f.archive(maximum: 4096)
        XCTAssertThrowsError(try build(tiny, context(), effect()))
        let cancelled = try f.archive(progress: { throw CancellationError() })
        XCTAssertThrowsError(try build(cancelled, context(), effect())) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("root").path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: f.root.appendingPathComponent(CanonicalReaderRequirement.fileName).path),
            "Failed private staging must not publish a canonical reader marker.")
    }
}
