import CTractandaPlatform
import Foundation
import Synchronization

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Caller-local captured pair; neither a JSON value nor an authority grant.
package final class PeerEnrollmentPairInput: @unchecked Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    static let maximumBytes = 56 + PeerEnrollment.maximumBytes + 2 * PeerCredentialStore.maximumBytes
    static let marker = Data("TPPAIR01".utf8)
    private let bytes: Mutex<Data>
    package init(bytes: Data) throws {
        _ = try Self.decode(bytes)
        self.bytes = Mutex(bytes)
    }
    package static func capture(path: String) throws -> PeerEnrollmentPairInput {
        guard let data = try PeerEnrollmentFiles.readPrivate(path, maximum: maximumBytes) else {
            throw NativePeerEnrollment.failure()
        }
        return try .init(bytes: data)
    }
    package var count: Int { bytes.withLock { $0.count } }
    package var operationID: String { get throws { try bytes.withLock { try Self.decode($0).operationID } } }
    func withBytes<T>(_ body: (Data) throws -> T) rethrows -> T { try bytes.withLock { try body($0) } }
    package var description: String { "PeerEnrollmentPairInput(<redacted>)" }
    package var debugDescription: String { description }
    package var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
    deinit {
        bytes.withLock {
            $0.resetBytes(in: 0..<$0.count)
            $0.removeAll()
        }
    }
    struct Contents {
        let operationID: String
        let preparationBytes: Data
        let sourceCredential: PeerCredential
        let targetCredential: PeerCredential
    }
    static func encode(_ value: Contents) throws -> Data {
        let a = try value.sourceCredential.privateEncodedBytes()
        let b = try value.targetCredential.privateEncodedBytes()
        var data = marker
        for length in [value.preparationBytes.count, a.count, b.count] { data.appendUInt32(length) }
        data.append(Data(value.operationID.utf8))
        data.append(value.preparationBytes)
        data.append(a)
        data.append(b)
        _ = try decode(data)
        return data
    }
    static func decode(_ data: Data) throws -> Contents {
        do {
            guard (56...maximumBytes).contains(data.count), data.prefix(8) == marker else {
                throw NativePeerEnrollment.failure()
            }
            let p = try data.enrollmentUInt32(at: 8)
            let a = try data.enrollmentUInt32(at: 12)
            let b = try data.enrollmentUInt32(at: 16)
            guard (1...PeerEnrollment.maximumBytes).contains(p), (36...4096).contains(a),
                (36...4096).contains(b),
                56 + p + a + b == data.count
            else { throw NativePeerEnrollment.failure() }
            let operation = String(decoding: data[20..<56], as: UTF8.self)
            _ = try AuthorityRecord.persistentID(.text(operation))
            let preparation = Data(data[56..<56 + p])
            let prep = try PeerEnrollmentApproval.preparation(preparation)
            let source = try PeerCredential.decode(Data(data[56 + p..<56 + p + a]))
            let target = try PeerCredential.decode(Data(data[56 + p + a..<data.count]))
            let x = source.binding
            let y = target.binding
            guard operation != prep.operationID, x.storeID == prep.commonStoreID,
                y.storeID == prep.commonStoreID,
                x.localReplicaID == prep.sourceReplicaID, x.remoteReplicaID == prep.targetReplicaID,
                y.localReplicaID == prep.targetReplicaID, y.remoteReplicaID == prep.sourceReplicaID,
                x.pairingID == y.pairingID, x.localIsInitiator != y.localIsInitiator,
                Set([
                    prep.commonStoreID, prep.sourceReplicaID, prep.targetReplicaID, prep.operationID,
                    operation, x.pairingID,
                ]).count == 6,
                source.withTLSInput({ _, secret in target.withTLSInput { _, other in secret == other } })
            else {
                throw NativePeerEnrollment.failure()
            }
            return .init(
                operationID: operation, preparationBytes: preparation, sourceCredential: source,
                targetCredential: target)
        } catch { throw NativePeerEnrollment.failure() }
    }
}

