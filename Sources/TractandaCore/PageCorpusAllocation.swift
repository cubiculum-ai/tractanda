import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Physical allocations are separate from logical lengths used for hashes/addressing.
struct PageCorpusAllocationEntry: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case directory, regular, symbolicLink, other }
    let kind: Kind
    let device: UInt64
    let inode: UInt64
    let logicalBytes: Int64
    let allocatedBlocks: Int64?  // POSIX st_blocks, always in 512-byte units.
}

struct PageCorpusAllocationUsage: Equatable, Sendable {
    let logicalBytes: Int64
    let allocatedBytes: Int64
    let inodeCount: Int
}

/// A flat private SQLite stage: count the owned directory and every auxiliary entry, without
/// following links. At most64 auxiliary entries bounds metadata retention; SQLite needs <10.
enum PageCorpusAllocation {
    private struct Key: Hashable {
        let device: UInt64
        let inode: UInt64
    }
    struct Ledger {
        private var seen: [Key: PageCorpusAllocationEntry] = [:]
        private var logical: Int64 = 0
        private var allocated: Int64 = 0
        mutating func include(_ entry: PageCorpusAllocationEntry) throws {
            guard entry.kind == .directory || entry.kind == .regular, entry.inode > 0,
                entry.logicalBytes >= 0, let blocks = entry.allocatedBlocks, blocks >= 0
            else { throw failure("Corpus allocation is unsafe or unknown.") }
            let bytes = blocks.multipliedReportingOverflow(by: 512)
            guard !bytes.overflow else { throw failure("Corpus allocation overflowed.") }
            let key = Key(device: entry.device, inode: entry.inode)
            if let prior = seen[key] {
                guard prior == entry else {
                    throw failure("Corpus inode changed during allocation accounting.")
                }
                return
            }
            guard seen.count < 65 else { throw failure("Corpus stage has too many auxiliary allocations.") }
            allocated = try PageCorpusEmitter.add(allocated, bytes.partialValue)
            if entry.kind == .regular { logical = try PageCorpusEmitter.add(logical, entry.logicalBytes) }
            seen[key] = entry
        }
        var usage: PageCorpusAllocationUsage {
            PageCorpusAllocationUsage(
                logicalBytes: logical, allocatedBytes: allocated, inodeCount: seen.count)
        }
    }
    static func rounded(_ bytes: Int64, allocationUnit: Int64) throws -> Int64 {
        guard bytes >= 0, allocationUnit > 0 else { throw failure("Corpus allocation rounding is unknown.") }
        if bytes == 0 { return 0 }
        let padding = (allocationUnit - bytes % allocationUnit) % allocationUnit
        return try PageCorpusEmitter.add(bytes, padding)
    }
    static func check(
        _ usage: PageCorpusAllocationUsage, maximumBytes: Int64, additionalBytes: Int64,
        allocationUnit: Int64
    ) throws -> Int64 {
        let growth = try rounded(additionalBytes, allocationUnit: allocationUnit)
        // The filesystem value can be its maximum record/transfer size (Linux ZFS reports
        // that in both statvfs fields). It is a conservative reservation, not a minimum
        // physical charge for each write. Operator admission uses the bounded output
        // estimate; actual directory/file allocations are checked again after writes.
        let physical = try PageCorpusEmitter.add(usage.allocatedBytes, additionalBytes)
        let logical = try PageCorpusEmitter.add(usage.logicalBytes, additionalBytes)
        guard physical <= maximumBytes, logical <= maximumBytes else {
            throw failure("Corpus spool reached its physical or logical operator byte budget.")
        }
        return growth
    }
    static func allocationUnit(at directory: URL) throws -> Int64 {
        var capacity = statvfs()
        guard statvfs(directory.path, &capacity) == 0,
            capacity.f_frsize > 0, capacity.f_bsize > 0,
            let unit = Int64(exactly: max(capacity.f_frsize, capacity.f_bsize)), unit > 0
        else { throw failure("Cannot determine the corpus filesystem allocation unit.") }
        return unit
    }
    static func usage(at directory: URL) throws -> PageCorpusAllocationUsage {
        let root = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw failure("Cannot inspect private corpus allocation.") }
        defer { _ = close(root) }
        var rootMetadata = stat()
        guard fstat(root, &rootMetadata) == 0,
            rootMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        else { throw failure("Cannot inspect corpus directory allocation.") }
        var ledger = Ledger()
        try ledger.include(entry(rootMetadata))
        let listing = dup(root)
        guard listing >= 0 else { throw failure("Cannot list corpus allocations.") }
        guard let stream = fdopendir(listing) else {
            _ = close(listing)
            throw failure("Cannot list corpus allocations.")
        }
        defer { _ = closedir(stream) }
        var count = 0
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let next = readdir(stream) else {
                guard errno == 0 else { throw failure("Corpus allocation listing failed.") }
                break
            }
            let name = withUnsafePointer(to: next.pointee.d_name) {
                $0.withMemoryRebound(
                    to: CChar.self, capacity: MemoryLayout.size(ofValue: next.pointee.d_name)
                ) {
                    String(validatingCString: $0)
                }
            }
            guard let name else { throw failure("Corpus allocation name is invalid.") }
            if name == "." || name == ".." { continue }
            count += 1
            guard count <= 64 else { throw failure("Corpus stage has too many auxiliary entries.") }
            var metadata = stat()
            guard name.withCString({ fstatat(root, $0, &metadata, AT_SYMLINK_NOFOLLOW) }) == 0 else {
                throw failure("Cannot inspect corpus auxiliary allocation.")
            }
            let allocation = try entry(metadata)
            // The builder owns a flat stage; foreign nested trees are not followed or ignored.
            guard allocation.kind == .regular else { throw failure("Unsafe corpus auxiliary entry.") }
            try ledger.include(allocation)
        }
        return ledger.usage
    }
    private static func entry(_ metadata: stat) throws -> PageCorpusAllocationEntry {
        guard metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0,
            metadata.st_size >= 0, let size = Int64(exactly: metadata.st_size),
            let blocks = Int64(exactly: metadata.st_blocks), blocks >= 0
        else { throw failure("Corpus allocation ownership, mode or blocks are unsafe/unknown.") }
        let kind: PageCorpusAllocationEntry.Kind
        switch metadata.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFDIR): kind = .directory
        case mode_t(S_IFREG): kind = .regular
        case mode_t(S_IFLNK): kind = .symbolicLink
        default: kind = .other
        }
        return PageCorpusAllocationEntry(
            kind: kind, device: UInt64(truncatingIfNeeded: metadata.st_dev),
            inode: UInt64(truncatingIfNeeded: metadata.st_ino), logicalBytes: size, allocatedBlocks: blocks)
    }
    private static func failure(_ message: String) -> TractandaError {
        TractandaError("resourceLimit", message)
    }
}
