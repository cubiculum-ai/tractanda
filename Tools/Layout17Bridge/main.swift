import Foundation
import TractandaCore
import TractandaClient
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Standalone .17 upgrade tool. It is not linked into the daemon.
@_silgen_name("layout17_move_file")
private func moveFile(_ a: Int32, _ name: UnsafePointer<CChar>, _ b: Int32,
                      _ target: UnsafePointer<CChar>, _ owner: uid_t, _ device: UInt64,
                      _ inode: UInt64, _ fault: Int32) -> Int32
@_silgen_name("layout17_move_directory")
private func moveDirectory(_ a: Int32, _ name: UnsafePointer<CChar>, _ b: Int32,
                           _ target: UnsafePointer<CChar>, _ owner: uid_t, _ device: UInt64,
                           _ inode: UInt64, _ fault: Int32) -> Int32
@_silgen_name("layout17_rename_exclusive")
private func renameExclusive(_ a: Int32, _ name: UnsafePointer<CChar>, _ b: Int32,
                             _ target: UnsafePointer<CChar>) -> Int32
@_silgen_name("layout17_durable_sync")
private func durableSync(_ fd: Int32) -> Int32

private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}
private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw Failure(message) }
}
private func systemError(_ operation: String) -> Failure {
    Failure("\(operation): \(String(cString: strerror(errno)))")
}
private let pendingName = "canonical-layout.pending.json"
private let completeName = "canonical-layout.json"
private let pendingBytes = Data("{\"profile\":\"tractanda.physical-layout.pending.v1\"}".utf8)
private let capability = "tractanda.physical-layout.flat-items.v1"
private let messageCapability = "tractanda.message-items.v1"
private func boundary(_ name: String) {
#if LAYOUT17_PRIVATE_FIXTURE
    if ProcessInfo.processInfo.environment["LAYOUT17_TEST_FAULT"] == name { _exit(90) }
#endif
}
private func spaceFault(_ name: String) throws {
#if LAYOUT17_PRIVATE_FIXTURE
    if ProcessInfo.processInfo.environment["LAYOUT17_TEST_ENOSPC"] == name {
        errno = ENOSPC
        throw systemError("Injected write failure")
    }
#endif
}
private let encoder: JSONEncoder = {
    let value = JSONEncoder(); value.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return value
}()

private struct Marker: Encodable {
    let profile = "tractanda.physical-layout.v1"
    let layout = "flat-items-visible-attachments.v1"
    let recordEncoding = "message-v1"
}
private struct Move: Codable {
    let kind: String
    let source: [String]
    let destination: [String]
    let contentSHA256: String
    let byteCount: UInt64
    var newContentSHA256: String? = nil
    var newByteCount: UInt64? = nil
    var originalMode: UInt32? = nil
    var originalGID: UInt32? = nil
}
private struct WorkItem: Codable {
    let kind: String
    var revision: Move? = nil
    var stage: PersonalStageTransition? = nil
    var directory: [String]? = nil
}
private struct Journal: Codable {
    let profile: String
    let storeID: String
    let replicaID: String
    let originalPersonalProfileSHA256: String
    let originalRequirement: Requirement
    let originalRequirementSHA256: String
    var phase: String
    var move: Move?
    var completedDigest: String?
    var stageMove: PersonalStageTransition? = nil
    var reviewMove: PersonalReviewTransition? = nil
}
private struct Requirement: Codable, Equatable {
    let profile: String
    let storeID: String
    var minimumReaderLevel: Int
    let recordFormats: [Int]
    var capabilities: [String]
}
private struct MaintenanceIntent: Decodable {
    let profile: String
    let mode: String
    let instance: String
    let storePath: String
    let storeID: String
    let replicaID: String
    let oldManifestSHA256: String
    let newManifestSHA256: String
    let membershipDigest: String
    let readerRequirementSHA256: String
    let acknowledgedAllMembersUpgradedBeforeStart: Bool
}
private struct CandidateManifest: Decodable {
    struct File: Decodable { let path: String; let sha256: String; let size: UInt64; let mode: UInt16 }
    let profile: String
    let version: String
    let platform: String
    let arch: String
    let files: [File]
}

private func metadata(_ fd: Int32, _ name: String) throws -> stat? {
    var value = stat()
    if fstatat(fd, name, &value, AT_SYMLINK_NOFOLLOW) == 0 { return value }
    if errno == ENOENT { return nil }
    throw systemError("Inspect \(name)")
}
private func sameTimes(_ a: stat, _ b: stat) -> Bool {
#if canImport(Darwin)
    return a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
#else
    return a.st_mtim.tv_sec == b.st_mtim.tv_sec && a.st_mtim.tv_nsec == b.st_mtim.tv_nsec &&
        a.st_ctim.tv_sec == b.st_ctim.tv_sec && a.st_ctim.tv_nsec == b.st_ctim.tv_nsec
#endif
}
private func fileBytes(_ dir: Int32, _ name: String, owner: uid_t, max: Int = 65536) throws -> Data {
    let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw systemError("Open \(name)") }
    defer { close(fd) }
    var value = stat()
    guard fstat(fd, &value) == 0 else { throw systemError("Stat \(name)") }
    try check((value.st_mode & S_IFMT) == S_IFREG && value.st_uid == owner &&
              value.st_nlink == 1 && value.st_mode & 0o7777 == 0o600 &&
              value.st_size > 0 && value.st_size <= max, "Unsafe metadata file \(name)")
    var data = Data(count: Int(value.st_size))
    try data.withUnsafeMutableBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let n = read(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw systemError("Read \(name)") }
            offset += n
        }
    }
    return data
}
private func atomicWrite(_ dir: Int32, _ name: String, _ data: Data, owner: uid_t,
                         replacing: Bool) throws {
    if let existing = try metadata(dir, name) {
        try check(replacing && (existing.st_mode & S_IFMT) == S_IFREG && existing.st_uid == owner &&
                  existing.st_nlink == 1 && existing.st_mode & 0o7777 == 0o600,
                  "Unsafe existing metadata \(name)")
    } else if replacing { throw Failure("Missing expected metadata \(name)") }
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let temp = ".layout17-" + digest + ".tmp"
    if try metadata(dir, temp) != nil {
        let retained = try fileBytes(dir, temp, owner: owner, max: max(data.count, 1))
        try check(retained == data, "Unexpected occupied migration temporary file")
        guard unlinkat(dir, temp, 0) == 0, fsync(dir) == 0 else { throw systemError("Clean owned migration temporary") }
    }
    let fd = openat(dir, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw systemError("Create \(temp)") }
    defer { close(fd); _ = unlinkat(dir, temp, 0) }
    try spaceFault("metadata:" + name)
    guard fchmod(fd, 0o600) == 0 else { throw systemError("Set metadata mode") }
    if geteuid() == 0 { guard fchown(fd, owner, gid_t.max) == 0 else { throw systemError("Set metadata owner") } }
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let n = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw systemError("Write \(name)") }
            offset += n
        }
    }
    guard durableSync(fd) == 0 else { throw systemError("Sync \(name)") }
    boundary("metadata-temp:" + name)
    if replacing {
        guard renameat(dir, temp, dir, name) == 0 else { throw systemError("Publish \(name)") }
    } else {
        guard renameExclusive(dir, temp, dir, name) == 0 else { throw systemError("Publish \(name)") }
    }
    guard fsync(dir) == 0 else { throw systemError("Sync metadata directory") }
}

private func directory(_ parent: Int32, _ name: String, owner: uid_t) throws -> Int32 {
    try check(!name.isEmpty && name != "." && name != ".." && !name.contains("/"), "Invalid path component")
    let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw systemError("Open directory \(name)") }
    var s = stat()
    guard fstat(fd, &s) == 0, (s.st_mode & S_IFMT) == S_IFDIR, s.st_uid == owner,
          s.st_mode & 0o077 == 0 else { close(fd); throw Failure("Unsafe directory \(name)") }
    return fd
}
private func entries(_ fd: Int32, _ body: (String) throws -> Void) throws {
    let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard copy >= 0, let stream = fdopendir(copy) else { if copy >= 0 { close(copy) }; throw systemError("Open directory stream") }
    defer { closedir(stream) }
    while true {
        errno = 0
        guard let entry = readdir(stream) else {
            if errno != 0 { throw systemError("Read directory") }
            break
        }
        let parsed = withUnsafePointer(to: &entry.pointee.d_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(validatingCString: $0) }
        }
        guard let name = parsed else { throw Failure("Non-UTF8 directory entry") }
        if name != "." && name != ".." { try body(name) }
    }
}
private func validID(_ name: String) -> Bool {
    guard let value = UUID(uuidString: name), value.uuidString.lowercased() == name,
          name.count == 36 else { return false }
    return true
}
private func validMinute(_ parts: [String]) -> Bool {
    guard parts.count == 5, let year = Int(parts[0]), let month = Int(parts[1]),
          let day = Int(parts[2]), let hour = Int(parts[3]), let minute = Int(parts[4]) else { return false }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    var value = DateComponents(); value.calendar = calendar; value.timeZone = calendar.timeZone
    value.year = year; value.month = month; value.day = day; value.hour = hour; value.minute = minute
    guard let date = calendar.date(from: value) else { return false }
    let roundtrip = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    return roundtrip.year == year && roundtrip.month == month && roundtrip.day == day &&
        roundtrip.hour == hour && roundtrip.minute == minute
}
private func parentDirectory(_ root: Int32, _ path: [String], owner: uid_t) throws -> Int32 {
    let initial = openat(root, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard initial >= 0 else { throw systemError("Duplicate store directory") }
    var current = initial
    do {
        for name in path {
            let next = try directory(current, name, owner: owner)
            close(current); current = next
        }
        return current
    } catch { close(current); throw error }
}
private func hashFile(_ parent: Int32, _ name: String, owner: uid_t) throws -> (String, UInt64, stat) {
    let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw systemError("Open original \(name)") }
    defer { close(fd) }
    var before = stat()
    guard fstat(fd, &before) == 0 else { throw systemError("Stat original") }
    try check((before.st_mode & S_IFMT) == S_IFREG && before.st_uid == owner &&
              before.st_nlink >= 1 && before.st_nlink <= 2 && before.st_size >= 0,
              "Unsafe original file \(name)")
    var hash = SHA256()
    var total: UInt64 = 0
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(fd, &buffer, buffer.count)
        if n < 0 && errno == EINTR { continue }
        guard n >= 0 else { throw systemError("Read original") }
        if n == 0 { break }
        hash.update(data: Data(buffer.prefix(n)))
        total += UInt64(n)
    }
    var after = stat()
    guard fstat(fd, &after) == 0 else { throw systemError("Restat original") }
#if canImport(Darwin)
    let timesMatch = before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec &&
        before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec &&
        before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec &&
        before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
#else
    let timesMatch = before.st_mtim.tv_sec == after.st_mtim.tv_sec &&
        before.st_mtim.tv_nsec == after.st_mtim.tv_nsec &&
        before.st_ctim.tv_sec == after.st_ctim.tv_sec &&
        before.st_ctim.tv_nsec == after.st_ctim.tv_nsec
#endif
    try check(before.st_dev == after.st_dev && before.st_ino == after.st_ino &&
              before.st_size == after.st_size && total == UInt64(before.st_size) && timesMatch,
              "Original changed during hashing")
    let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
    return (digest, total, after)
}
private func readBoundedRecord(_ parent: Int32, _ name: String, owner: uid_t,
                               expectedMode: mode_t?, allowHardlinks: Bool = false) throws -> (Data, stat) {
    let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw systemError("Open revision bytes") }
    defer { close(fd) }
    var before = stat()
    guard fstat(fd, &before) == 0 else { throw systemError("Stat revision bytes") }
    let mode = before.st_mode & 0o7777
    try check((before.st_mode & S_IFMT) == S_IFREG && before.st_uid == owner &&
              (expectedMode.map { mode == $0 } ?? (mode & 0o077 == 0)) &&
              before.st_nlink >= 1 && (allowHardlinks || before.st_nlink == 1) &&
              before.st_size > 0 && before.st_size <= LegacyRecordCodec.maximumRecordBytes,
              "Unsafe or incomplete revision bytes")
    var data = Data(count: Int(before.st_size))
    try data.withUnsafeMutableBytes { raw in
        var offset = 0
        while offset < raw.count {
            let n = read(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw systemError("Read revision bytes") }
            offset += n
        }
    }
    var after = stat()
    guard fstat(fd, &after) == 0 else { throw systemError("Restat revision bytes") }