/// Local file hygiene only. No server request supplies a pathname to these operations.
enum PeerEnrollmentFiles {
    static func readPrivate(_ path: String, maximum: Int) throws -> Data? {
        guard (1...PeerPackage.maximumChunkBytes).contains(maximum) else {
            throw NativePeerEnrollment.failure()
        }
        let path = try PeerPrivateCredentialInput.checkedPath(path)
        var pointer: UnsafeMutableRawPointer?
        var count: UInt32 = 0
        let result = path.withCString {
            tractanda_capture_private_artifact($0, &pointer, &count, UInt32(maximum))
        }
        if result == 1 { return nil }
        guard result == 0 else { throw NativePeerEnrollment.failure() }
        guard let pointer else { throw NativePeerEnrollment.failure() }
        defer { tractanda_private_free(pointer, count) }
        return Data(bytes: pointer, count: Int(count))
    }
    private static func readPrivate(parent: Int32, name: String, maximum: Int) throws -> Data? {
        var pointer: UnsafeMutableRawPointer?
        var count: UInt32 = 0
        let result = name.withCString {
            tractanda_capture_private_artifact_at(parent, $0, &pointer, &count, UInt32(maximum))
        }
        if result == 1 { return nil }
        guard result == 0, let pointer else { throw NativePeerEnrollment.failure() }
        defer { tractanda_private_free(pointer, count) }
        return Data(bytes: pointer, count: Int(count))
    }
    private static func requireNamedParent(_ path: String, matches held: Int32) throws {
        let named = path.withCString { tractanda_open_private_directory($0) }
        guard named >= 0 else { throw NativePeerEnrollment.failure() }
        defer { tractanda_close(named) }
        var a = stat()
        var b = stat()
        guard fstat(held, &a) == 0, fstat(named, &b) == 0, a.st_dev == b.st_dev, a.st_ino == b.st_ino else {
            throw NativePeerEnrollment.failure()
        }
    }
    static func preparation(_ path: String) throws -> Data {
        let data = try preparationSizedMetadata(path)
        do {
            _ = try PeerEnrollmentApproval.preparation(data)
            return data
        } catch { throw NativePeerEnrollment.failure() }
    }
    static func preparationSizedMetadata(_ path: String) throws -> Data {
        let path = try PeerPrivateCredentialInput.checkedPath(path)
        var pointer: UnsafeMutableRawPointer?
        var count: UInt32 = 0
        guard path.withCString({ tractanda_capture_peer_preparation($0, &pointer, &count) }) == 0, let pointer
        else {
            throw NativePeerEnrollment.failure()
        }
        defer { tractanda_private_free(pointer, count) }
        let data = Data(bytes: pointer, count: Int(count))
        return data
    }
    static func writeExact(
        _ data: Data, path: String, maximum: Int,
        afterParentOpenForTesting: (() throws -> Void)? = nil,
        afterPublicationForTesting: (() throws -> Void)? = nil
    ) throws {
        guard data.count <= maximum, maximum <= PeerPackage.maximumChunkBytes else {
            throw NativePeerEnrollment.failure()
        }
        let absolute = try PeerPrivateCredentialInput.checkedPath(path)
        guard let slash = absolute.lastIndex(of: "/"), slash < absolute.index(before: absolute.endIndex)
        else {
            throw NativePeerEnrollment.failure()
        }
        let parent = slash == absolute.startIndex ? "/" : String(absolute[..<slash])
        let name = String(absolute[absolute.index(after: slash)...])
        guard name != ".", name != ".." else { throw NativePeerEnrollment.failure() }
        let fd = parent.withCString { tractanda_open_private_directory($0) }
        guard fd >= 0 else { throw NativePeerEnrollment.failure() }
        defer { tractanda_close(fd) }
        try afterParentOpenForTesting?()
        if let old = try readPrivate(parent: fd, name: name, maximum: maximum) {
            guard old == data, fsync(fd) == 0 else { throw NativePeerEnrollment.failure() }
            try requireNamedParent(parent, matches: fd)
            guard try readPrivate(parent: fd, name: name, maximum: maximum) == data else {
                throw NativePeerEnrollment.failure()
            }
            return
        }
        let temporary = ".peer-artifact-" + UUID().uuidString + ".tmp"
        let result = data.withUnsafeBytes { raw in
            temporary.withCString { source in
                name.withCString { target in
                    tractanda_write_private_artifact_at(
                        fd, source, target, raw.baseAddress, UInt32(raw.count))
                }
            }
        }
        if result < 0 {
            guard errno == EEXIST, try readPrivate(parent: fd, name: name, maximum: maximum) == data,
                fsync(fd) == 0
            else {
                throw NativePeerEnrollment.failure()
            }
        } else if result == 1 {
            throw NativePeerEnrollment.failure()
        }
        try afterPublicationForTesting?()
        guard try readPrivate(parent: fd, name: name, maximum: maximum) == data else {
            throw NativePeerEnrollment.failure()
        }
        try requireNamedParent(parent, matches: fd)
    }
}

