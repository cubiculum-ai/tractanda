import Foundation
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

private struct Marker: Encodable { let profile = "tractanda.physical-layout.v1"; let layout = "flat-items-visible-attachments.v1" }
private struct Move: Codable {
    let kind: String
    let source: [String]
    let destination: [String]
    let contentSHA256: String
    let byteCount: UInt64
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
    return name[name.index(name.startIndex, offsetBy: 14)] == "1"
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
private func verifyItemHeader(_ dir: Int32, _ name: String, item: String, revision: String) throws {
    let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw systemError("Open item envelope") }
    defer { close(fd) }
    var bytes = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    let separator = Data("\r\n\r\n".utf8)
    while bytes.count < 65536 && bytes.range(of: separator) == nil {
        let n = read(fd, &buffer, buffer.count)
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else { throw Failure("Incomplete item MIME envelope") }
        bytes.append(contentsOf: buffer.prefix(n))
    }
    guard let split = bytes.range(of: separator),
          let header = String(data: bytes[..<split.lowerBound], encoding: .utf8) else {
        throw Failure("Invalid item MIME envelope")
    }
    var fields: [String: String] = [:]
    for line in header.components(separatedBy: "\r\n") {
        guard let colon = line.firstIndex(of: ":") else { throw Failure("Malformed MIME header") }
        let key = line[..<colon].lowercased()
        try check(fields[key] == nil, "Duplicate MIME header")
        fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    try check(fields["mime-version"] == "1.0" && fields["x-item-id"] == item &&
              fields["x-revision-id"] == revision && fields["x-isa"]?.isEmpty == false &&
              ["1", "2"].contains(fields["x-tractanda-format-version"] ?? "") &&
              fields["content-type"] == "application/vnd.tractanda.item+json; charset=utf-8",
              "Item envelope identities differ from its path")
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
    if move.kind == "file" {
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

private func itemTree(_ root: Int32, owner: uid_t, allowFlat: Bool, requireFlat: Bool = false,
                      move: ((Move) throws -> Void)?,
                      onFlat: (([String], String, UInt64, mode_t) throws -> Void)? = nil) throws {
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
                try verifyItemHeader(fd, name, item: pieces[0], revision: pieces[1])
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
                try verifyItemHeader(itemDir, revisionName, item: name, revision: pieces[0])
                let target = name + "." + revisionName
                let targetMeta = try metadata(fd, target)
                let sourceMeta = try metadata(itemDir, revisionName)
                try check(sourceMeta != nil, "Revision disappeared")
                if let targetMeta {
                    try check(allowFlat && targetMeta.st_dev == sourceMeta!.st_dev &&
                              targetMeta.st_ino == sourceMeta!.st_ino, "Item destination collision")
                }
                let digest = try hashFile(itemDir, revisionName, owner: owner)
                if let move {
                    try move(Move(kind: "file", source: ["items"] + parts + [name, revisionName],
                                  destination: ["items"] + parts + [target],
                                  contentSHA256: digest.0, byteCount: digest.1))
                }
            }
            if move != nil {
                if unlinkat(fd, name, AT_REMOVEDIR) != 0 && errno != ENOTEMPTY {
                    throw systemError("Remove empty item directory")
                }
                guard fsync(fd) == 0 else { throw systemError("Sync item minute") }
            }
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
    try itemTree(root, owner: owner, allowFlat: true, requireFlat: true, move: nil) { path, hash, size, mode in
        add("item\0\(path.joined(separator: "/"))\0\(size)\0\(mode)\0\(hash)")
    }
    if try metadata(root, "attachments") != nil {
        let attachments = try directory(root, "attachments", owner: owner); defer { close(attachments) }
        for name in ["staging", "placements"] {
            if try metadata(attachments, name) != nil {
                let digest = try directoryDigest(attachments, name, owner: owner)
                add("attachment-directory\0\(name)\0\(digest.1)\0\(digest.0)")
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
    try check(value.profile == "tractanda.canonical-reader.v1" && validID(value.storeID) &&
              (16...19).contains(value.minimumReaderLevel) && !value.recordFormats.isEmpty &&
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
          let replica = profile["replicaID"] as? String, validID(replica)
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
            let bytes = try fileBytes(journalFD, name, owner: geteuid())
            let value = try JSONDecoder().decode(Journal.self, from: bytes)
            try check(bytes == encoder.encode(value) && value.profile == "tractanda.layout17-journal.v1" &&
                      value.storeID == requirement.storeID && value.replicaID == replicaID &&
                      value.originalPersonalProfileSHA256 == personal.1 &&
                      value.originalRequirement.storeID == requirement.storeID &&
                      ["prepared", "moving", "complete"].contains(value.phase), "Invalid bridge journal")
            var raised = value.originalRequirement
            raised.minimumReaderLevel = 19
            raised.capabilities = Array(Set(raised.capabilities + [capability])).sorted()
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
        try check(requirement.minimumReaderLevel < 19 && !requirement.capabilities.contains(capability) &&
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
        try itemTree(root, owner: owner, allowFlat: false, move: nil)
        try attachmentTree(root, owner: owner, allowMoved: false, move: nil)
    }
    return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])
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
    var s = stat()
    guard fstat(parent, &s) == 0, s.st_uid == 0, s.st_mode & 0o022 == 0 else {
        throw Failure("Maintenance intent directory is not root-controlled")
    }
    let bytes = try fileBytes(parent, url.lastPathComponent, owner: 0)
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
        let bytes = try fileBytes(journalFD, journalName, owner: geteuid())
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
        try check(requirement.minimumReaderLevel < 19 && !requirement.capabilities.contains(capability),
                  "Unexpected existing layout requirement")
        try itemTree(root, owner: owner, allowFlat: false, move: nil)
        try attachmentTree(root, owner: owner, allowMoved: false, move: nil)
        journal = Journal(profile: "tractanda.layout17-journal.v1", storeID: requirement.storeID,
                          replicaID: personal.0, originalPersonalProfileSHA256: personal.1,
                          originalRequirement: requirement, originalRequirementSHA256: requirementDigest,
                          phase: "prepared", move: nil, completedDigest: nil)
        try atomicWrite(journalFD, journalName, encoder.encode(journal), owner: geteuid(), replacing: false)
        boundary("prepared")
    }
    var raised = journal.originalRequirement
    raised.minimumReaderLevel = 19
    raised.capabilities = Array(Set(raised.capabilities + [capability])).sorted()
    try check((requirement == journal.originalRequirement && requirementDigest == journal.originalRequirementSHA256) ||
              requirement == raised, "Current reader requirement differs from the pinned transition")
    func save() throws { try atomicWrite(journalFD, journalName, encoder.encode(journal), owner: geteuid(), replacing: true) }
    if journal.phase == "prepared" {
        try itemTree(root, owner: owner, allowFlat: false, move: nil)
        try attachmentTree(root, owner: owner, allowMoved: false, move: nil)
        if try metadata(root, pendingName) == nil {
            try atomicWrite(root, pendingName, pendingBytes, owner: owner, replacing: false)
        } else {
            try check(try fileBytes(root, pendingName, owner: owner) == pendingBytes,
                      "Pending barrier differs from this operation")
        }
        boundary("pending")
        if requirement.minimumReaderLevel < 19 {
            requirement = raised
            try atomicWrite(root, "canonical-reader.json", encoder.encode(requirement), owner: owner, replacing: true)
        }
        boundary("fence")
        try check(requirement.capabilities.contains(capability), "Reader layout fence is absent")
        if try metadata(root, ".tractanda-checkpoint-dirty") == nil {
            try atomicWrite(root, ".tractanda-checkpoint-dirty", Data("dirty-v1\n".utf8), owner: owner, replacing: false)
        } else {
            _ = try fileBytes(root, ".tractanda-checkpoint-dirty", owner: owner, max: 128)
        }
        boundary("dirty")
        journal.phase = "moving"; try save()
        boundary("moving")
    }
    try check(requirement.minimumReaderLevel == 19 && requirement.capabilities.contains(capability),
              "Reader layout fence is absent")
    if journal.phase == "moving" {
        try check(try fileBytes(root, pendingName, owner: owner) == pendingBytes,
                  "Pending barrier differs from this operation")
        if let pending = journal.move { try perform(pending, root: root, owner: owner); journal.move = nil; try save() }
        func move(_ planned: Move) throws {
            journal.move = planned; try save()
            boundary("move-intent")
            try perform(planned, root: root, owner: owner)
            boundary("move-completed")
            journal.move = nil; try save()
            boundary("move-cleared")
        }
        try itemTree(root, owner: owner, allowFlat: true, move: move)
        try attachmentTree(root, owner: owner, allowMoved: true, move: move)
        try itemTree(root, owner: owner, allowFlat: true, requireFlat: true, move: nil)
        try attachmentTree(root, owner: owner, allowMoved: true, requireMoved: true, move: nil)
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
    try check(journal.phase == "complete" && journal.move == nil, "Layout journal did not complete")
    try check(try fileBytes(root, completeName, owner: owner) == encoder.encode(Marker()), "Completion marker differs")
    try itemTree(root, owner: owner, allowFlat: true, requireFlat: true, move: nil)
    try attachmentTree(root, owner: owner, allowMoved: true, requireMoved: true, move: nil)
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
    if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "stage-fixture" {
        try withStagedCandidate(bundle: CommandLine.arguments[2], stageParent: CommandLine.arguments[3]) { stage in
            try check(FileManager.default.isExecutableFile(atPath: stage + "/bin/tractanda-setup"),
                      "Staged Setup is not executable")
        }
        print("Layout17 private candidate stage verified")
    } else {
        guard CommandLine.arguments.count == 3 else { throw Failure("Expected STORE JOURNAL-DIRECTORY") }
        try runBridge(store: CommandLine.arguments[1], journalDirectory: CommandLine.arguments[2])
        print("Layout17 private conversion completed")
    }
} catch {
    fputs("tractanda-layout17: \(error)\n", stderr)
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
    } else if (args.count == 5 || args.count == 7) && args[0] == "migrate" &&
                args[1] == "--store" && args[3] == "--journal-directory" &&
                (args.count == 5 || args[5] == "--intent") {
        try runBridge(store: args[2], journalDirectory: args[4], intent: args.count == 7 ? args[6] : nil)
        print("Layout17 migration completed and verified.")
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
    fputs("tractanda-layout17: \(error)\n", stderr)
    exit(1)
}
#endif