#if canImport(Darwin)
    let timesMatch = before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec &&
        before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec &&
        before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec &&
        before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
#else
    let timesMatch = before.st_mtim.tv_sec == after.st_mtim.tv_sec &&
        before.st_mtim.tv_nsec == after.st_mtim.tv_nsec &&
        before.st_ctim.tv_sec == after.st_ctim.tv_sec &&
        before.st_ctim.tv_nsec == after.st_ctim.tv_nsec
#endif
    try check(before.st_dev == after.st_dev && before.st_ino == after.st_ino &&
              before.st_size == after.st_size && timesMatch, "Revision changed while reading")
    return (data, after)
}
private func convertLegacyRecord(_ bytes: Data, item: String, revision: String) throws -> Data {
    let old = try LegacyRecordCodec.decode(bytes)
    try check(old.itemID == item && old.revisionID == revision, "Legacy revision identity differs from its path")
    try ItemSemantics.validate(old)
    let encoded = try MessageRecordCodec.encode(old)
    try check(try MessageRecordCodec.decode(encoded) == old, "Message encoding changed the logical revision")
    return encoded
}
private func revisionDescriptors(_ revision: Revision, oldBytes: Data, newBytes: Data) throws
    -> (PersonalRevisionDescriptor, PersonalRevisionDescriptor) {
    let parents = try revision.provenance?.parents ?? revision.supersedes.map { [$0] } ?? []
    let old = PersonalRevisionDescriptor(kind: "revision", id: revision.revisionID,
        byteCount: Int64(oldBytes.count), sha256: digest(oldBytes), itemID: revision.itemID,
        parentRevisionIDs: parents)
    let new = PersonalRevisionDescriptor(kind: "revision", id: revision.revisionID,
        byteCount: Int64(newBytes.count), sha256: digest(newBytes), itemID: revision.itemID,
        parentRevisionIDs: parents)
    try old.validate(); try new.validate()
    return (old, new)
}
private func peerDescriptorsIfRepresentable(_ revision: Revision, oldBytes: Data, newBytes: Data) throws
    -> (PersonalRevisionDescriptor, PersonalRevisionDescriptor)? {
    let parents = try revision.provenance?.parents ?? revision.supersedes.map { [$0] } ?? []
    guard PersonalRevisionDescriptor.validID(revision.itemID), PersonalRevisionDescriptor.validID(revision.revisionID),
          parents.allSatisfy(PersonalRevisionDescriptor.validID) else { return nil }
    return try revisionDescriptors(revision, oldBytes: oldBytes, newBytes: newBytes)
}
private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
private func pendingPersonalRevisions(_ root: Int32, owner: uid_t, map: TransientDescriptorMap?,
                                      converted: Bool = false, mixed: Bool = false,
                                      queue: Bool = false) throws -> Int {
    guard try metadata(root, ".personal-sync") != nil else { return 0 }
    let sync = try directory(root, ".personal-sync", owner: owner); defer { close(sync) }
    var count = 0
    if try metadata(sync, "stages") != nil {
        let stages = try directory(sync, "stages", owner: owner); defer { close(stages) }
        try entries(stages) { name in
            let (bytes, _) = try readBoundedRecord(stages, name, owner: owner, expectedMode: 0o400)
            try check(bytes.count <= 16384, "Personal stage metadata exceeds its bound")
            guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  Set(object.keys) == ["descriptor", "stageID"],
                  let descriptor = object["descriptor"] as? [String: Any],
                  let kind = descriptor["kind"] as? String, ["revision", "original", "document"].contains(kind),
                  let stageID = object["stageID"] as? String, PersonalRevisionDescriptor.validID(stageID)
            else { throw Failure("Malformed personal stage metadata; recover on 16.2") }
            let descriptorBytes = try JSONSerialization.data(withJSONObject: descriptor)
            let coreDescriptor = try JSON.decode(PersonalObjectDescriptor.self, descriptorBytes)
            try coreDescriptor.validate()
            try check(name == digest(try JSON.encode(coreDescriptor)) + ".json",
                      "Personal stage descriptor key differs")
            if kind != "revision" {
                // Preserve ordinary partial original/document transfers byte-for-byte.
                // A missing stage can be a previously adopted object; normal Core retry
                // remains responsible for resolving that existing state.
                if try metadata(root, "attachments") != nil {
                    let attachments = try directory(root, "attachments", owner: owner); defer { close(attachments) }
                    let stageDirectory = try converted || (mixed && metadata(attachments, ".staging") == nil) ? "staging" : ".staging"
                    if try metadata(attachments, stageDirectory) != nil {
                        let payloads = try directory(attachments, stageDirectory, owner: owner); defer { close(payloads) }
                        if let value = try metadata(payloads, stageID + ".stage") {
                            try check((value.st_mode & S_IFMT) == S_IFREG && value.st_uid == owner &&
                                      value.st_mode & 0o7777 == 0o600 && value.st_nlink == 1 &&
                                      value.st_size >= 0 && UInt64(value.st_size) <= UInt64(coreDescriptor.byteCount),
                                      "Unsafe retained non-revision stage \(stageID)")
                        }
                    }
                }
                return
            }
            let revision: PersonalRevisionDescriptor
            do { revision = try PersonalRevisionDescriptor.decode(descriptor) }
            catch {
                let recorded = (descriptor["id"] as? String).flatMap {
                    PersonalRevisionDescriptor.validID($0) ? $0 : nil
                }
                let revisionLabel = recorded.map { ", revision " + $0 } ?? ""
                throw Failure("Malformed revision stage \(stageID)\(revisionLabel); recover it on 16.2")
            }
            try check(name == (try revision.key) + ".json", "Personal revision stage key differs")
            guard try metadata(root, "attachments") != nil else {
                throw Failure("Missing revision stage \(stageID) for revision \(revision.id); restore 16.2 sync")
            }
            let attachments = try directory(root, "attachments", owner: owner); defer { close(attachments) }
            let stageDirectory = try converted || (mixed && metadata(attachments, ".staging") == nil) ? "staging" : ".staging"
            guard try metadata(attachments, stageDirectory) != nil else {
                throw Failure("Missing revision stage \(stageID) for revision \(revision.id); restore 16.2 sync")
            }
            let payloads = try directory(attachments, stageDirectory, owner: owner); defer { close(payloads) }
            let stageName = stageID + ".stage"
            guard try metadata(payloads, stageName) != nil else {
                throw Failure("Missing revision stage \(stageID) for revision \(revision.id); restore 16.2 sync")
            }
            let raw: Data
            do {
                (raw, _) = try readBoundedRecord(payloads, stageName, owner: owner, expectedMode: 0o600)
            } catch {
                throw Failure("Incomplete or unsafe revision \(revision.id), stage \(stageID); restore 16.2 sync before upgrading")
            }
            try check(UInt64(raw.count) == UInt64(revision.byteCount) && digest(raw) == revision.sha256,
                      "Incomplete or changed revision \(revision.id), stage \(stageID); restore 16.2 sync before upgrading")
            let current = (converted || mixed) ? try? MessageRecordCodec.decode(raw) : nil
            let decoded: Revision
            do { decoded = try current ?? LegacyRecordCodec.decode(raw) }
            catch { throw Failure("Malformed revision \(revision.id), stage \(stageID); recover it on 16.2") }
            try check(!converted || current != nil, "Retained revision stage still uses the old encoding")
            if current != nil {
                try ItemSemantics.validate(decoded)
                try check(try MessageRecordCodec.encode(decoded) == raw,
                          "Retained message stage is not in deterministic canonical encoding")
            }
            let parents = try decoded.provenance?.parents ?? decoded.supersedes.map { [$0] } ?? []
            try check(decoded.itemID == revision.itemID && decoded.revisionID == revision.id &&
                      parents == revision.parentRevisionIDs, "Staged revision descriptor differs from its content")
            let encoded: Data
            do { encoded = try current != nil ? raw : convertLegacyRecord(raw, item: revision.itemID, revision: revision.id) }
            catch {
                throw Failure("Malformed revision \(revision.id), stage \(stageID); recover it on 16.2: \(error)")
            }
            let pair = try revisionDescriptors(decoded, oldBytes: raw, newBytes: encoded)
            try check(pair.0 == revision, "Staged revision descriptor differs from canonical content")
            let oldKey = try revision.key, newKey = try pair.1.key
            let newBinding = try JSON.encode(PersonalRevisionStage(descriptor: pair.1, stageID: stageID))
            try check(newBinding.count <= 16384,
                      "Converted revision \(revision.id), stage \(stageID), exceeds the stage metadata limit")
            if oldKey != newKey, try metadata(stages, newKey + ".json") != nil {
                let (otherBytes, _) = try readBoundedRecord(stages, newKey + ".json", owner: owner, expectedMode: 0o400)
                let other = try JSON.decode(PersonalRevisionStage.self, otherBytes)
                throw Failure("Converted stage key collision: revision \(revision.id), stage \(stageID); revision \(other.descriptor.id), stage \(other.stageID)")
            }
            try map?.staged(oldKey: revision.key, newKey: pair.1.key, revision: revision.id, stage: stageID,
                            newDescriptor: JSON.encode(pair.1))
            if queue && current == nil, let map {
                var oldReviewSHA: String?
                var newReview: Data?
                if try metadata(sync, "reviews") != nil {
                    let reviews = try directory(sync, "reviews", owner: owner); defer { close(reviews) }
                    if try metadata(reviews, name) != nil {
                        let (reviewBytes, _) = try readBoundedRecord(reviews, name, owner: owner, expectedMode: 0o400)
                        let review = try decodePersonalReview(reviewBytes, descriptor: revision)
                        oldReviewSHA = digest(reviewBytes)
                        newReview = try JSON.encode(review.replacingDescriptor(pair.1))
                    }
                }
                let transition = PersonalStageTransition(stageID: stageID, oldDescriptor: revision,
                    newDescriptor: pair.1, oldBindingSHA256: digest(bytes), newBinding: newBinding,
                    oldReviewSHA256: oldReviewSHA, newReview: newReview)
                try map.enqueue(priority: 0, payload: encoder.encode(WorkItem(kind: "stage", stage: transition)))
            }
            count += 1
        }
    }
    return count
}
private func pendingPersonalReviews(_ root: Int32, owner: uid_t, map: TransientDescriptorMap,
                                    allowMixed: Bool = false) throws -> Int {
    guard try metadata(root, ".personal-sync") != nil else { return 0 }
    let sync = try directory(root, ".personal-sync", owner: owner); defer { close(sync) }
    guard try metadata(sync, "reviews") != nil else { return 0 }
    let reviews = try directory(sync, "reviews", owner: owner); defer { close(reviews) }
    var count = 0
    var total = 0
    var convertedTotal = 0
    try entries(reviews) { name in
        count += 1
        try check(count <= 1024, "Personal review count exceeds its supported bound")
        let (bytes, _) = try readBoundedRecord(reviews, name, owner: owner, expectedMode: 0o400)
        total += bytes.count
        try check(bytes.count <= 128 * 1024 && total <= 16 * 1024 * 1024,
                  "Personal review metadata exceeds its supported bound")
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(object.keys) == ["reviewID", "descriptor", "sourceReplicaID", "currentFrontier",
                                   "baseRevisionIDs", "reason", "disposition"],
              let descriptorObject = object["descriptor"] else {
            throw Failure("Malformed personal review metadata; recover it on 16.2")
        }
        let descriptor = try PersonalRevisionDescriptor.decode(descriptorObject)
        let review = try JSONDecoder().decode(PersonalRevisionReview.self, from: bytes)
        try check(review.descriptor == descriptor && PersonalRevisionDescriptor.validID(review.reviewID) &&
                  PersonalRevisionDescriptor.validID(review.sourceReplicaID) &&
                  ["pending", "rejected", "accepted"].contains(review.disposition) &&
                  review.currentFrontier.allSatisfy(PersonalRevisionDescriptor.validID) &&
                  review.baseRevisionIDs == descriptor.parentRevisionIDs &&
                  !review.reason.isEmpty && name == (try descriptor.key) + ".json",
                  "Invalid retained personal review \(review.reviewID); recover it on 16.2")
        let oldKey = try descriptor.key
        let staged = try map.newKey(oldKey: oldKey, staged: true)
        let directCanonical = try map.newKey(oldKey: oldKey, staged: false)
        let canonical = try directCanonical ?? (allowMixed && map.hasCanonicalNewKey(oldKey) ? oldKey : nil)
        if review.disposition == "accepted" {
            try check(canonical != nil, "Accepted review \(review.reviewID) has no matching canonical revision")
        } else {
            try check(staged != nil || canonical != nil, "Unaccepted review \(review.reviewID) has neither a complete retained stage nor a matching canonical revision; recover it on 16.2")
        }
        guard let newKey = staged ?? canonical else { throw Failure("Review descriptor cannot be mapped") }
        if let staged, let canonical { try check(staged == canonical, "Review descriptor mapping differs") }
        let mapped = try map.descriptor(oldKey: oldKey, staged: true)
            ?? map.descriptor(oldKey: oldKey, staged: false)
            ?? map.descriptor(oldKey: oldKey, staged: false, byNewKey: true)
        guard let mapped else { throw Failure("Review \(review.reviewID) lacks a converted descriptor") }
        try check(try mapped.key == newKey, "Mapped review descriptor key differs")
        let newReview = try JSON.encode(review.replacingDescriptor(mapped))
        convertedTotal += newReview.count
        try check(newReview.count <= 128 * 1024,
                  "Converted review \(review.reviewID) exceeds its supported metadata limit")
        try check(convertedTotal <= 16 * 1024 * 1024, "Converted reviews exceed their supported aggregate limit")
        if oldKey != newKey, try metadata(reviews, newKey + ".json") != nil {
            let (otherBytes, _) = try readBoundedRecord(reviews, newKey + ".json", owner: owner, expectedMode: 0o400)
            let other = try JSON.decode(PersonalRevisionReview.self, otherBytes)
            throw Failure("Converted review key collision: review \(review.reviewID), revision \(descriptor.id); review \(other.reviewID), revision \(other.descriptor.id)")
        }
        try map.review(oldKey: oldKey, newKey: newKey, review: review.reviewID)
    }
    return count
}
private func deepPreflight(_ root: Int32, owner: uid_t, allowMixed: Bool = false,
                           queue: Bool = false) throws -> (TransientDescriptorMap, Int, Int) {
    let map = try TransientDescriptorMap()
    let schedule: ((Move) throws -> Void)? = queue ? { move in
        try map.enqueue(priority: 1, payload: encoder.encode(WorkItem(kind: "revision", revision: move)))
    } : nil
    try itemTree(root, owner: owner, allowFlat: allowMixed, move: schedule, onLegacy: { path, revision, old, new in
        try map.canonicalIdentity(revision: revision.revisionID, path: path.joined(separator: "/"))
        guard let pair = try peerDescriptorsIfRepresentable(revision, oldBytes: old, newBytes: new) else { return }
        try map.canonical(oldKey: pair.0.key, newKey: pair.1.key, revision: revision.revisionID, path: path.joined(separator: "/"),
                          newDescriptor: JSON.encode(pair.1))
    }, onFlatRevision: { path, revision, bytes in
        try map.canonicalIdentity(revision: revision.revisionID, path: path.joined(separator: "/"))
        guard let pair = try peerDescriptorsIfRepresentable(revision, oldBytes: bytes, newBytes: bytes) else { return }
        try map.canonical(oldKey: pair.0.key, newKey: pair.1.key, revision: revision.revisionID, path: path.joined(separator: "/"),
                          newDescriptor: JSON.encode(pair.1))
    }, onItemDirectory: { path in
        if queue { try map.enqueue(priority: 2, payload: encoder.encode(WorkItem(kind: "directory", directory: path))) }
    })
    try attachmentTree(root, owner: owner, allowMoved: allowMixed, move: nil)
    let stages = try pendingPersonalRevisions(root, owner: owner, map: map, mixed: allowMixed, queue: queue)
    let reviews = try pendingPersonalReviews(root, owner: owner, map: map, allowMixed: allowMixed)
    return (map, stages, reviews)
}
private func validateConvertedPersonal(_ root: Int32, owner: uid_t) throws {
    let map = try TransientDescriptorMap()
    try itemTree(root, owner: owner, allowFlat: true, requireFlat: true, move: nil,
                 onFlatRevision: { path, revision, bytes in
        try map.canonicalIdentity(revision: revision.revisionID, path: path.joined(separator: "/"))
        guard let pair = try peerDescriptorsIfRepresentable(revision, oldBytes: bytes, newBytes: bytes) else { return }
        try map.canonical(oldKey: pair.0.key, newKey: pair.1.key, revision: revision.revisionID, path: path.joined(separator: "/"),
                          newDescriptor: JSON.encode(pair.1))
    })
    try attachmentTree(root, owner: owner, allowMoved: true, requireMoved: true, move: nil)
    _ = try pendingPersonalRevisions(root, owner: owner, map: map, converted: true)
    _ = try pendingPersonalReviews(root, owner: owner, map: map)
}
private func directoryDigest(_ parent: Int32, _ name: String, owner: uid_t) throws -> (String, UInt64, stat) {
    let root = try directory(parent, name, owner: owner)
    defer { close(root) }
    var rootStat = stat()
    guard fstat(root, &rootStat) == 0 else { throw systemError("Stat staged directory") }
    var aggregate = [UInt8](repeating: 0, count: 32)
    var count: UInt64 = 0
    func add(_ bytes: Data) {
        let hash = SHA256.hash(data: bytes)
        for (i, value) in hash.enumerated() { aggregate[i] ^= value }
        count += 1
    }
    func visit(_ fd: Int32, path: [String], depth: Int) throws {
        try check(depth <= 64, "Staged directory depth exceeds limit")
        try entries(fd) { name in
            guard let s = try metadata(fd, name) else { throw Failure("Staged entry vanished") }
            let relative = (path + [name]).joined(separator: "/")
            try check(relative.utf8.count <= 4096 && !relative.contains("\n"), "Unsupported staged path")
            if (s.st_mode & S_IFMT) == S_IFDIR {
                let child = try directory(fd, name, owner: owner); defer { close(child) }
                add(Data("directory\0\(relative)\0\(s.st_mode & 0o7777)".utf8))
                try visit(child, path: path + [name], depth: depth + 1)
            } else if (s.st_mode & S_IFMT) == S_IFREG {
                let (digest, size, _) = try hashFile(fd, name, owner: owner)
                add(Data("file\0\(relative)\0\(s.st_mode & 0o7777)\0\(size)\0\(digest)".utf8))
            } else { throw Failure("Link or special file in staged directory") }
        }
    }
    try visit(root, path: [], depth: 0)
    let combined = Data("tractanda-layout17-directory-v1\0\(rootStat.st_mode & 0o7777)\0\(count)\0".utf8) + Data(aggregate)
    let digest = SHA256.hash(data: combined).map { String(format: "%02x", $0) }.joined()
    return (digest, count, rootStat)
}
private func perform(_ move: Move, root: Int32, owner: uid_t) throws {
    try check(!move.source.isEmpty && !move.destination.isEmpty &&
              move.source.first == move.destination.first &&
              ["items", "attachments"].contains(move.source[0]), "Invalid journal move")
    if move.kind == "revision" {
        try check(move.source.count == 8 && move.destination.count == 7 &&
                  Array(move.source.prefix(6)) == Array(move.destination.prefix(6)) &&
                  validID(move.source[6]) && move.source[7].hasSuffix(".tractanda"),
                  "Invalid item move shape")
        let revision = String(move.source[7].dropLast(".tractanda".count))
        try check(validID(revision) && move.destination[6] == move.source[6] + "." + move.source[7],
                  "Invalid item identity")
        for (index, part) in move.source[1...5].enumerated() {
            try check(part.utf8.count == (index == 0 ? 4 : 2) &&
                      part.utf8.allSatisfy({ (48...57).contains($0) }), "Invalid arrival minute")
        }
    } else {
        try check(move.kind == "directory" && move.source.count == 2 && move.destination.count == 2 &&
                  ((move.source[1] == ".staging" && move.destination[1] == "staging") ||
                   (move.source[1] == ".placements" && move.destination[1] == "placements")),
                  "Invalid attachment move shape")
    }
    let a = try parentDirectory(root, Array(move.source.dropLast()), owner: owner); defer { close(a) }
    let b = try parentDirectory(root, Array(move.destination.dropLast()), owner: owner); defer { close(b) }
    let source = move.source.last!, target = move.destination.last!
    if move.kind == "revision" {
        try performRevision(move, sourceDirectory: a, source: source, targetDirectory: b, target: target, owner: owner)
        return
    }
    let sourceStat = try metadata(a, source)
    let targetStat = try metadata(b, target)
    try check(sourceStat != nil || targetStat != nil, "Both journal paths are absent")
    if let s = sourceStat, let d = targetStat {
        try check(move.kind == "file" && s.st_dev == d.st_dev && s.st_ino == d.st_ino,
                  "Journal destination collision")
    }
    let parent = sourceStat == nil ? b : a
    let name = sourceStat == nil ? target : source
    let actual = try move.kind == "file" ? hashFile(parent, name, owner: owner) :
        directoryDigest(parent, name, owner: owner)
    try check(actual.0 == move.contentSHA256 && actual.1 == move.byteCount,
              "Journal content differs from its durable commitment")
    try spaceFault("move")
    let rc = source.withCString { source in
        target.withCString { target in
            if move.kind == "file" {
                return moveFile(a, source, b, target, owner, UInt64(actual.2.st_dev), UInt64(actual.2.st_ino), 0)
            }
            if move.kind == "directory" {
                return moveDirectory(a, source, b, target, owner, UInt64(actual.2.st_dev), UInt64(actual.2.st_ino), 0)
            }
            return -1
        }
    }
    guard rc == 0 else { throw systemError("Move \(move.source.joined(separator: "/"))") }
}