extension Data {
    fileprivate mutating func appendUInt32(_ value: Int) {
        let v = UInt32(value)
        append(contentsOf: [UInt8(v >> 24), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)])
    }
    fileprivate func enrollmentUInt32(at offset: Int) throws -> Int {
        guard offset >= 0, offset <= count - 4 else { throw NativePeerEnrollment.failure() }
        return self[offset..<offset + 4].reduce(0) { $0 * 256 + Int($1) }
    }
}

/// The only secret-bearing output profile: exact accepted target record + target credential.
package final class PeerEnrollmentTargetOutput: @unchecked Sendable, CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    static let maximumBytes = 16 + PeerEnrollmentActivation.maximumBytes + PeerCredentialStore.maximumBytes
    static let marker = Data("TPTARG01".utf8)
    private let bytes: Mutex<Data>
    init(material: PeerEnrollmentActivation.Material) throws {
        let original = try AuthorityRecordCodec.decode(material.proof.approvalBytes)
        let bootstrap = try AuthorityRecord.list(original.record.payload["bootstrap"]).map(
            AuthorityBinding.init(value:))
        guard bootstrap.count == 1 else { throw NativePeerEnrollment.failure() }
        let prep = try PeerEnrollmentApproval.preparation(material.preparationBytes)
        let pin = PeerEnrollmentActivation.Pin(
            sourceReplicaID: prep.sourceReplicaID, bootstrap: bootstrap[0],
            approval: try .init(recordID: original.record.recordID, sha256: original.sha256))
        let record = try PeerEnrollmentActivation.makeRecord(material, pin: pin)
        let encoded = try JSON.encode(record)
        let credential = try material.targetCredential.privateEncodedBytes()
        guard encoded.count <= PeerEnrollmentActivation.maximumBytes, credential.count <= 4096 else {
            throw NativePeerEnrollment.failure()
        }
        var data = Self.marker
        data.appendUInt32(encoded.count)
        data.appendUInt32(credential.count)
        data.append(encoded)
        data.append(credential)
        bytes = Mutex(data)
    }
    init(bytes: Data) throws {
        _ = try Self.decode(bytes)
        self.bytes = Mutex(bytes)
    }
    static func decode(_ data: Data) throws -> (PeerEnrollmentActivation.Record, PeerCredential) {
        do {
            guard data.count >= 16, data.count <= maximumBytes, data.prefix(8) == marker else {
                throw NativePeerEnrollment.failure()
            }
            let r = try data.enrollmentUInt32(at: 8)
            let c = try data.enrollmentUInt32(at: 12)
            guard (1...PeerEnrollmentActivation.maximumBytes).contains(r), (36...4096).contains(c),
                16 + r + c == data.count
            else {
                throw NativePeerEnrollment.failure()
            }
            let record = try PeerPackage.decode(PeerEnrollmentActivation.Record.self, Data(data[16..<16 + r]))
            let credential = try PeerCredential.decode(Data(data[16 + r..<data.count]))
            try PeerEnrollmentActivation.validate(record)
            try PeerEnrollmentActivation.validateCredential(credential, record: record)
            return (record, credential)  // These pins are assertions, never independently trusted input.
        } catch { throw NativePeerEnrollment.failure() }
    }
    package static func capture(path: String) throws -> PeerEnrollmentTargetOutput {
        do {
            guard let data = try PeerEnrollmentFiles.readPrivate(path, maximum: maximumBytes) else {
                throw NativePeerEnrollment.failure()
            }
            return try .init(bytes: data)
        } catch { throw NativePeerEnrollment.failure() }
    }
    package var count: Int { bytes.withLock { $0.count } }
    package func withBytes<T>(_ body: (Data) throws -> T) rethrows -> T {
        try bytes.withLock { try body($0) }
    }
    package var description: String { "PeerEnrollmentTargetOutput(<redacted>)" }
    package var debugDescription: String { description }
    package var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
    deinit {
        bytes.withLock {
            $0.resetBytes(in: 0..<$0.count)
            $0.removeAll()
        }
    }
}

