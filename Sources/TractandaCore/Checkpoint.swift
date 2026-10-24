import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Durability primitives for the disposable startup catalogue's write-ahead marker.
enum StoreCheckpoint {
    static let name = ".tractanda-checkpoint-dirty"

    static func markDirty(root: URL, maintenance: CanonicalMaintenanceContext? = nil) throws {
        if let maintenance {
            let event = try maintenance.beginCheckpoint(.checkpointDirty, suppliedRoot: root)
            do {
                try maintenance.requireBound(to: root)
                try replace(Data("dirty-v1\n".utf8), at: root.appendingPathComponent(name), root: root)
                try maintenance.finishCheckpoint(event, suppliedRoot: root)
            } catch {
                try? maintenance.finishCheckpoint(event, suppliedRoot: root, failed: true)
                throw error
            }
            return
        }
        try CanonicalMaintenanceContext.deny(
            root: root, path: [name], operation: "checkpoint mutation without a context")
        try replace(Data("dirty-v1\n".utf8), at: root.appendingPathComponent(name), root: root)
    }

    static func clear(root: URL, maintenance: CanonicalMaintenanceContext? = nil) throws {
        if let maintenance {
            let event = try maintenance.beginCheckpoint(.checkpointClear, suppliedRoot: root)
            do {
                try maintenance.requireBound(to: root)
                try clearDerived(root: root)
                try maintenance.finishCheckpoint(event, suppliedRoot: root)
            } catch {
                try? maintenance.finishCheckpoint(event, suppliedRoot: root, failed: true)
                throw error
            }
            return
        }
        try CanonicalMaintenanceContext.deny(
            root: root, path: [name], operation: "checkpoint clear without a context")
        try clearDerived(root: root)
    }
    private static func clearDerived(root: URL) throws {
        let url = root.appendingPathComponent(name)
        guard unlink(url.path) == 0 || errno == ENOENT else {
            throw TractandaError("checkpointError", "Cannot clear checkpoint marker.")
        }
        try syncDirectory(root)
    }

    static func isDirty(root: URL) -> Bool {
        // A dangling link, wrong file type, or an unreadable marker is never a clean signal.
        // Only a definite ENOENT permits checkpoint reuse.
        var metadata = stat()
        let result = lstat(root.appendingPathComponent(name).path, &metadata)
        return result == 0 || errno != ENOENT
    }

    private static func replace(_ data: Data, at url: URL, root: URL) throws {
        let temporary = root.appendingPathComponent(".checkpoint-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw TractandaError("checkpointError", "Cannot create checkpoint marker.")
        }
        var failure: Int32 = 0
        data.withUnsafeBytes { bytes in
            var cursor = 0
            while cursor < bytes.count {
                let count = write(descriptor, bytes.baseAddress!.advanced(by: cursor), bytes.count - cursor)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 {
                    failure = errno
                    break
                }
                cursor += count
            }
        }
        if failure == 0 && fsync(descriptor) != 0 { failure = errno }
        _ = close(descriptor)
        guard failure == 0 else {
            _ = unlink(temporary.path)
            throw TractandaError("checkpointError", "Cannot synchronize checkpoint marker.")
        }
        guard rename(temporary.path, url.path) == 0 else {
            _ = unlink(temporary.path)
            throw TractandaError("checkpointError", "Cannot publish checkpoint marker.")
        }
        try syncDirectory(root)
    }

    static func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw TractandaError("checkpointError", "Cannot open checkpoint directory.")
        }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw TractandaError("checkpointError", "Cannot synchronize checkpoint directory.")
        }
    }
}