private func performRevision(_ move: Move, sourceDirectory: Int32, source: String,
                             targetDirectory: Int32, target: String, owner: uid_t) throws {
    guard let newSHA = move.newContentSHA256, let newSize = move.newByteCount,
          let originalMode = move.originalMode, let originalGID = move.originalGID,
          originalMode & 0o077 == 0, originalMode & ~UInt32(0o7777) == 0,
          PersonalRevisionDescriptor.validDigest(newSHA), newSize > 0,
          newSize <= UInt64(MessageRecordCodec.maximumRecordBytes) else {
        throw Failure("Revision journal lacks its new byte commitment")
    }
    let sourceMeta = try metadata(sourceDirectory, source)
    let targetMeta = try metadata(targetDirectory, target)
    try check(sourceMeta != nil || targetMeta != nil, "Both journal revision paths are absent")
    let itemID = move.source[6]
    let revisionID = String(source.dropLast(".tractanda".count))
    var generated: Data?
    var sourceIdentity: stat?
    if sourceMeta != nil {
        let (oldBytes, oldStat) = try readBoundedRecord(sourceDirectory, source, owner: owner,
                                                         expectedMode: mode_t(originalMode), allowHardlinks: true)
        try check(UInt32(oldStat.st_gid) == originalGID, "Legacy revision group differs from journal")
        try check(UInt64(oldBytes.count) == move.byteCount && digest(oldBytes) == move.contentSHA256,
                  "Legacy revision differs from its journal commitment")
        let newBytes = try convertLegacyRecord(oldBytes, item: itemID, revision: revisionID)
        try check(UInt64(newBytes.count) == newSize && digest(newBytes) == newSHA,
                  "Converted revision differs from its journal commitment")
        generated = newBytes
        sourceIdentity = oldStat
    }
    if targetMeta != nil {
        let (targetBytes, targetStat) = try readBoundedRecord(targetDirectory, target, owner: owner,
                                                               expectedMode: mode_t(originalMode))
        try check(UInt32(targetStat.st_gid) == originalGID, "Message revision group differs from journal")
        try check(UInt64(targetBytes.count) == newSize && digest(targetBytes) == newSHA,
                  "Message revision destination collision")
        let decoded = try MessageRecordCodec.decode(targetBytes)
        try check(decoded.itemID == itemID && decoded.revisionID == revisionID,
                  "Message revision destination identity differs")
        if let generated { try check(targetBytes == generated, "Message revision content differs") }
    } else {
        guard let generated else { throw Failure("Missing message revision and legacy source") }
        try spaceFault("move")
        let temporary = ".layout17-record-" + newSHA + ".tmp"
        if let prior = try metadata(targetDirectory, temporary) {
            try check((prior.st_mode & S_IFMT) == S_IFREG && prior.st_nlink == 1 &&
                      (prior.st_uid == owner || (geteuid() == 0 && prior.st_uid == 0)) &&
                      [mode_t(originalMode), mode_t(0o600)].contains(prior.st_mode & 0o7777) &&
                      prior.st_size >= 0 && UInt64(prior.st_size) <= newSize,
                      "Unsafe retained revision temporary")
            let fd = openat(targetDirectory, temporary, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw systemError("Open retained revision temporary") }
            defer { close(fd) }
            var bytes = Data(count: Int(prior.st_size))
            try bytes.withUnsafeMutableBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = read(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { throw systemError("Read retained revision temporary") }
                    offset += n
                }
            }
            try check(generated.prefix(bytes.count).elementsEqual(bytes),
                      "Retained revision temporary is not the expected prefix")
            guard unlinkat(targetDirectory, temporary, 0) == 0 && fsync(targetDirectory) == 0 else {
                throw systemError("Clean retained revision temporary")
            }
        }
        let fd = openat(targetDirectory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw systemError("Create staged message revision") }
        defer { close(fd); _ = unlinkat(targetDirectory, temporary, 0) }
        guard fchown(fd, owner, gid_t(originalGID)) == 0 else { throw systemError("Set revision owner and group") }
        try generated.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                try spaceFault("revision-write")
                let n = write(fd, raw.baseAddress!.advanced(by: offset), min(65536, raw.count - offset))
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw systemError("Write staged message revision") }
                offset += n
            }
        }
        guard fchmod(fd, mode_t(originalMode)) == 0, durableSync(fd) == 0 else { throw systemError("Seal message revision") }
        boundary("revision-temp")
        guard renameExclusive(targetDirectory, temporary, targetDirectory, target) == 0,
              fsync(targetDirectory) == 0 else { throw systemError("Publish message revision") }
        boundary("revision-published")
    }
    if let sourceIdentity {
        let (rechecked, latest) = try readBoundedRecord(sourceDirectory, source, owner: owner,
                                                         expectedMode: mode_t(originalMode), allowHardlinks: true)
        try check(digest(rechecked) == move.contentSHA256 && UInt64(rechecked.count) == move.byteCount &&
                  latest.st_dev == sourceIdentity.st_dev && latest.st_ino == sourceIdentity.st_ino &&
                  latest.st_nlink == sourceIdentity.st_nlink && UInt32(latest.st_gid) == originalGID &&
                  sameTimes(latest, sourceIdentity),
                  "Legacy revision changed before retirement")
        guard let current = try metadata(sourceDirectory, source),
              current.st_dev == sourceIdentity.st_dev, current.st_ino == sourceIdentity.st_ino,
              current.st_uid == owner, current.st_nlink == sourceIdentity.st_nlink,
              current.st_mode & 0o7777 == mode_t(originalMode), UInt32(current.st_gid) == originalGID,
              current.st_size == latest.st_size, sameTimes(current, latest) else {
            throw Failure("Legacy revision changed before retirement")
        }
        guard unlinkat(sourceDirectory, source, 0) == 0 else { throw systemError("Retire legacy revision") }
        boundary("revision-retired")
    }
    guard fsync(targetDirectory) == 0, fsync(sourceDirectory) == 0 else { throw systemError("Sync revision parents") }
}