package struct PeerEnrollmentOperatorStatus: Codable, Sendable {
    package let operationID: String
    package let phase: String
    package let storeID: String
    package let sourceReplicaID: String
    package let targetReplicaID: String
    package let bootstrap: AuthorityBinding
    package let approval: AuthorityBinding?
    package let baselineManifest: Data?
    func validate() throws {
        for id in [operationID, storeID, sourceReplicaID, targetReplicaID] {
            _ = try AuthorityRecord.persistentID(.text(id))
        }
        _ = try AuthorityBinding(recordID: bootstrap.recordID, sha256: bootstrap.sha256)
        if let approval { _ = try AuthorityBinding(recordID: approval.recordID, sha256: approval.sha256) }
        guard
            ["pending", "selecting", "building", "ready", "accepted", "registered", "exported"].contains(
                phase)
        else { throw NativePeerEnrollment.failure() }
        if let baselineManifest {
            let manifest = try PeerPackage.decode(PeerPackage.Manifest.self, baselineManifest)
            try manifest.validate()
            guard manifest.storeID == storeID else { throw NativePeerEnrollment.failure() }
        }
    }
}

package enum NativePeerEnrollment {
    package enum Action: String, Codable, Sendable { case step, status, accept, register }
    package static let prefix = Data("TRACTANDA-PEER-ENROLLMENT/1\n".utf8)
    package static let ready = Data("TRACTANDA-PEER-ENROLLMENT-READY/1".utf8)
    package static let maximumMetadata = 16 * 1024
    package static let maximumTargetOutputBytes = PeerEnrollmentTargetOutput.maximumBytes
    package static func failure() -> TractandaError {
        .init(
            "nativeEnrollmentProtocol",
            "Enrollment input or operation is unavailable; no private details are returned.")
    }
    package static func failure(_ error: any Error) -> Data {
        let allowed: Set<String> = [
            "forbidden", "serviceBusy", "serviceClosed", "cancelled", "deadlineExceeded",
            "operationReviewRequired",
            "enrollmentReviewRequired", "enrollmentActivationRequired", "enrollmentBaselineIncomplete",
            "invalidEnrollmentTarget", "storeBusy",
            "recoveryRequired", "resourceLimit", "peerPayloadVerifying", "nativeEnrollmentProtocol",
            "invalidArguments", "localReplicaRetired", "peerRetired",
        ]
        let code = (error as? TractandaError)?.code
        return
            (try? JSON.encode(
                TractandaError(
                    code.flatMap { allowed.contains($0) ? $0 : nil } ?? "nativeEnrollmentProtocol",
                    "Enrollment was not completed or its result is unavailable."))) ?? Data()
    }
    static func checkedError(_ data: Data) -> TractandaError? {
        guard let error = try? JSON.decode(TractandaError.self, data) else { return nil }
        return try? JSON.decode(TractandaError.self, failure(error))
    }
    package struct PrivateRequest: Codable, Sendable {
        package enum Operation: String, Codable, Sendable { case begin, exportTarget }
        package let operation: Operation
        package let operationID: String
        package let byteCount: Int
        package init(operation: Operation, operationID: String, byteCount: Int) throws {
            _ = try AuthorityRecord.persistentID(.text(operationID))
            guard
                operation == .begin
                    ? (56...PeerEnrollmentPairInput.maximumBytes).contains(byteCount) : byteCount == 0
            else { throw failure() }
            self.operation = operation
            self.operationID = operationID
            self.byteCount = byteCount
        }
        package func encoded() throws -> Data {
            let data = prefix + (try JSON.encode(self))
            guard data.count <= maximumMetadata else { throw failure() }
            return data
        }
        package static func parse(_ data: Data) throws -> Self {
            do {
                guard data.count <= maximumMetadata, data.starts(with: prefix) else { throw failure() }
                let body = Data(data.dropFirst(prefix.count))
                let value = try JSON.decode(Self.self, body)
                _ = try Self(
                    operation: value.operation, operationID: value.operationID, byteCount: value.byteCount)
                guard try JSON.encode(value) == body else { throw failure() }
                return value
            } catch { throw failure() }
        }
    }
    package static func createPair(
        preparationPath: String, outputPath: String, sourcePeerID: String,
        targetPeerID: String, sourceIsInitiator: Bool
    ) throws -> Data {
        let preparation = try PeerEnrollmentFiles.preparation(preparationPath)
        let prep = try PeerEnrollmentApproval.preparation(preparation)
        func summarize(_ contents: PeerEnrollmentPairInput.Contents) throws -> Data {
            let a = contents.sourceCredential.binding
            let b = contents.targetCredential.binding
            guard contents.preparationBytes == preparation, a.peerID == sourcePeerID,
                b.peerID == targetPeerID,
                a.localIsInitiator == sourceIsInitiator
            else { throw failure() }
            return try JSON.encode([
                "operationID": contents.operationID, "pairingID": a.pairingID,
                "storeID": prep.commonStoreID, "sourceReplicaID": prep.sourceReplicaID,
                "targetReplicaID": prep.targetReplicaID,
            ])
        }
        _ = try AuthorityRecord.text(.text(sourcePeerID))
        _ = try AuthorityRecord.text(.text(targetPeerID))
        guard sourcePeerID != "local", targetPeerID != "local" else { throw failure() }
        if let old = try PeerEnrollmentFiles.readPrivate(
            outputPath, maximum: PeerEnrollmentPairInput.maximumBytes)
        {
            let result = try summarize(PeerEnrollmentPairInput.decode(old))
            try PeerEnrollmentFiles.writeExact(
                old, path: outputPath, maximum: PeerEnrollmentPairInput.maximumBytes)
            return result
        }
        func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
        let operation = try id()
        let pairing = try id()
        let aDigest = try AuthorityRecordCodec.sha256(Data(id().utf8))
        let bDigest = try AuthorityRecordCodec.sha256(Data(id().utf8))
        var random = SystemRandomNumberGenerator()
        let secret = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) }
        let source = try PeerCredential(
            binding: .init(
                peerID: sourcePeerID, storeID: prep.commonStoreID,
                localReplicaID: prep.sourceReplicaID, remoteReplicaID: prep.targetReplicaID,
                pairingID: pairing,
                localIsInitiator: sourceIsInitiator, configurationDigest: aDigest), secret: secret)
        let target = try PeerCredential(
            binding: .init(
                peerID: targetPeerID, storeID: prep.commonStoreID,
                localReplicaID: prep.targetReplicaID, remoteReplicaID: prep.sourceReplicaID,
                pairingID: pairing,
                localIsInitiator: !sourceIsInitiator, configurationDigest: bDigest), secret: secret)
        let contents = PeerEnrollmentPairInput.Contents(
            operationID: operation, preparationBytes: preparation,
            sourceCredential: source, targetCredential: target)
        try PeerEnrollmentFiles.writeExact(
            PeerEnrollmentPairInput.encode(contents), path: outputPath,
            maximum: PeerEnrollmentPairInput.maximumBytes)
        return try summarize(contents)
    }
    private static func socket<T>(_ connection: ServerConnection, body: (Int32, UInt64) throws -> T) throws
        -> T
    {
        try connection.validate()
        let fd = tractanda_connect(connection.socketPath)
        guard fd >= 0 else {
            throw LocalTransport.connectionFailure(socket: connection.socketPath, errorCode: errno)
        }
        defer { tractanda_close(fd) }
        let expected =
            try (connection.serverUser ?? ProcessInfo.processInfo.environment["TRACTANDA_SERVER_USER"])
            .map { try SystemAccountDirectory().user(named: $0).uid } ?? tractanda_uid()
        var uid: UInt32 = .max
        guard tractanda_peer_uid(fd, &uid) == 0, uid == expected else {
            throw TractandaError("forbidden", "Unexpected daemon OS identity.")
        }
        let deadline = tractanda_private_io_begin(fd)
        guard deadline != 0 else { throw failure() }
        return try body(fd, deadline)
    }
    private static func receive(_ fd: Int32, maximum: Int, deadline: UInt64) throws -> Data {
        var pointer: UnsafeMutableRawPointer?
        var count: UInt32 = 0
        guard tractanda_private_receive_frame(fd, &pointer, &count, UInt32(maximum), deadline) == 0,
            let pointer
        else { throw failure() }
        defer { tractanda_private_free(pointer, count) }
        return Data(bytes: pointer, count: Int(count))
    }
    private static func sendRequest(_ request: PrivateRequest, fd: Int32, deadline: UInt64) throws {
        let data = try request.encoded()
        guard
            data.withUnsafeBytes({
                tractanda_private_send_begin(fd, $0.baseAddress, UInt32($0.count), deadline)
            }) == 0
        else { throw failure() }
        let reply = try receive(fd, maximum: maximumMetadata, deadline: deadline)
        guard reply == ready else { throw checkedError(reply) ?? failure() }
    }
    static func checkedStatus(_ data: Data, operationID: String) throws -> Data {
        if let error = checkedError(data) { throw error }
        do {
            let status = try JSON.decode(PeerEnrollmentOperatorStatus.self, data)
            try status.validate()
            guard status.operationID == operationID, try JSON.encode(status) == data,
                data.count <= maximumMetadata
            else { throw failure() }
            return data
        } catch { throw failure() }
    }
    package static func begin(connection: ServerConnection, input: PeerEnrollmentPairInput) throws -> Data {
        let operation = try input.operationID
        let request = try PrivateRequest(operation: .begin, operationID: operation, byteCount: input.count)
        return try socket(connection) { fd, deadline in
            try sendRequest(request, fd: fd, deadline: deadline)
            guard
                input.withBytes({ data in
                    data.withUnsafeBytes {
                        tractanda_private_send_frame(fd, $0.baseAddress, UInt32($0.count), deadline)
                    }
                }) == 0
            else { throw failure() }
            return try checkedStatus(
                receive(fd, maximum: maximumMetadata, deadline: deadline), operationID: operation)
        }
    }
    private static func sendNative(_ connection: ServerConnection, request: Data) throws -> Data {
        var selected = connection
        selected.managedService = nil
        return try selected.send(request)
    }
    package static func call(connection: ServerConnection, action: Action, operationID: String) throws -> Data
    {
        _ = try AuthorityRecord.persistentID(.text(operationID))
        let call = PeerEnrollmentNativeCall(action: action.rawValue, operationID: operationID)
        return try checkedStatus(sendNative(connection, request: call.encoded()), operationID: operationID)
    }
    package static func exportTarget(connection: ServerConnection, operationID: String, outputPath: String)
        throws -> Data
    {
        let request = try PrivateRequest(operation: .exportTarget, operationID: operationID, byteCount: 0)
        return try socket(connection) { fd, deadline in
            try sendRequest(request, fd: fd, deadline: deadline)
            let data = try receive(fd, maximum: PeerEnrollmentTargetOutput.maximumBytes, deadline: deadline)
            if let error = checkedError(data) { throw error }
            let (record, _) = try PeerEnrollmentTargetOutput.decode(data)
            let approval = try AuthorityRecordCodec.decode(record.proof.approvalBytes).record
            guard approval.payload["operationID"]?.string == operationID else { throw failure() }
            try PeerEnrollmentFiles.writeExact(
                data, path: outputPath, maximum: PeerEnrollmentTargetOutput.maximumBytes)
            let prep = try record.preparation
            return try JSON.encode(
                PeerEnrollmentOperatorStatus(
                    operationID: operationID, phase: "exported", storeID: prep.commonStoreID,
                    sourceReplicaID: prep.sourceReplicaID, targetReplicaID: prep.targetReplicaID,
                    bootstrap: record.pin.bootstrap,
                    approval: record.pin.approval, baselineManifest: JSON.encode(record.baseline)))
        }
    }
    /// One authenticated source call: the same absolute cutoff includes UNIX connect and frames.
    private static func boundedSourceExchange(
        _ connection: ServerConnection, request: Data,
        maximum: Int, deadline: UInt64
    ) throws -> Data {
        try Task.checkCancellation()
        try connection.validate()
        let expected =
            try (connection.serverUser ?? ProcessInfo.processInfo.environment["TRACTANDA_SERVER_USER"])
            .map { try SystemAccountDirectory().user(named: $0).uid } ?? tractanda_uid()
        let fd = tractanda_private_connect_until(connection.socketPath, deadline)
        guard fd >= 0 else {
            throw TractandaError(
                errno == ETIMEDOUT ? "deadlineExceeded" : "connectionFailed",
                "Bounded source connection failed.")
        }
        defer { tractanda_close(fd) }
        var actual: UInt32 = .max
        guard tractanda_peer_uid(fd, &actual) == 0, actual == expected else {
            throw TractandaError("forbidden", "Unexpected source daemon OS identity.")
        }
        try Task.checkCancellation()
        guard request.count <= maximumMetadata,
            request.withUnsafeBytes({
                tractanda_private_send_frame(fd, $0.baseAddress, UInt32($0.count), deadline)
            }) == 0
        else { throw failure() }
        return try receive(fd, maximum: maximum, deadline: deadline)
    }
    static func boundedCall(
        connection: ServerConnection, action: Action, operationID: String,
        deadline: UInt64
    ) throws -> PeerEnrollmentOperatorStatus {
        _ = try AuthorityRecord.persistentID(.text(operationID))
        let call = PeerEnrollmentNativeCall(action: action.rawValue, operationID: operationID)
        let data = try boundedSourceExchange(
            connection, request: call.encoded(), maximum: maximumMetadata, deadline: deadline)
        return try JSON.decode(
            PeerEnrollmentOperatorStatus.self, checkedStatus(data, operationID: operationID))
    }
    static func checkedChunk(
        _ response: Data, object: PeerPackage.Object, offset: Int,
        maximumBytes: Int
    ) throws -> PeerEnrollmentNativeChunk {
        if let error = checkedError(response) { throw error }
        do {
            let chunk = try JSON.decode(PeerEnrollmentNativeChunk.self, response)
            guard chunk.object == object, chunk.offset == offset, chunk.offset <= object.length,
                chunk.bytes.count == min(maximumBytes, object.chunkBytes, object.length - chunk.offset),
                try JSON.encode(chunk) == response
            else { throw failure() }
            return chunk
        } catch { throw failure() }
    }
    static func readChunk(
        connection: ServerConnection, operationID: String, object: PeerPackage.Object,
        offset: Int, maximumBytes: Int, deadline: UInt64
    ) throws -> PeerEnrollmentNativeChunk {
        guard offset >= 0, offset <= object.length, (1...65536).contains(maximumBytes) else {
            throw failure()
        }
        try object.validate()
        _ = try AuthorityRecord.persistentID(.text(operationID))
        let call = PeerEnrollmentNativeCall(
            action: "read", operationID: operationID, descriptor: object,
            offset: offset, maximumBytes: maximumBytes)
        let response = try boundedSourceExchange(
            connection, request: call.encoded(), maximum: 128 * 1024, deadline: deadline)
        return try checkedChunk(response, object: object, offset: offset, maximumBytes: maximumBytes)
    }
    package static func readObject(
        connection: ServerConnection, operationID: String, descriptorPath: String,
        offset: Int, maximumBytes: Int, outputPath: String
    ) throws -> Data {
        guard offset >= 0, (1...PeerPackage.maximumChunkBytes).contains(maximumBytes) else { throw failure() }
        let object: PeerPackage.Object
        do {
            let descriptor = try PeerEnrollmentFiles.preparationSizedMetadata(descriptorPath)
            object = try PeerPackage.decode(
                PeerPackage.Object.self, descriptor, maximum: PeerEnrollment.maximumBytes)
            try object.validate()
        } catch { throw failure() }
        let call = PeerEnrollmentNativeCall(
            action: "read", operationID: operationID, descriptor: object, offset: offset,
            maximumBytes: maximumBytes)
        let response = try sendNative(connection, request: call.encoded())
        let chunk = try checkedChunk(response, object: object, offset: offset, maximumBytes: maximumBytes)
        try PeerEnrollmentFiles.writeExact(
            chunk.bytes, path: outputPath, maximum: PeerPackage.maximumChunkBytes)
        return try JSON.encode(["offset": offset, "byteCount": chunk.bytes.count])
    }
}

