import CTractandaPlatform
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Public trust anchors supplied independently of the private target envelope.
package struct PeerTargetEnrollmentPin: Sendable {
    package let sourceReplicaID: String
    package let bootstrapID: String
    package let bootstrapSHA256: String
    package let approvalID: String
    package let approvalSHA256: String
    package init(sourceReplicaID: String, bootstrapID: String, bootstrapSHA256: String,
                 approvalID: String, approvalSHA256: String) throws {
        do {
            for id in [sourceReplicaID, bootstrapID, approvalID] { _ = try AuthorityRecord.persistentID(.text(id)) }
            for digest in [bootstrapSHA256, approvalSHA256] { _ = try AuthorityRecord.digest(.text(digest)) }
        } catch { throw PeerTargetEnrollment.failure("invalidTargetPin") }
        self.sourceReplicaID = sourceReplicaID; self.bootstrapID = bootstrapID
        self.bootstrapSHA256 = bootstrapSHA256; self.approvalID = approvalID; self.approvalSHA256 = approvalSHA256
    }
    var value: PeerEnrollmentActivation.Pin { get throws {
        try .init(sourceReplicaID: sourceReplicaID, bootstrap: .init(recordID: bootstrapID, sha256: bootstrapSHA256),
              approval: .init(recordID: approvalID, sha256: approvalSHA256))
    } }
}