private func publishSealed(_ directory: Int32, name: String, bytes: Data, owner: uid_t) throws {
    if try metadata(directory, name) != nil {
        let (existing, _) = try readBoundedRecord(directory, name, owner: owner, expectedMode: 0o400)
        try check(existing == bytes, "Converted private metadata destination collision")
        return
    }
    let temporary = ".layout17-meta-" + digest(bytes) + ".tmp"
    if let prior = try metadata(directory, temporary) {
        try check((prior.st_mode & S_IFMT) == S_IFREG && prior.st_nlink == 1 &&
                  (prior.st_uid == owner || (geteuid() == 0 && prior.st_uid == 0)) &&
                  [mode_t(0o400), mode_t(0o600)].contains(prior.st_mode & 0o7777) &&
                  prior.st_size >= 0 && prior.st_size <= bytes.count,
                  "Unsafe retained private metadata temporary")
        let fd = openat(directory, temporary, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw systemError("Open private metadata temporary") }
        defer { close(fd) }
        var prefix = Data(count: Int(prior.st_size))
        try prefix.withUnsafeMutableBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = read(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw systemError("Read private metadata temporary") }
                offset += n
            }
        }
        try check(bytes.prefix(prefix.count).elementsEqual(prefix), "Unexpected private metadata temporary")
        guard unlinkat(directory, temporary, 0) == 0 && fsync(directory) == 0 else {
            throw systemError("Clean private metadata temporary")
        }
    }
    let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw systemError("Create converted private metadata") }
    defer { close(fd); _ = unlinkat(directory, temporary, 0) }
    if geteuid() == 0 { guard fchown(fd, owner, gid_t.max) == 0 else { throw systemError("Set private metadata owner") } }
    try bytes.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw systemError("Write converted private metadata") }
            offset += n
        }
    }
    guard fchmod(fd, 0o400) == 0, durableSync(fd) == 0 else { throw systemError("Seal converted private metadata") }
    boundary("private-metadata-temp")
    guard renameExclusive(directory, temporary, directory, name) == 0, fsync(directory) == 0 else {
        throw systemError("Publish converted private metadata")
    }
}

private func retireSealed(_ directory: Int32, name: String, expectedSHA256: String, owner: uid_t) throws {
    guard try metadata(directory, name) != nil else { return }
    let (bytes, _) = try readBoundedRecord(directory, name, owner: owner, expectedMode: 0o400)
    try check(digest(bytes) == expectedSHA256, "Retained private metadata changed before retirement")
    guard unlinkat(directory, name, 0) == 0, fsync(directory) == 0 else {
        throw systemError("Retire old private metadata")
    }
}

private func decodePersonalReview(_ bytes: Data, descriptor: PersonalRevisionDescriptor) throws -> PersonalRevisionReview {
    try check(bytes.count <= 128 * 1024, "Personal review metadata exceeds its bound")
    guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
          Set(object.keys) == ["reviewID", "descriptor", "sourceReplicaID", "currentFrontier",
                               "baseRevisionIDs", "reason", "disposition"],
          let descriptorObject = object["descriptor"] else {
        throw Failure("Malformed personal review metadata; recover it on 16.2")
    }
    let parsed = try PersonalRevisionDescriptor.decode(descriptorObject)
    let review = try JSONDecoder().decode(PersonalRevisionReview.self, from: bytes)
    try check(parsed == descriptor && review.descriptor == descriptor &&
              PersonalRevisionDescriptor.validID(review.reviewID) &&
              PersonalRevisionDescriptor.validID(review.sourceReplicaID) &&
              ["pending", "rejected", "accepted"].contains(review.disposition) &&
              review.currentFrontier.allSatisfy(PersonalRevisionDescriptor.validID) &&
              review.baseRevisionIDs == descriptor.parentRevisionIDs && !review.reason.isEmpty,
              "Invalid retained personal review; recover it on 16.2")
    return review
}

private func performReviewTransition(_ move: PersonalReviewTransition, root: Int32, owner: uid_t) throws {
    try move.oldDescriptor.validate(); try move.newDescriptor.validate()
    let oldKey = try move.oldDescriptor.key, newKey = try move.newDescriptor.key
    try check(oldKey != newKey && move.oldDescriptor.id == move.newDescriptor.id &&
              move.oldDescriptor.itemID == move.newDescriptor.itemID &&
              move.oldDescriptor.parentRevisionIDs == move.newDescriptor.parentRevisionIDs,
              "Review transition changes logical revision identity")
    let reviews = try parentDirectory(root, [".personal-sync", "reviews"], owner: owner); defer { close(reviews) }
    let oldName = oldKey + ".json", newName = newKey + ".json"
    let newReview = try decodePersonalReview(move.newReview, descriptor: move.newDescriptor)
    if try metadata(reviews, oldName) != nil {
        let (oldBytes, _) = try readBoundedRecord(reviews, oldName, owner: owner, expectedMode: 0o400)
        try check(digest(oldBytes) == move.oldReviewSHA256, "Old review changed during migration")
        let oldReview = try decodePersonalReview(oldBytes, descriptor: move.oldDescriptor)
        try check(oldReview.replacingDescriptor(move.newDescriptor) == newReview,
                  "Review transition changed its disposition or context")
    }
    try publishSealed(reviews, name: newName, bytes: move.newReview, owner: owner)
    boundary("review-published")
    try retireSealed(reviews, name: oldName, expectedSHA256: move.oldReviewSHA256, owner: owner)
    boundary("review-retired")
}