/// Exact native-only metadata. Object descriptors select sealed export bytes, never admission.
package struct PeerEnrollmentNativeCall: Sendable {
    package let action: String
    package let operationID: String
    let object: PeerPackage.Object?
    let offset: Int
    let maximumBytes: Int
    let callID: String
    init(
        action: String, operationID: String, descriptor: PeerPackage.Object? = nil, offset: Int = 0,
        maximumBytes: Int = PeerPackage.maximumChunkBytes, callID: String = "enrollment"
    ) {
        self.callID = callID
        self.action = action
        self.operationID = operationID
        object = descriptor
        self.offset = offset
        self.maximumBytes = maximumBytes
    }
    func encoded() throws -> Data {
        var args: [String: Any] = ["operationID": operationID]
        if let object {
            args["descriptor"] = try JSONSerialization.jsonObject(with: JSON.encode(object))
            args["offset"] = offset
            args["maximumBytes"] = maximumBytes
        }
        return try JSONSerialization.data(
            withJSONObject: [
                "using": [ItemService.capability],
                "methodCalls": [["TractandaPeerEnrollment/" + action, args, callID]],
            ], options: [.sortedKeys])
    }
    package static func parse(_ data: Data) throws -> Self? {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let calls = envelope["methodCalls"] as? [[Any]],
            calls.contains(where: { ($0.first as? String)?.hasPrefix("TractandaPeerEnrollment/") == true })
        else { return nil }
        do {
            guard data.count <= NativePeerEnrollment.maximumMetadata,
                Set(envelope.keys) == ["using", "methodCalls"],
                envelope["using"] as? [String] == [ItemService.capability], calls.count == 1,
                calls[0].count == 3,
                let method = calls[0][0] as? String, let args = calls[0][1] as? [String: Any],
                let callID = calls[0][2] as? String, !callID.isEmpty, callID.utf8.count <= 256,
                let operation = args["operationID"] as? String
            else { throw NativePeerEnrollment.failure() }
            _ = try AuthorityRecord.persistentID(.text(operation))
            let action = String(method.dropFirst("TractandaPeerEnrollment/".count))
            if NativePeerEnrollment.Action(rawValue: action) != nil {
                guard Set(args.keys) == ["operationID"] else { throw NativePeerEnrollment.failure() }
                let call = Self(action: action, operationID: operation, callID: callID)
                guard try call.encoded() == data else { throw NativePeerEnrollment.failure() }
                return call
            }
            guard action == "read",
                Set(args.keys) == ["operationID", "descriptor", "offset", "maximumBytes"],
                let descriptor = args["descriptor"] as? [String: Any]
            else { throw NativePeerEnrollment.failure() }
            struct Read: Decodable {
                let offset: Int
                let maximumBytes: Int
            }
            let bounds = try JSON.decode(Read.self, JSONSerialization.data(withJSONObject: args))
            let object = try JSON.decode(
                PeerPackage.Object.self, JSONSerialization.data(withJSONObject: descriptor))
            try object.validate()
            guard bounds.offset >= 0, (1...PeerPackage.maximumChunkBytes).contains(bounds.maximumBytes),
                Set(descriptor.keys).isSubset(of: ["kind", "id", "length", "sha256", "part"])
            else { throw NativePeerEnrollment.failure() }
            // Strict descriptor re-encoding prevents ignored fields/ambiguous composite addresses.
            let canonical = try JSONSerialization.jsonObject(with: JSON.encode(object)) as? NSDictionary
            guard canonical == descriptor as NSDictionary else { throw NativePeerEnrollment.failure() }
            let call = Self(
                action: action, operationID: operation, descriptor: object, offset: bounds.offset,
                maximumBytes: bounds.maximumBytes, callID: callID)
            guard try call.encoded() == data else { throw NativePeerEnrollment.failure() }
            return call
        } catch {
            throw TractandaError(
                "invalidArguments",
                "Use one strict native enrollment operation with explicit bounded arguments.")
        }
    }
}
struct PeerEnrollmentNativeChunk: Codable, Sendable {
    let object: PeerPackage.Object
    let offset: Int
    let bytes: Data
}

/// Opaque host admission; no caller-supplied identity or opening capability.
package struct PeerNativeEnrollmentAdmission: Sendable {
    let id: UUID
    let owner: UUID
    let uid: UInt32
    let generation: UInt64
    let request: NativePeerEnrollment.PrivateRequest
    let control: PeerExchangeControl
    let output: PeerEnrollmentTargetOutput?
}