/// A finite offline owner. No wire input constructs a trusted cursor or canonical caller identity.
package enum PeerTargetEnrollment {
    static let profile = "tractanda.peer-target-stdio.v2"
    static let maximumControlBytes = 16 * 1024
    static let maximumReplyBytes = 128 * 1024
    struct Entry: Codable {
        let ordinal: Int
        let descriptor: PeerPackage.Object
        let nextOffset: Int
        let verifiedComplete: Bool
    }
    struct Reply: Codable {
        let profile: String
        let operation: String
        var packageID: String? = nil
        var phase: String? = nil
        var entries: [Entry]? = nil
        var blockedOnIndex: Bool? = nil
        var complete: Bool? = nil
        var receipt: PeerEnrollmentActivation.Receipt? = nil
        var code: String? = nil
        init(_ operation: String) { self.profile = PeerTargetEnrollment.profile; self.operation = operation }
    }
    struct Request: Codable {
        let operation: String
        var packageID: String? = nil
        var advance: Bool? = nil
        var ordinal: Int? = nil
        var offset: Int? = nil
        static func decode(_ bytes: Data) throws -> Self {
            do {
                guard bytes.count <= maximumControlBytes,
                    let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                    let operation = object["operation"] as? String else { throw failure() }
                let keys: Set<String>
                switch operation {
                case "resume": keys = ["operation", "packageID", "advance"]
                case "append": keys = ["operation", "packageID", "ordinal", "offset"]
                case "finish", "close": keys = ["operation"]
                default: throw failure()
                }
                guard Set(object.keys) == keys else { throw failure() }
                let value = try JSON.decode(Self.self, bytes)
                if keys.contains("packageID") { _ = try AuthorityRecord.persistentID(.text(value.packageID ?? "")) }
                if operation == "resume", value.advance == nil { throw failure() }
                if operation == "append", !(0..<128).contains(value.ordinal ?? -1) || (value.offset ?? -1) < 0 { throw failure() }
                return value
            } catch { throw failure() }
        }
    }
    static func failure(_ code: String = "invalidTargetProtocol") -> TractandaError {
        TractandaError(code, "Finite target enrollment stopped; no automatic repair or retry was performed.")
    }
    static func sanitized(_ error: Error) -> TractandaError {
        let allowed: Set<String> = ["invalidTargetPin", "invalidTargetProtocol", "cancelled", "deadlineExceeded",
            "custodyUncertain", "storeBusy", "resourceLimit", "peerRepairRequired", "recoveryRequired", "missingDependencies",
            "peerPayloadVerifying", "enrollmentConflict", "invalidEnrollmentTarget", "enrollmentPending"]
        if error is CancellationError { return failure("cancelled") }
        let code = (error as? TractandaError)?.code ?? "invalidTargetProtocol"
        return failure(allowed.contains(code) ? code : "invalidTargetProtocol")
    }
    final class Control {
        let deadline: UInt64
        let cancelled: () -> Bool
        init(seconds: Double, cancelled: @escaping () -> Bool) throws {
            guard seconds.isFinite, seconds > 0, seconds <= 1800 else { throw failure() }
            deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
            self.cancelled = cancelled
        }
        func check() throws {
            try Task.checkCancellation()
            guard !cancelled() else { throw failure("cancelled") }
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw failure("deadlineExceeded") }
        }
    }
    /// Dedicated synchronous pipe IO; poll sleeps between readiness events and checks one absolute deadline.
    final class IO {
        let input: Int32, output: Int32
        let control: Control
        private let onWait: (() throws -> Void)?
        private var original: [(Int32, Int32, Int32)] = []
        init(input: Int32, output: Int32, control: Control, onWait: (() throws -> Void)? = nil) throws {
            guard input >= 0, output >= 0, input != output else { throw failure() }
            self.input = input; self.output = output; self.control = control; self.onWait = onWait
            do {
                for fd in [input, output] {
                    var metadata = stat()
                    guard fstat(fd, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFIFO) else { throw failure() }
                    let flags = fcntl(fd, F_GETFL), descriptorFlags = fcntl(fd, F_GETFD)
                    guard flags >= 0, descriptorFlags >= 0 else { throw failure() }
                    original.append((fd, flags, descriptorFlags))
                    guard fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
                        fcntl(fd, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else { throw failure() }
                }
            } catch { restore(); throw error }
        }
        deinit { restore() }
        func restoreBeforeClosing(_ fd: Int32) {
            guard let index = original.firstIndex(where: { $0.0 == fd }) else { return }
            let (_, flags, descriptorFlags) = original.remove(at: index)
            _ = fcntl(fd, F_SETFL, flags); _ = fcntl(fd, F_SETFD, descriptorFlags)
        }
        private func restore() {
            for (fd, flags, descriptorFlags) in original {
                _ = fcntl(fd, F_SETFL, flags); _ = fcntl(fd, F_SETFD, descriptorFlags)
            }
            original.removeAll()
        }
        private func wait(_ fd: Int32, writing: Bool) throws {
            while true {
                try control.check(); try onWait?()
                let remaining = control.deadline - min(control.deadline, DispatchTime.now().uptimeNanoseconds)
                let timeout = Int32(min(100, max(1, (remaining + 999_999) / 1_000_000)))
                var event = pollfd(fd: fd, events: Int16(writing ? POLLOUT : POLLIN), revents: 0)
                let result = poll(&event, 1, timeout)
                if result < 0, errno == EINTR { continue }
                guard result >= 0, event.revents & Int16(POLLNVAL) == 0 else { throw failure() }
                if result > 0 { try control.check(); try onWait?(); return }
            }
        }
        private func readExact(_ count: Int, allowEOF: Bool = false) throws -> Data? {
            var data = Data(count: count), offset = 0
            defer { if offset < count { data.resetBytes(in: 0..<data.count) } }
            while offset < count {
                try wait(input, writing: false)
                let amount = data.withUnsafeMutableBytes { read(input, $0.baseAddress!.advanced(by: offset), count - offset) }
                if amount < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                guard amount > 0 else {
                    data.resetBytes(in: 0..<data.count)
                    if amount == 0, offset == 0, allowEOF { return nil }
                    throw failure()
                }
                offset += amount
            }
            return data
        }
        func receive(maximum: Int, allowEOF: Bool = false) throws -> Data? {
            guard let header = try readExact(4, allowEOF: allowEOF) else { return nil }
            let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length > 0, length <= UInt32(maximum) else { throw failure() }
            return try readExact(Int(length))
        }
        func writeAll(_ data: Data) throws {
            var offset = 0
            while offset < data.count {
                try wait(output, writing: true)
                let amount = data.withUnsafeBytes { tractanda_document_write(output, $0.baseAddress!.advanced(by: offset), data.count - offset) }
                if amount < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                guard amount > 0 else { throw failure() }
                offset += Int(amount)
            }
        }
        func send(_ data: Data, maximum: Int = maximumReplyBytes) throws {
            guard !data.isEmpty, data.count <= maximum else { throw failure("resourceLimit") }
            let n = UInt32(data.count)
            try writeAll(Data([UInt8(n >> 24), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)]))
            try writeAll(data)
        }
        func send(_ reply: Reply) throws { try send(JSON.encode(reply)) }
    }
    static func pageReply(_ page: PeerPackage.ResumePage, packageID: String) throws -> Reply {
        guard page.objects.count <= 128 else { throw failure("resourceLimit") }
        var reply = Reply("page"); reply.packageID = packageID; reply.phase = page.state.phase.rawValue
        reply.entries = try page.objects.enumerated().map { ordinal, object in
            let entry = Entry(ordinal: ordinal, descriptor: object.descriptor,
                nextOffset: object.nextOffset, verifiedComplete: object.verifiedComplete)
            // Fixed fields only. Legal maximal descriptor encoding is tested below this bound.
            guard try JSON.encode(entry).count <= 768 else { throw failure("resourceLimit") }
            return entry
        }
        reply.blockedOnIndex = page.blockedOnIndex
        reply.complete = !page.blockedOnIndex && page.nextCursor == nil && page.objects.allSatisfy(\.verifiedComplete)
        guard try JSON.encode(reply).count <= maximumReplyBytes else { throw failure("resourceLimit") }
        return reply
    }
    package static func run(root: URL, pin: PeerTargetEnrollmentPin, inputFD: Int32, outputFD: Int32) throws {
        try run(root: root, pin: pin, inputFD: inputFD, outputFD: outputFD, accounts: SystemAccountDirectory(),
            maximumSeconds: 1800, cancelled: { tractanda_stopping() != 0 })
    }
    static func run(root: URL, pin: PeerTargetEnrollmentPin, inputFD: Int32, outputFD: Int32,
                    accounts: any AccountDirectory, maximumSeconds: Double,
                    cancelled: @escaping () -> Bool, beforeOperation: ((String) throws -> Void)? = nil,
                    pageLimitForTesting: Int = 128, afterReleaseBeforeReply: (() throws -> Void)? = nil) throws {
        guard getuid() != 0, getuid() == tractanda_uid(), root.path.hasPrefix("/"),
            root.path.utf8.count <= 4096, !root.path.utf8.contains(0) else { throw failure("invalidEnrollmentTarget") }
        guard (1...128).contains(pageLimitForTesting) else { throw failure() }
        let control = try Control(seconds: maximumSeconds, cancelled: cancelled)
        let io = try IO(input: inputFD, output: outputFD, control: control)
        var session: PeerEnrollmentActivation.Session?
        defer { session?.close() }
        do {
            try control.check(); try io.send(Reply("ready"))
            guard var privateBytes = try io.receive(maximum: PeerEnrollmentTargetOutput.maximumBytes, allowEOF: true) else { return }
            let decoded: (PeerEnrollmentActivation.Record, PeerCredential)
            do { defer { privateBytes.resetBytes(in: 0..<privateBytes.count) }; decoded = try PeerEnrollmentTargetOutput.decode(privateBytes) }
            let (record, credential) = decoded
            let material = PeerEnrollmentActivation.Material(preparationBytes: record.preparationBytes,
                baseline: record.baseline, proof: record.proof, sourceContext: record.sourceContext,
                targetContext: record.targetContext, targetCredential: credential,
                targetPrivateBytesDigest: record.targetPrivateBytesDigest)
            guard record.pin == (try pin.value) else { throw failure("invalidTargetPin") }
            guard try PeerEnrollmentActivation.makeRecord(material, pin: pin.value) == record else { throw failure("invalidTargetPin") }
            try control.check()
            let owner = try PeerEnrollmentActivation.open(root: root, material: material, pin: pin.value, accounts: accounts, control: control.check)
            session = owner
            let requestedClose: Bool = try owner.withControl(control.check) {
                try io.send(Reply("opened"))
                var package: String?, cursor: PeerPackage.ResumeCursor?, page: PeerPackage.ResumePage?
                for _ in 0..<PeerPackage.Limits().maximumWork {
                    guard let bytes = try io.receive(maximum: maximumControlBytes, allowEOF: true) else { return false }
                    let request = try Request.decode(bytes)
                    try control.check(); try beforeOperation?(request.operation); try control.check()
                    do {
                    switch request.operation {
                    case "close": return true
                    case "finish":
                        let receipt = try owner.finish(); try control.check()
                        var reply = Reply("finished"); reply.receipt = receipt; try io.send(reply)
                    case "resume":
                        let selected = request.packageID!
                        guard selected == record.baseline.packageID || selected == record.proof.manifest.packageID else { throw failure() }
                        if package != selected {
                            guard request.advance == false else { throw failure() }
                            package = selected; cursor = nil; page = nil
                        }
                        let fresh = try owner.resume(packageID: selected, cursor: cursor, limit: pageLimitForTesting)
                        if request.advance == true {
                            guard !fresh.blockedOnIndex, fresh.objects.allSatisfy(\.verifiedComplete) else { throw failure() }
                            if let next = fresh.nextCursor {
                                let candidate = try owner.resume(packageID: selected, cursor: next, limit: pageLimitForTesting)
                                let reply = try pageReply(candidate, packageID: selected)
                                try control.check(); try io.send(reply)
                                cursor = next; page = candidate; continue
                            }
                        }
                        let reply = try pageReply(fresh, packageID: selected)
                        try control.check(); try io.send(reply); page = fresh
                    case "append":
                        guard request.packageID == package, let current = page,
                            let ordinal = request.ordinal, ordinal < current.objects.count else { throw failure() }
                        let object = current.objects[ordinal]
                        guard !object.verifiedComplete, request.offset == object.nextOffset,
                            object.nextOffset < object.descriptor.length else { throw failure() }
                        guard var payload = try io.receive(maximum: object.descriptor.chunkBytes) else { throw failure() }
                        defer { payload.resetBytes(in: 0..<payload.count) }
                        guard payload.count == min(object.descriptor.chunkBytes, object.descriptor.length - object.nextOffset) else { throw failure() }
                        try control.check()
                        _ = try owner.append(packageID: package!, object: object.descriptor, offset: object.nextOffset, bytes: payload)
                        // Only the rendered page is invalidated. Its PRE-page cursor stays owned here.
                        page = nil
                        try control.check(); try io.send(Reply("appended"))
                    default: throw failure()
                    }
                    } catch let error as TractandaError where error.code == "peerPayloadVerifying" {
                        // This exact transient owns in-memory verifier progress in this Session/epoch.
                        // Keep the current pre-page cursor and append selection; duplicate offsets remain Core checked.
                        try control.check()
                        var reply = Reply("error"); reply.code = "peerPayloadVerifying"; try io.send(reply)
                    }
                }
                throw failure("resourceLimit")
            }
            // The controlled Store frame is gone before releasing the final Session slot.
            if requestedClose {
                try owner.closeForAcknowledgement(); session = nil
                try afterReleaseBeforeReply?(); try control.check(); try io.send(Reply("closed"))
            } else { owner.close(); session = nil }
        } catch {
            let safe = sanitized(error)
            var reply = Reply("error"); reply.code = safe.code
            try? io.send(reply)
            throw safe
        }
    }
}