private func performStageTransition(_ move: PersonalStageTransition, root: Int32, owner: uid_t) throws {
    try move.oldDescriptor.validate(); try move.newDescriptor.validate()
    let oldKey = try move.oldDescriptor.key, newKey = try move.newDescriptor.key
    try check(PersonalRevisionDescriptor.validID(move.stageID) && oldKey != newKey &&
              move.oldDescriptor.id == move.newDescriptor.id &&
              move.oldDescriptor.itemID == move.newDescriptor.itemID &&
              move.oldDescriptor.parentRevisionIDs == move.newDescriptor.parentRevisionIDs &&
              (move.oldReviewSHA256 == nil) == (move.newReview == nil),
              "Invalid personal stage transition")
    let newBinding = try JSON.decode(PersonalRevisionStage.self, move.newBinding)
    try check(newBinding.stageID == move.stageID && newBinding.descriptor == move.newDescriptor,
              "Converted stage binding differs from journal")
    let bindings = try parentDirectory(root, [".personal-sync", "stages"], owner: owner); defer { close(bindings) }
    let stageDir = try parentDirectory(root, ["attachments", ".staging"], owner: owner); defer { close(stageDir) }
    let oldName = oldKey + ".json", newName = newKey + ".json", stageName = move.stageID + ".stage"
    if try metadata(bindings, oldName) != nil {
        let (old, _) = try readBoundedRecord(bindings, oldName, owner: owner, expectedMode: 0o400)
        let stage = try JSON.decode(PersonalRevisionStage.self, old)
        try check(digest(old) == move.oldBindingSHA256 && stage.stageID == move.stageID &&
                  stage.descriptor == move.oldDescriptor, "Old stage binding changed")
    }
    let (stageBytes, stageStat) = try readBoundedRecord(stageDir, stageName, owner: owner, expectedMode: 0o600)
    let stageSHA = digest(stageBytes)
    let newBytes: Data
    if stageSHA == move.oldDescriptor.sha256 && Int64(stageBytes.count) == move.oldDescriptor.byteCount {
        newBytes = try convertLegacyRecord(stageBytes, item: move.oldDescriptor.itemID, revision: move.oldDescriptor.id)
    } else {
        try check(stageSHA == move.newDescriptor.sha256 && Int64(stageBytes.count) == move.newDescriptor.byteCount,
                  "Personal revision stage differs from both journal commitments")
        let revision = try MessageRecordCodec.decode(stageBytes)
        try check(revision.itemID == move.newDescriptor.itemID && revision.revisionID == move.newDescriptor.id,
                  "Converted stage identity differs")
        newBytes = stageBytes
    }
    try check(digest(newBytes) == move.newDescriptor.sha256 && Int64(newBytes.count) == move.newDescriptor.byteCount,
              "Converted stage differs from journal")
    try publishSealed(bindings, name: newName, bytes: move.newBinding, owner: owner)
    boundary("stage-binding-published")
    if let reviewBytes = move.newReview, let oldReviewSHA = move.oldReviewSHA256 {
        try performReviewTransition(.init(oldDescriptor: move.oldDescriptor, newDescriptor: move.newDescriptor,
                                          oldReviewSHA256: oldReviewSHA, newReview: reviewBytes), root: root, owner: owner)
    }
    if stageSHA == move.oldDescriptor.sha256 {
        let temporary = ".layout17-stage-" + move.newDescriptor.sha256 + ".tmp"
        if let retained = try metadata(stageDir, temporary) {
            try check((retained.st_mode & S_IFMT) == S_IFREG && retained.st_nlink == 1 &&
                      (retained.st_uid == owner || (geteuid() == 0 && retained.st_uid == 0)) &&
                      retained.st_mode & 0o7777 == 0o600 && retained.st_size >= 0 &&
                      retained.st_size <= newBytes.count, "Unsafe retained stage temporary")
            let fd = openat(stageDir, temporary, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw systemError("Open stage temporary") }
            defer { close(fd) }
            var prefix = Data(count: Int(retained.st_size))
            try prefix.withUnsafeMutableBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = read(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { throw systemError("Read stage temporary") }
                    offset += n
                }
            }
            try check(newBytes.prefix(prefix.count).elementsEqual(prefix), "Unexpected stage temporary contents")
            guard unlinkat(stageDir, temporary, 0) == 0 && fsync(stageDir) == 0 else {
                throw systemError("Clean stage temporary")
            }
        }
        let fd = openat(stageDir, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw systemError("Create converted revision stage") }
        defer { close(fd); _ = unlinkat(stageDir, temporary, 0) }
        if geteuid() == 0 { guard fchown(fd, owner, gid_t.max) == 0 else { throw systemError("Set stage owner") } }
        try newBytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                try spaceFault("stage-write")
                let n = write(fd, raw.baseAddress!.advanced(by: offset), min(65536, raw.count - offset))
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw systemError("Write converted revision stage") }
                offset += n
            }
        }
        guard fchmod(fd, 0o600) == 0, durableSync(fd) == 0 else { throw systemError("Seal converted revision stage") }
        boundary("stage-temp")
        guard let named = try metadata(stageDir, stageName), named.st_dev == stageStat.st_dev,
              named.st_ino == stageStat.st_ino, named.st_uid == owner, named.st_nlink == 1 else {
            throw Failure("Old revision stage changed before replacement")
        }
        guard renameat(stageDir, temporary, stageDir, stageName) == 0, fsync(stageDir) == 0 else {
            throw systemError("Replace converted revision stage")
        }
        boundary("stage-data-published")
    }
    try retireSealed(bindings, name: oldName, expectedSHA256: move.oldBindingSHA256, owner: owner)
    boundary("stage-binding-retired")
}

private func planCanonicalReview(_ root: Int32, owner: uid_t, revision: Revision,
                                 oldBytes: Data, newBytes: Data) throws -> PersonalReviewTransition? {
    guard try metadata(root, ".personal-sync") != nil else { return nil }
    let sync = try directory(root, ".personal-sync", owner: owner); defer { close(sync) }
    guard try metadata(sync, "reviews") != nil else { return nil }
    let reviews = try directory(sync, "reviews", owner: owner); defer { close(reviews) }
    guard let pair = try peerDescriptorsIfRepresentable(revision, oldBytes: oldBytes, newBytes: newBytes)
    else { return nil }
    let name = try pair.0.key + ".json"
    guard try metadata(reviews, name) != nil else { return nil }
    let (bytes, _) = try readBoundedRecord(reviews, name, owner: owner, expectedMode: 0o400)
    let review = try decodePersonalReview(bytes, descriptor: pair.0)
    return .init(oldDescriptor: pair.0, newDescriptor: pair.1, oldReviewSHA256: digest(bytes),
                 newReview: try JSON.encode(review.replacingDescriptor(pair.1)))
}

private func itemTree(_ root: Int32, owner: uid_t, allowFlat: Bool, requireFlat: Bool = false,
                      move: ((Move) throws -> Void)?,
                      onFlat: (([String], String, UInt64, mode_t) throws -> Void)? = nil,
                      onLegacy: (([String], Revision, Data, Data) throws -> Void)? = nil,
                      onFlatRevision: (([String], Revision, Data) throws -> Void)? = nil,
                      onItemDirectory: (([String]) throws -> Void)? = nil) throws {
    guard try metadata(root, "items") != nil else { return }
    let items = try directory(root, "items", owner: owner); defer { close(items) }
    func visit(_ fd: Int32, _ parts: [String]) throws {
        if parts.count < 5 {
            try entries(fd) { name in
                let width = parts.isEmpty ? 4 : 2
                try check(name.utf8.count == width && name.utf8.allSatisfy({ (48...57).contains($0) }),
                          "Unexpected item arrival directory \(name)")
                let next = try directory(fd, name, owner: owner); defer { close(next) }
                try visit(next, parts + [name])
            }
            return
        }
        try check(validMinute(parts), "Invalid item arrival minute")
        try entries(fd) { name in
            guard let entry = try metadata(fd, name) else { throw Failure("Item entry vanished") }
            if (entry.st_mode & S_IFMT) == S_IFREG {
                let pieces = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
                try check(allowFlat && pieces.count == 3 && validID(pieces[0]) && validID(pieces[1]) &&
                          pieces[2] == "tractanda" && entry.st_uid == owner && entry.st_nlink == 1,
                          "Unexpected flat item or unsafe entry")
                let (bytes, _) = try readBoundedRecord(fd, name, owner: owner, expectedMode: nil)
                let revision = try MessageRecordCodec.decode(bytes)
                try ItemSemantics.validate(revision)
                try check(try MessageRecordCodec.encode(revision) == bytes,
                          "Message revision is not in deterministic canonical encoding")
                try check(revision.itemID == pieces[0] && revision.revisionID == pieces[1],
                          "Message revision identity differs from its path")
                if let onFlatRevision { try onFlatRevision(["items"] + parts + [name], revision, bytes) }
                if let onFlat {
                    let digest = try hashFile(fd, name, owner: owner)
                    try onFlat(["items"] + parts + [name], digest.0, digest.1, entry.st_mode & 0o7777)
                }
                return
            }
            try check(!requireFlat, "Old item directory remains after migration")
            try check((entry.st_mode & S_IFMT) == S_IFDIR && validID(name), "Unexpected item directory")
            let itemDir = try directory(fd, name, owner: owner); defer { close(itemDir) }
            try entries(itemDir) { revisionName in
                let pieces = revisionName.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
                try check(pieces.count == 2 && validID(pieces[0]) && pieces[1] == "tractanda",
                          "Unexpected revision filename")
                let (oldBytes, oldStat) = try readBoundedRecord(itemDir, revisionName, owner: owner,
                                                                 expectedMode: nil, allowHardlinks: true)
                let newBytes = try convertLegacyRecord(oldBytes, item: name, revision: pieces[0])
                if let onLegacy { try onLegacy(["items"] + parts + [name, revisionName], LegacyRecordCodec.decode(oldBytes), oldBytes, newBytes) }
                let target = name + "." + revisionName
                let targetMeta = try metadata(fd, target)
                let sourceMeta = try metadata(itemDir, revisionName)
                try check(sourceMeta != nil, "Revision disappeared")
                if let targetMeta {
                    try check(allowFlat && targetMeta.st_dev == sourceMeta!.st_dev &&
                              targetMeta.st_ino == sourceMeta!.st_ino, "Item destination collision")
                }
                if let move {
                    try move(Move(kind: "revision", source: ["items"] + parts + [name, revisionName],
                                  destination: ["items"] + parts + [target],
                                  contentSHA256: digest(oldBytes), byteCount: UInt64(oldBytes.count),
                                  newContentSHA256: digest(newBytes), newByteCount: UInt64(newBytes.count),
                                  originalMode: UInt32(oldStat.st_mode & 0o7777), originalGID: UInt32(oldStat.st_gid)))
                }
            }
            if let onItemDirectory { try onItemDirectory(["items"] + parts + [name]) }
        }
    }
    try visit(items, [])
}

private func completedDigest(_ root: Int32, owner: uid_t) throws -> String {
    var aggregate = [UInt8](repeating: 0, count: 32)
    var count: UInt64 = 0
    func add(_ value: String) {
        let digest = SHA256.hash(data: Data(value.utf8))
        for (index, byte) in digest.enumerated() { aggregate[index] ^= byte }
        count += 1
    }
    try itemTree(root, owner: owner, allowFlat: true, requireFlat: true, move: nil, onFlat: { path, hash, size, mode in
        add("item\0\(path.joined(separator: "/"))\0\(size)\0\(mode)\0\(hash)")
    })
    if try metadata(root, "attachments") != nil {
        let attachments = try directory(root, "attachments", owner: owner); defer { close(attachments) }
        for name in ["staging", "placements"] {
            if try metadata(attachments, name) != nil {
                let digest = try directoryDigest(attachments, name, owner: owner)
                add("attachment-directory\0\(name)\0\(digest.1)\0\(digest.0)")
            }
        }
    }
    if try metadata(root, ".personal-sync") != nil {
        let sync = try directory(root, ".personal-sync", owner: owner); defer { close(sync) }
        for name in ["stages", "reviews"] {
            if try metadata(sync, name) != nil {
                let value = try directoryDigest(sync, name, owner: owner)
                add("personal-metadata\0\(name)\0\(value.1)\0\(value.0)")
            }
        }
    }
    return SHA256.hash(data: Data("tractanda-layout17-completed-v1\0\(count)\0".utf8) + Data(aggregate))
        .map { String(format: "%02x", $0) }.joined()
}

private func attachmentTree(_ root: Int32, owner: uid_t, allowMoved: Bool, requireMoved: Bool = false,
                            move: ((Move) throws -> Void)?) throws {
    guard try metadata(root, "attachments") != nil else { return }
    let attachments = try directory(root, "attachments", owner: owner); defer { close(attachments) }
    for (old, new) in [(".staging", "staging"), (".placements", "placements")] {
        let source = try metadata(attachments, old)
        let target = try metadata(attachments, new)
        if requireMoved { try check(source == nil, "Old attachment directory remains after migration") }
        if target != nil { try check(allowMoved && source == nil, "Attachment destination collision") }
        if source != nil {
            try check(target == nil, "Attachment destination collision")
            let digest = try directoryDigest(attachments, old, owner: owner)
            if let move {
                try move(Move(kind: "directory", source: ["attachments", old],
                              destination: ["attachments", new], contentSHA256: digest.0,
                              byteCount: digest.1))
            }
        }
    }
}

private func openAbsolute(_ path: String) throws -> Int32 {
    try check(path.hasPrefix("/") && path != "/", "A dedicated absolute path is required")
    let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    try check(components.first == "" && components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              "Path must be normalized")
    var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { throw systemError("Open root") }
    for component in components.dropFirst() {
        let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if next < 0 { close(fd); throw systemError("Open path component \(component)") }
        close(fd); fd = next
    }
    return fd
}

private func readRequirement(_ root: Int32, owner: uid_t) throws -> (Requirement, String) {
    let data = try fileBytes(root, "canonical-reader.json", owner: owner, max: 16384)
    let object = try JSONSerialization.jsonObject(with: data)
    guard let values = object as? [String: Any],
          Set(values.keys) == ["profile", "storeID", "minimumReaderLevel", "recordFormats", "capabilities"]
    else { throw Failure("Unsupported canonical reader metadata") }
    let value = try JSONDecoder().decode(Requirement.self, from: data)
    try check(value.profile == "tractanda.canonical-reader.v1" && PersonalRevisionDescriptor.validID(value.storeID) &&
              (16...20).contains(value.minimumReaderLevel) && !value.recordFormats.isEmpty &&
              value.recordFormats == Array(Set(value.recordFormats)).sorted() &&
              Set(value.recordFormats).isSubset(of: Set([1, 2])) &&
              value.capabilities == Array(Set(value.capabilities)).sorted() &&
              value.capabilities.contains("tractanda.personal-workgroup.v1"),
              "Store is not a supported personal/workgroup reader")
    return (value, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
}

private func verifyPersonal(_ root: Int32, owner: uid_t, storeID: String) throws -> (String, String) {
    for name in [".tractanda-first-source.json", ".tractanda-first-source-complete.json",
                 ".tractanda-personal-profile.pending.json", ".personal-membership.pending.json",
                 ".tractanda-maintenance-pending.json"] {
        try check(try metadata(root, name) == nil,
                  "Unsupported pending or historical bootstrap state \(name); complete or recover using 16.2")
    }
    let bytes = try fileBytes(root, ".tractanda-personal-profile.json", owner: owner)
    guard let profile = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
          profile["profile"] as? String == "tractanda.personal-workgroup.v1",
          profile["storeID"] as? String == storeID,
          let replica = profile["replicaID"] as? String, PersonalRevisionDescriptor.validID(replica)
    else { throw Failure("Store is not an established personal/workgroup replica") }
    try entries(root) { name in
        try check(!(name.hasPrefix(".physical-layout-") && name.hasSuffix(".stage")),
                  "Unknown newer-layout marker stage blocks this 16.2 bridge")
    }
    if try metadata(root, "authority") != nil {
        let authority = try directory(root, "authority", owner: owner); defer { close(authority) }
        if try metadata(authority, "locators") != nil {
            let locators = try directory(authority, "locators", owner: owner); defer { close(locators) }
            var populated = false
            try entries(locators) { _ in populated = true }
            try check(!populated, "Retained historical authority locators require 16.2 recovery")
        }
    }
    return (replica, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
}

private func inspectStore(_ path: String, journalDirectory: String?) throws -> Data {
    let root = try openAbsolute(path); defer { close(root) }
    var rootStat = stat()
    guard fstat(root, &rootStat) == 0 else { throw systemError("Stat store") }
    let owner = rootStat.st_uid
    try check(rootStat.st_mode & 0o077 == 0, "Store root is not private")
    let (requirement, digest) = try readRequirement(root, owner: owner)
    if try metadata(root, completeName) != nil && metadata(root, pendingName) == nil {
        let marker = try fileBytes(root, completeName, owner: owner, max: 4096)
        let object = try JSONSerialization.jsonObject(with: marker) as? [String: String]
        try check(object == ["profile": "tractanda.physical-layout.v1",
                             "layout": "flat-items-visible-attachments.v1", "recordEncoding": "message-v1"] &&
                  requirement.minimumReaderLevel == 20 && requirement.capabilities.contains(capability) &&
                  requirement.capabilities.contains(messageCapability), "Completed layout marker or reader fence differs")
        let bytes = try fileBytes(root, ".tractanda-personal-profile.json", owner: owner)
        guard let profile = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              profile["profile"] as? String == "tractanda.personal-workgroup.v1",
              profile["storeID"] as? String == requirement.storeID,
              let replica = profile["replicaID"] as? String, PersonalRevisionDescriptor.validID(replica) else {
            throw Failure("Completed store profile differs from its reader requirement")
        }
        var result: [String: Any] = ["profile": "tractanda.layout17-inspection.v1",
            "storeID": requirement.storeID, "replicaID": replica, "readerRequirementSHA256": digest,
            "currentReaderRequirementSHA256": digest, "minimumReaderLevel": requirement.minimumReaderLevel,
            "phase": "complete", "clustered": false]
        if try metadata(root, ".personal-membership.json") != nil {
            let membership = try fileBytes(root, ".personal-membership.json", owner: owner, max: 131072)
            let value = try JSON.decode(PersonalMembershipConfiguration.self, membership)
            try value.validate()
            try check(value.storeID == requirement.storeID && value.members.contains(where: { $0.replicaID == replica }),
                      "Completed store membership differs from its identity")
            result["clustered"] = value.members.count > 1
            result["membershipDigest"] = SHA256.hash(data: membership).map { String(format: "%02x", $0) }.joined()
            result["memberCount"] = value.members.count
        }
        return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    let personal = try verifyPersonal(root, owner: owner, storeID: requirement.storeID)
    let replicaID = personal.0
    var priorJournal: Journal?
    if let journalDirectory {
        try check(!journalDirectory.hasPrefix(path + "/") && !path.hasPrefix(journalDirectory + "/") &&
                  path != journalDirectory, "Journal must be outside the store")
        let journalFD = try openAbsolute(journalDirectory); defer { close(journalFD) }
        var info = stat()
        guard fstat(journalFD, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            throw Failure("External journal directory is not private")
        }
        let name = "layout17-" + requirement.storeID + "-" + replicaID + ".json"
        if try metadata(journalFD, name) != nil {
            let bytes = try fileBytes(journalFD, name, owner: geteuid(), max: 512 * 1024)
            let value = try JSONDecoder().decode(Journal.self, from: bytes)
            try check(bytes == encoder.encode(value) && value.profile == "tractanda.layout17-journal.v1" &&
                      value.storeID == requirement.storeID && value.replicaID == replicaID &&
                      value.originalPersonalProfileSHA256 == personal.1 &&
                      value.originalRequirement.storeID == requirement.storeID &&
                      ["prepared", "moving", "complete"].contains(value.phase), "Invalid bridge journal")
            var raised = value.originalRequirement
            raised.minimumReaderLevel = 20
            raised.capabilities = Array(Set(raised.capabilities + [capability, messageCapability])).sorted()
            try check((requirement == value.originalRequirement && digest == value.originalRequirementSHA256) ||
                      requirement == raised, "Reader requirement differs from bridge journal")
            if try metadata(root, pendingName) != nil {
                try check(try fileBytes(root, pendingName, owner: owner) == pendingBytes,
                          "Pending barrier differs from this operation")
            }
            if value.phase == "moving" {
                try check(try fileBytes(root, pendingName, owner: owner) == pendingBytes,
                          "Pending barrier differs from this operation")
            }
            if value.phase == "complete" { try check(try metadata(root, completeName) != nil, "Completion marker is absent") }
            priorJournal = value
        }
    }
    if priorJournal == nil {
        try check(requirement.minimumReaderLevel < 20 && !requirement.capabilities.contains(capability) &&
                  !requirement.capabilities.contains(messageCapability) &&
                  metadata(root, pendingName) == nil && metadata(root, completeName) == nil,
                  "Store is not an unmigrated 16.2 layout")
    }
    var result: [String: Any] = [
        "profile": "tractanda.layout17-inspection.v1", "storeID": requirement.storeID,
        "replicaID": replicaID, "readerRequirementSHA256": priorJournal?.originalRequirementSHA256 ?? digest,
        "currentReaderRequirementSHA256": digest, "phase": priorJournal?.phase ?? "unmigrated",
        "minimumReaderLevel": requirement.minimumReaderLevel, "clustered": false,
    ]
    if try metadata(root, ".personal-membership.json") != nil {
        let membership = try fileBytes(root, ".personal-membership.json", owner: owner, max: 131072)
        guard let value = try JSONSerialization.jsonObject(with: membership) as? [String: Any],
              value["profile"] as? String == "tractanda.personal-membership.v1",
              value["storeID"] as? String == requirement.storeID,
              let members = value["members"] as? [[String: Any]], (1...256).contains(members.count),
              members.contains(where: { $0["replicaID"] as? String == replicaID })
        else { throw Failure("Unsupported current membership") }
        result["clustered"] = members.count > 1
        result["membershipDigest"] = SHA256.hash(data: membership).map { String(format: "%02x", $0) }.joined()
        result["memberCount"] = members.count
    }
    // This snapshot can race an active writer; actual conversion repeats these checks
    // after the owning Setup transaction has stopped the writer and acquired its lock.
    if priorJournal == nil {
        let pending = try deepPreflight(root, owner: owner)
        result["pendingRevisionStages"] = pending.1
        result["retainedRevisionReviews"] = pending.2
    }
    return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])
}

/// Definitive post-stop inspection owns the same writer flock as an ordinary Store.
/// The earlier unlocked inspection is only an early, race-prone refusal.
private func inspectQuiescent(_ path: String, journalDirectory: String?) throws -> Data {
    let root = try openAbsolute(path); defer { close(root) }
    var rootInfo = stat()
    guard fstat(root, &rootInfo) == 0, rootInfo.st_mode & 0o077 == 0 else {
        throw Failure("Store root is not private")
    }
    let lock = openat(root, ".writer.lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    guard lock >= 0 else { throw systemError("Open writer lock") }
    defer { _ = flock(lock, LOCK_UN); close(lock) }
    var held = stat()
    guard fstat(lock, &held) == 0, (held.st_mode & S_IFMT) == S_IFREG,
          held.st_uid == rootInfo.st_uid, held.st_nlink == 1, held.st_mode & 0o7777 == 0o600,
          flock(lock, LOCK_EX | LOCK_NB) == 0, let named = try metadata(root, ".writer.lock"),
          named.st_dev == held.st_dev, named.st_ino == held.st_ino else {
        throw Failure("Store writer is running or its lock changed")
    }
    return try inspectStore(path, journalDirectory: journalDirectory)
}

private func syncUnlink(_ fd: Int32, _ name: String) throws {
    if unlinkat(fd, name, 0) != 0 && errno != ENOENT { throw systemError("Remove \(name)") }
    guard fsync(fd) == 0 else { throw systemError("Sync removed \(name)") }
}
private func validateIntent(_ path: String?, store: String, inspection: Data) throws {
    guard let info = try JSONSerialization.jsonObject(with: inspection) as? [String: Any],
          let clustered = info["clustered"] as? Bool else { throw Failure("Invalid store inspection") }
    guard clustered else { return }
    guard let path else { throw Failure("Clustered store requires administrator-coordinated maintenance intent") }
    let url = URL(fileURLWithPath: path)
    let parent = try openAbsolute(url.deletingLastPathComponent().path); defer { close(parent) }
    var intentOwner: uid_t = 0
#if LAYOUT17_PRIVATE_FIXTURE
    if ProcessInfo.processInfo.environment["LAYOUT17_TEST_INTENT_OWNER"] == "self" { intentOwner = geteuid() }
#endif
    var s = stat()
    guard fstat(parent, &s) == 0, s.st_uid == intentOwner, s.st_mode & 0o022 == 0 else {
        throw Failure("Maintenance intent directory is not root-controlled")
    }
    let bytes = try fileBytes(parent, url.lastPathComponent, owner: intentOwner)
    let intent = try JSONDecoder().decode(MaintenanceIntent.self, from: bytes)
    guard let keys = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
          Set(keys.keys) == ["profile", "mode", "instance", "storePath", "storeID", "replicaID",
                             "oldManifestSHA256", "newManifestSHA256", "membershipDigest",
                             "readerRequirementSHA256", "acknowledgedAllMembersUpgradedBeforeStart"]
    else { throw Failure("Unsupported maintenance intent fields") }
    let validDigest = { (value: String) in
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    try check(intent.profile == "tractanda.layout17-prepare.v1" && intent.mode == "administrator-coordinated" &&
              intent.acknowledgedAllMembersUpgradedBeforeStart && intent.storePath == store &&
              intent.storeID == info["storeID"] as? String && intent.replicaID == info["replicaID"] as? String &&
              intent.membershipDigest == info["membershipDigest"] as? String &&
              intent.readerRequirementSHA256 == info["readerRequirementSHA256"] as? String &&
              !intent.instance.isEmpty && validDigest(intent.oldManifestSHA256) && validDigest(intent.newManifestSHA256),
              "Maintenance intent differs from the current cluster/store")
}
private func requireSpace(_ fd: Int32, bytes: UInt64) throws {
    var value = statvfs()
    guard fstatvfs(fd, &value) == 0 else { throw systemError("Inspect available filesystem space") }
    let (available, overflow) = UInt64(value.f_bavail).multipliedReportingOverflow(by: UInt64(value.f_frsize))
    try check(!overflow && available >= bytes, "Insufficient space for the selected candidate file")
}

private func candidateParent(_ root: Int32, _ parts: [String], create: Bool) throws -> Int32 {
    var fd = openat(root, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw systemError("Open candidate root") }
    do {
        for part in parts {
            try check(!part.isEmpty && part != "." && part != ".." && !part.contains("/"), "Invalid candidate path")
            if create && mkdirat(fd, part, 0o700) != 0 && errno != EEXIST { throw systemError("Create candidate directory") }
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw systemError("Open candidate directory") }
            var value = stat()
            guard fstat(next, &value) == 0, (value.st_mode & S_IFMT) == S_IFDIR,
                  !create || (value.st_uid == geteuid() && value.st_mode & 0o077 == 0) else {
                close(next); throw Failure("Candidate directory has unsafe custody")
            }
            close(fd); fd = next
        }
        return fd
    } catch { close(fd); throw error }
}
private func candidateBytes(_ root: Int32, name: String, maximum: Int) throws -> Data {
    let fd = openat(root, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw systemError("Open candidate manifest") }
    defer { close(fd) }
    var before = stat()
    guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG, before.st_nlink == 1,
          before.st_size > 0 && before.st_size <= maximum else { throw Failure("Unsafe candidate manifest") }
    var bytes = Data(count: Int(before.st_size))
    try bytes.withUnsafeMutableBytes { raw in
        var offset = 0
        while offset < raw.count {
            let n = read(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw systemError("Read candidate manifest") }
            offset += n
        }
    }
    var after = stat()
    try check(fstat(fd, &after) == 0 && before.st_dev == after.st_dev &&
              before.st_ino == after.st_ino && before.st_size == after.st_size,
              "Candidate manifest changed while reading")
    return bytes
}
private func copyCandidateFile(_ file: CandidateManifest.File, source: Int32, destination: Int32) throws {
    let parts = file.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    try check(!parts.isEmpty && parts.count <= 64 && parts.allSatisfy({
        !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 && !$0.contains("\0")
    }), "Invalid candidate entry")
    let a = try candidateParent(source, Array(parts.dropLast()), create: false); defer { close(a) }
    let b = try candidateParent(destination, Array(parts.dropLast()), create: true); defer { close(b) }
    let input = openat(a, parts.last!, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard input >= 0 else { throw systemError("Open candidate file") }
    defer { close(input) }
    var before = stat()
    guard fstat(input, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG, before.st_nlink == 1,
          before.st_size >= 0, UInt64(before.st_size) == file.size,
          before.st_mode & 0o777 == mode_t(file.mode), file.mode & 0o022 == 0,
          file.size <= 8 * 1024 * 1024 * 1024 else { throw Failure("Unsafe candidate file metadata") }
    let output = openat(b, parts.last!, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard output >= 0 else { throw systemError("Create staged candidate file") }
    defer { close(output) }
    var hash = SHA256()
    var total: UInt64 = 0
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(input, &buffer, buffer.count)
        if n < 0 && errno == EINTR { continue }
        guard n >= 0 else { throw systemError("Read candidate file") }
        if n == 0 { break }
        hash.update(data: Data(buffer.prefix(n)))
        total += UInt64(n)
        try buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset < n {
                let written = write(output, raw.baseAddress!.advanced(by: offset), n - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw systemError("Write candidate file") }
                offset += written
            }
        }
    }
    var after = stat()
    let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
    try check(fstat(input, &after) == 0 && before.st_dev == after.st_dev && before.st_ino == after.st_ino &&
              before.st_size == after.st_size && total == file.size && digest == file.sha256,
              "Candidate file differs from its manifest")
    guard fchmod(output, mode_t(file.mode)) == 0, durableSync(output) == 0 else {
        throw systemError("Finalize staged candidate file")
    }
    let staged = try hashFile(b, parts.last!, owner: geteuid())
    try check(staged.0 == file.sha256 && staged.1 == file.size, "Staged candidate verification failed")
}
private func callSetup(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"]
    try process.run()
    process.waitUntilExit()
    try check(process.terminationReason == .exit && process.terminationStatus == 0,
              "The authenticated Setup operation did not complete")
}
private func validInstance(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    return (1...32).contains(bytes.count) && bytes.first != 45 && bytes.last != 45 &&
        bytes.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
}
private func withStagedCandidate(bundle: String, stageParent: String, action: (String) throws -> Void) throws {
    let source = try openAbsolute(bundle); defer { close(source) }
    let manifestBytes = try candidateBytes(source, name: "bundle-manifest.json", maximum: 4 * 1024 * 1024)
    let manifest = try JSONDecoder().decode(CandidateManifest.self, from: manifestBytes)
#if canImport(Darwin)
    let platform = "macos"
#else
    let platform = "linux"
#endif
#if arch(arm64)
    let architecture = "arm64"
#else
    let architecture = "x86_64"
#endif
    try check(manifest.profile == "tractanda.bundle.v1" && manifest.version == "0.1.0-poc.17" &&
              manifest.platform == platform && manifest.arch == architecture &&
              !manifest.files.isEmpty && manifest.files.count <= 20000,
              "Candidate is not the selected .17 platform bundle")
    var paths = Set<String>()
    for file in manifest.files {
        try check(paths.insert(file.path.precomposedStringWithCanonicalMapping.lowercased()).inserted &&
                  file.sha256.utf8.count == 64 && file.sha256.utf8.allSatisfy({
                      (48...57).contains($0) || (97...102).contains($0)
                  }) && file.mode & ~0o777 == 0 && file.mode & 0o022 == 0,
                  "Invalid or duplicate candidate inventory")
    }
    try check(manifest.files.contains(where: { $0.path == "bin/tractanda-setup" && $0.mode & 0o111 != 0 }),
              "Candidate Setup executable is absent")
    let parent = try openAbsolute(stageParent); defer { close(parent) }
    var parentInfo = stat()
    try check(fstat(parent, &parentInfo) == 0 && parentInfo.st_uid == geteuid() && parentInfo.st_mode & 0o022 == 0,
              "Installation stage parent is not controlled by the invoking account")
    var template = Array((stageParent + "/.layout17-prepare-XXXXXX").utf8CString)
    guard let raw = mkdtemp(&template) else { throw systemError("Create protected candidate stage") }
    let stage = String(cString: raw)
    defer { try? FileManager.default.removeItem(atPath: stage) }
    let target = try openAbsolute(stage); defer { close(target) }
    for file in manifest.files {
        try requireSpace(target, bytes: file.size)
        try copyCandidateFile(file, source: source, destination: target)
    }
    try atomicWrite(target, "bundle-manifest.json", manifestBytes, owner: geteuid(), replacing: false)
    try action(stage)
}
private func prepare(instance: String, bundle: String) throws {
    try check(geteuid() == 0 && validInstance(instance), "Preparation requires root and a valid instance")
#if canImport(Darwin)
    let stageParent = "/Library/Tractanda/Installation"
#else
    let stageParent = "/opt/tractanda/var/lib/tractanda/Installation"
#endif
    try withStagedCandidate(bundle: bundle, stageParent: stageParent) { stage in
        try callSetup(stage + "/bin/tractanda-setup", ["--layout17-prepare", "--instance", instance,
                                                           "--bundle", stage, "--coordinated-maintenance"])
    }
}
private func complete(instance: String) throws {
    try check(geteuid() == 0 && validInstance(instance), "Completion requires root and a valid instance")
#if canImport(Darwin)
    let selected = "/Library/Tractanda/Software/current/bin/tractanda-setup"
#else
    let selected = "/opt/tractanda/current/bin/tractanda-setup"
#endif
    let resolved = URL(fileURLWithPath: selected).resolvingSymlinksInPath().path
#if canImport(Darwin)
    try check(resolved.hasPrefix("/Library/Tractanda/Software/releases/") && resolved.hasSuffix("/bin/tractanda-setup"),
              "Installed Setup resolves outside owned releases")
#else
    try check(resolved == "/opt/tractanda/current/bin/tractanda-setup",
              "Installed Setup resolves outside the dpkg payload")
#endif
    let url = URL(fileURLWithPath: resolved)
    let parent = try openAbsolute(url.deletingLastPathComponent().path); defer { close(parent) }
    guard let value = try metadata(parent, url.lastPathComponent), (value.st_mode & S_IFMT) == S_IFREG,
          value.st_uid == 0, value.st_nlink == 1, value.st_mode & 0o022 == 0,
          value.st_mode & 0o111 != 0 else { throw Failure("Installed Setup executable has unsafe custody") }
    let bundle = try openAbsolute(url.deletingLastPathComponent().deletingLastPathComponent().path)
    defer { close(bundle) }
    guard let manifestMeta = try metadata(bundle, "bundle-manifest.json"), manifestMeta.st_uid == 0,
          manifestMeta.st_mode & 0o022 == 0 else { throw Failure("Installed manifest has unsafe custody") }
    let manifest = try JSONDecoder().decode(CandidateManifest.self,
        from: candidateBytes(bundle, name: "bundle-manifest.json", maximum: 4 * 1024 * 1024))
    guard manifest.profile == "tractanda.bundle.v1", manifest.version == "0.1.0-poc.17",
          let entry = manifest.files.first(where: { $0.path == "bin/tractanda-setup" }),
          manifest.files.filter({ $0.path == "bin/tractanda-setup" }).count == 1 else {
        throw Failure("Installed bundle is not the .17 bridge")
    }
    let installed = try hashFile(parent, url.lastPathComponent, owner: 0)
    try check(installed.0 == entry.sha256 && installed.1 == entry.size &&
              value.st_mode & 0o777 == mode_t(entry.mode), "Installed Setup differs from its manifest")
    try callSetup(resolved, ["--layout17-complete", "--instance", instance, "--all-members-upgraded"])
}

private func runBridge(store: String, journalDirectory: String, intent: String? = nil) throws {
    try check(!journalDirectory.hasPrefix(store + "/") && !store.hasPrefix(journalDirectory + "/") &&
              store != journalDirectory, "External journal must be outside the canonical store")
    let root = try openAbsolute(store); defer { close(root) }
    var rootStat = stat()
    guard fstat(root, &rootStat) == 0 else { throw systemError("Stat store") }
    let owner = rootStat.st_uid
    try check(rootStat.st_mode & 0o077 == 0, "Store root is not private")
    let lock = openat(root, ".writer.lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    guard lock >= 0 else { throw systemError("Open writer lock") }
    defer { _ = flock(lock, LOCK_UN); close(lock) }
    var lockStat = stat()
    guard fstat(lock, &lockStat) == 0, (lockStat.st_mode & S_IFMT) == S_IFREG,
          lockStat.st_uid == owner, lockStat.st_nlink == 1, lockStat.st_mode & 0o7777 == 0o600,
          flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw Failure("Store writer is running or lock is unsafe") }
    guard let named = try metadata(root, ".writer.lock"), named.st_dev == lockStat.st_dev,
          named.st_ino == lockStat.st_ino else { throw Failure("Writer lock identity changed") }
    if try metadata(root, completeName) != nil && metadata(root, pendingName) == nil {
        let marker = try fileBytes(root, completeName, owner: owner, max: 4096)
        let object = try JSONSerialization.jsonObject(with: marker) as? [String: String]
        let requirement = try readRequirement(root, owner: owner).0
        try check(object == ["profile": "tractanda.physical-layout.v1",
                             "layout": "flat-items-visible-attachments.v1", "recordEncoding": "message-v1"] &&
                  requirement.minimumReaderLevel == 20 && requirement.capabilities.contains(capability) &&
                  requirement.capabilities.contains(messageCapability), "Completed layout marker or reader fence differs")
        return  // No snapshot/digest check after writers may legitimately have resumed.
    }
    let journalFD = try openAbsolute(journalDirectory); defer { close(journalFD) }
    var journalStat = stat()
    guard fstat(journalFD, &journalStat) == 0, journalStat.st_uid == geteuid(),
          journalStat.st_mode & 0o077 == 0 else { throw Failure("External journal directory is not private") }
    try check(journalStat.st_dev != rootStat.st_dev || journalStat.st_ino != rootStat.st_ino,
              "External journal aliases the canonical store")
    try validateIntent(intent, store: store, inspection: inspectStore(store, journalDirectory: journalDirectory))
    var (requirement, requirementDigest) = try readRequirement(root, owner: owner)
    let personal = try verifyPersonal(root, owner: owner, storeID: requirement.storeID)
    let journalName = "layout17-" + requirement.storeID + "-" + personal.0 + ".json"
    var journal: Journal
    if try metadata(journalFD, journalName) != nil {
        let bytes = try fileBytes(journalFD, journalName, owner: geteuid(), max: 512 * 1024)
        journal = try JSONDecoder().decode(Journal.self, from: bytes)
        try check(journal.profile == "tractanda.layout17-journal.v1" &&
                  journal.storeID == requirement.storeID && journal.originalRequirement.storeID == requirement.storeID &&
                  journal.replicaID == personal.0 && journal.originalPersonalProfileSHA256 == personal.1 &&
                  journal.originalRequirementSHA256.utf8.count == 64 &&
                  ["prepared", "moving", "complete"].contains(journal.phase),
                  "External journal does not bind this operation")
    } else {
        try check(try metadata(root, pendingName) == nil && metadata(root, completeName) == nil,
                  "Existing layout state requires an exact bridge journal")
        try check(requirement.minimumReaderLevel < 20 && !requirement.capabilities.contains(capability) &&
                  !requirement.capabilities.contains(messageCapability),
                  "Unexpected existing layout requirement")
        _ = try deepPreflight(root, owner: owner)
        journal = Journal(profile: "tractanda.layout17-journal.v1", storeID: requirement.storeID,
                          replicaID: personal.0, originalPersonalProfileSHA256: personal.1,
                          originalRequirement: requirement, originalRequirementSHA256: requirementDigest,
                          phase: "prepared", move: nil, completedDigest: nil)
        try atomicWrite(journalFD, journalName, encoder.encode(journal), owner: geteuid(), replacing: false)
        boundary("prepared")
    }
    var raised = journal.originalRequirement
    raised.minimumReaderLevel = 20
    raised.capabilities = Array(Set(raised.capabilities + [capability, messageCapability])).sorted()
    try check((requirement == journal.originalRequirement && requirementDigest == journal.originalRequirementSHA256) ||
              requirement == raised, "Current reader requirement differs from the pinned transition")
    func save() throws { try atomicWrite(journalFD, journalName, encoder.encode(journal), owner: geteuid(), replacing: true) }
    if journal.phase == "prepared" {
        _ = try deepPreflight(root, owner: owner)
        if try metadata(root, pendingName) == nil {
            try atomicWrite(root, pendingName, pendingBytes, owner: owner, replacing: false)
        } else {
            try check(try fileBytes(root, pendingName, owner: owner) == pendingBytes,
                      "Pending barrier differs from this operation")
        }
        boundary("pending")
        if requirement.minimumReaderLevel < 20 {
            requirement = raised
            try atomicWrite(root, "canonical-reader.json", encoder.encode(requirement), owner: owner, replacing: true)
        }
        boundary("fence")
        try check(requirement.capabilities.contains(capability) && requirement.capabilities.contains(messageCapability),
                  "Reader layout and message-encoding fence is absent")
        if try metadata(root, ".tractanda-checkpoint-dirty") == nil {
            try atomicWrite(root, ".tractanda-checkpoint-dirty", Data("dirty-v1\n".utf8), owner: owner, replacing: false)
        } else {
            _ = try fileBytes(root, ".tractanda-checkpoint-dirty", owner: owner, max: 128)
        }
        boundary("dirty")
        journal.phase = "moving"; try save()
        boundary("moving")
    }
    try check(requirement.minimumReaderLevel == 20 && requirement.capabilities.contains(capability) &&
              requirement.capabilities.contains(messageCapability), "Reader layout and message-encoding fence is absent")
    if journal.phase == "moving" {
        try check(try fileBytes(root, pendingName, owner: owner) == pendingBytes,
                  "Pending barrier differs from this operation")
        try check([journal.move != nil, journal.stageMove != nil, journal.reviewMove != nil].filter { $0 }.count <= 1,
                  "Journal contains overlapping migration operations")
        if let pending = journal.move { try perform(pending, root: root, owner: owner); journal.move = nil; try save() }
        if let pending = journal.stageMove {
            try performStageTransition(pending, root: root, owner: owner)
            journal.stageMove = nil; try save()
        }
        if let pending = journal.reviewMove {
            try performReviewTransition(pending, root: root, owner: owner)
            journal.reviewMove = nil; try save()
        }
        func move(_ planned: Move) throws {
            journal.move = planned; try save()
            boundary("move-intent")
            try perform(planned, root: root, owner: owner)
            boundary("move-completed")
            journal.move = nil; try save()
            boundary("move-cleared")
        }
        let work = try deepPreflight(root, owner: owner, allowMixed: true, queue: true).0
        while let (sequence, bytes) = try work.nextWork() {
            let item = try JSON.decode(WorkItem.self, bytes)
            switch item.kind {
            case "stage":
                guard let planned = item.stage, item.revision == nil, item.directory == nil else {
                    throw Failure("Invalid staged-revision work item")
                }
                journal.stageMove = planned; try save()
                boundary("stage-intent")
                try performStageTransition(planned, root: root, owner: owner)
                journal.stageMove = nil; try save()
                boundary("stage-cleared")
            case "revision":
                guard let planned = item.revision, let mode = planned.originalMode,
                      item.stage == nil, item.directory == nil else {
                    throw Failure("Invalid revision work item")
                }
                let parent = try parentDirectory(root, Array(planned.source.dropLast()), owner: owner)
                defer { close(parent) }
                let (old, _) = try readBoundedRecord(parent, planned.source.last!, owner: owner,
                                                     expectedMode: mode_t(mode), allowHardlinks: true)
                let revision = try LegacyRecordCodec.decode(old)
                let new = try convertLegacyRecord(old, item: revision.itemID, revision: revision.revisionID)
                if let review = try planCanonicalReview(root, owner: owner, revision: revision, oldBytes: old, newBytes: new) {
                    journal.reviewMove = review; try save()
                    boundary("review-intent")
                    try performReviewTransition(review, root: root, owner: owner)
                    journal.reviewMove = nil; try save()
                    boundary("review-cleared")
                }
                try move(planned)
            case "directory":
                guard let path = item.directory, item.stage == nil, item.revision == nil,
                      path.count == 7, path.first == "items", validID(path[6]) else {
                    throw Failure("Invalid empty-directory work item")
                }
                let parent = try parentDirectory(root, Array(path.dropLast()), owner: owner)
                defer { close(parent) }
                if unlinkat(parent, path[6], AT_REMOVEDIR) != 0 && errno != ENOENT {
                    throw systemError("Remove empty legacy item directory")
                }
                guard fsync(parent) == 0 else { throw systemError("Sync item minute directory") }
            default:
                throw Failure("Unknown migration work item")
            }
            try work.removeWork(sequence)
        }
        try attachmentTree(root, owner: owner, allowMoved: true, move: move)
        try itemTree(root, owner: owner, allowFlat: true, requireFlat: true, move: nil)
        try attachmentTree(root, owner: owner, allowMoved: true, requireMoved: true, move: nil)
        try validateConvertedPersonal(root, owner: owner)
        if try metadata(root, completeName) == nil {
            try atomicWrite(root, completeName, encoder.encode(Marker()), owner: owner, replacing: false)
        } else {
            let bytes = try fileBytes(root, completeName, owner: owner)
            try check(bytes == encoder.encode(Marker()), "Layout completion marker differs")
        }
        boundary("completion-marker")
        journal.completedDigest = try completedDigest(root, owner: owner)
        journal.phase = "complete"; try save()
        boundary("journal-complete")
    }
    try check(journal.phase == "complete" && journal.move == nil && journal.stageMove == nil &&
              journal.reviewMove == nil, "Layout journal did not complete")
    try check(try fileBytes(root, completeName, owner: owner) == encoder.encode(Marker()), "Completion marker differs")
    try itemTree(root, owner: owner, allowFlat: true, requireFlat: true, move: nil)
    try attachmentTree(root, owner: owner, allowMoved: true, requireMoved: true, move: nil)
    try validateConvertedPersonal(root, owner: owner)
    try check(journal.completedDigest != nil && journal.completedDigest == completedDigest(root, owner: owner),
              "Completed layout content differs from its journal commitment")
    if try metadata(root, pendingName) != nil {
        try check(try fileBytes(root, pendingName, owner: owner) == pendingBytes,
                  "Pending barrier differs from this operation")
    }
    try syncUnlink(root, pendingName)
    boundary("pending-removed")
}
#if LAYOUT17_PRIVATE_FIXTURE
do {
    if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "record-fixture" {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
        if CommandLine.arguments[2] == "legacy-write" {
            let revision = try MessageRecordCodec.decode(bytes)
            FileHandle.standardOutput.write(try LegacyRecordCodec.encodeFixture(revision))
            exit(0)
        }
        let revision: Revision
        if CommandLine.arguments[2] == "legacy" { revision = try LegacyRecordCodec.decode(bytes) }
        else if CommandLine.arguments[2] == "message" { revision = try MessageRecordCodec.decode(bytes) }
        else { throw Failure("Unknown fixture encoding") }
        FileHandle.standardOutput.write(try JSON.encode(revision))
    } else if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "peer-descriptor-fixture" {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        let descriptor = try JSON.decode(PersonalObjectDescriptor.self, bytes)
        try descriptor.validate()
        print(digest(try JSON.encode(descriptor)))
    } else if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "descriptor-fixture" {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        let object = try JSONSerialization.jsonObject(with: bytes)
        print(try PersonalRevisionDescriptor.decode(object).key)
    } else if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "stage-fixture" {
        try withStagedCandidate(bundle: CommandLine.arguments[2], stageParent: CommandLine.arguments[3]) { stage in
            try check(FileManager.default.isExecutableFile(atPath: stage + "/bin/tractanda-setup"),
                      "Staged Setup is not executable")
        }
        print("Layout17 private candidate stage verified")
    } else {
        guard CommandLine.arguments.count == 3 ||
                (CommandLine.arguments.count == 5 && CommandLine.arguments[3] == "--intent") else {
            throw Failure("Expected STORE JOURNAL-DIRECTORY [--intent ABS]")
        }
        try runBridge(store: CommandLine.arguments[1], journalDirectory: CommandLine.arguments[2],
                      intent: CommandLine.arguments.count == 5 ? CommandLine.arguments[4] : nil)
        print("Layout17 private conversion completed")
    }
} catch {
    FileHandle.standardError.write(Data("tractanda-layout17: \(error)\n".utf8))
    exit(1)
}
#else
do {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.count == 3 && args[0] == "inspect" && args[1] == "--store" {
        let data = try inspectStore(args[2], journalDirectory: nil)
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    } else if args.count == 5 && args[0] == "inspect" && args[1] == "--store" && args[3] == "--journal-directory" {
        let data = try inspectStore(args[2], journalDirectory: args[4])
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    } else if args.count == 4 && args[0] == "inspect" && args[1] == "--store" && args[3] == "--quiescent" {
        let data = try inspectQuiescent(args[2], journalDirectory: nil)
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    } else if args.count == 6 && args[0] == "inspect" && args[1] == "--store" &&
                args[3] == "--journal-directory" && args[5] == "--quiescent" {
        let data = try inspectQuiescent(args[2], journalDirectory: args[4])
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    } else if (args.count == 5 || args.count == 7) && args[0] == "migrate" &&
                args[1] == "--store" && args[3] == "--journal-directory" &&
                (args.count == 5 || args[5] == "--intent") {
        try runBridge(store: args[2], journalDirectory: args[4], intent: args.count == 7 ? args[6] : nil)
        print("Layout17 bridge completed or already marked complete.")
    } else if args.count == 6 && args[0] == "prepare" && args[1] == "--instance" &&
                args[3] == "--bundle" && args[5] == "--coordinated-maintenance" {
        try prepare(instance: args[2], bundle: args[4])
    } else if args.count == 4 && args[0] == "complete" && args[1] == "--instance" &&
                args[3] == "--all-members-upgraded" {
        try complete(instance: args[2])
    } else {
        throw Failure("Use inspect, migrate, prepare --instance NAME --bundle ABS --coordinated-maintenance, or complete --instance NAME --all-members-upgraded.")
    }
} catch {
    FileHandle.standardError.write(Data("tractanda-layout17: \(error)\n".utf8))
    exit(1)
}
#endif
