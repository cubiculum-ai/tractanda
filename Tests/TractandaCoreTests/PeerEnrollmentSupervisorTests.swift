import CTractandaPlatform
import Foundation
import XCTest
@testable import TractandaCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class PeerEnrollmentSupervisorTests: XCTestCase {
    private func root() throws -> URL {
        try AttachmentFixtureCapacity.requireFree()
        return try GuardedFixtureDirectory.create(prefix: "e", source: "PeerEnrollmentSupervisorTests", test: name)
    }
    func testFixedImageSiblingRejectsLinksWritableHelperAndMutationACL() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        for directory in [a,b] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        let helper = a.appendingPathComponent("tractanda-setup")
        try Data("fixed helper fixture".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        XCTAssertEqual(tractanda_validate_enrollment_helper(helper.path, 0), 0)
        let actualImage = a.appendingPathComponent("tractanda"), alias = root.appendingPathComponent("current")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: a)
        XCTAssertEqual(try PeerEnrollmentSupervisor.sibling(image: actualImage), helper)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: b)
        XCTAssertEqual(try PeerEnrollmentSupervisor.sibling(image: actualImage), helper, "Loaded-image path is independent of a retargeted alias")
        XCTAssertNotEqual(tractanda_validate_enrollment_helper(alias.appendingPathComponent("tractanda-setup").path, 0), 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o720], ofItemAtPath: helper.path)
        XCTAssertNotEqual(tractanda_validate_enrollment_helper(helper.path, 0), 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        #if os(macOS)
        func chmod(_ arguments: [String]) throws {
            let strings = (["/bin/chmod"] + arguments + [helper.path]).map { strdup($0) }
            defer { strings.forEach { free($0) } }
            guard strings.allSatisfy({ $0 != nil }) else { throw PeerEnrollmentSupervisor.failure() }
            let argv: [UnsafePointer<CChar>?] = strings.map { $0.map { UnsafePointer<CChar>($0) } } + [nil]
            var pid: Int32 = -1, input: Int32 = -1, output: Int32 = -1, diagnostics: Int32 = -1
            guard argv.withUnsafeBufferPointer({ tractanda_document_spawn("/bin/chmod", $0.baseAddress,
                &pid, &input, &output, &diagnostics) }) == 0 else { throw PeerEnrollmentSupervisor.failure() }
            defer { for fd in [input,output,diagnostics] where fd >= 0 { tractanda_close(fd) } }
            tractanda_close(input); input = -1
            let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
            while tractanda_document_exited(pid) == 0 && DispatchTime.now().uptimeNanoseconds < deadline { _ = poll(nil, 0, 20) }
            // PID remains waitable until the exact owned group has been signalled/reaped.
            if tractanda_document_exited(pid) != 1 { _ = kill(-pid, SIGTERM); _ = poll(nil, 0, 100) }
            if tractanda_document_exited(pid) != 1 { _ = kill(-pid, SIGKILL) }
            var status: Int32 = 0, result: Int32
            repeat { result = waitpid(pid, &status, 0) } while result < 0 && errno == EINTR
            XCTAssertEqual(result, pid); XCTAssertEqual(status, 0)
            print("SUPERVISOR-ACL-CHILD pid=\(pid) status=\(status) reaped=\(result == pid)")
        }
        defer { try? chmod(["-N"]) } // Remove deny-delete before the enclosing guarded-root cleanup.
        try chmod(["-N"]); XCTAssertEqual(tractanda_validate_enrollment_helper(helper.path, 0), 0)
        try chmod(["+a", "everyone deny delete"]); XCTAssertEqual(tractanda_validate_enrollment_helper(helper.path, 0), 0)
        try chmod(["+a", "everyone allow write"]); XCTAssertNotEqual(tractanda_validate_enrollment_helper(helper.path, 0), 0)
        #endif
        XCTAssertTrue(try PeerEnrollmentSupervisor.actualImage().path.hasPrefix("/"))
        let argv = try PeerEnrollmentSupervisor.sudoArguments(user: "isolated-user", helper: helper, arguments: ["fixed", "/root with spaces"])
        XCTAssertEqual(argv, ["-n", "-u", "isolated-user", "--", helper.path, "fixed", "/root with spaces"])
        XCTAssertThrowsError(try PeerEnrollmentSupervisor.sudoArguments(user: "-root", helper: helper, arguments: []))
    }
    func testConnectIncludesTinyAbsoluteDeadlineWithoutSendingRequest() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("s").path, listener = tractanda_listen(path)
        XCTAssertGreaterThanOrEqual(listener, 0); guard listener >= 0 else { return }
        var clients: [Int32] = []; defer { clients.forEach { tractanda_close($0) }; tractanda_close(listener) }
        var refused = false
        let start = try PeerEnrollmentSupervisor.Job.now()
        for _ in 0..<128 {
            let fd = tractanda_private_connect_until(path, try PeerEnrollmentSupervisor.Job.now() + 20_000_000)
            if fd < 0 { refused = true; break }; clients.append(fd)
        }
        XCTAssertTrue(refused, "Saturated unaccepted UNIX queue must refuse or expire rather than block")
        XCTAssertLessThan(try PeerEnrollmentSupervisor.Job.now() - start, 1_000_000_000)
        XCTAssertLessThan(tractanda_private_connect_until(path, try PeerEnrollmentSupervisor.Job.now() - 1), 0)
        // No native request or secret frame is ever written by this probe.
    }
    func testSourceChunkAndHelperReplyRejectShortOffsetDescriptorAndOldVersion() throws {
        let f = try PeerTargetEnrollmentTests.Fixture(test: name, proofSource: "PeerEnrollmentSupervisorTests")
        let object = f.material.baseline.root
        let actual = try f.source.readPeerEnrollment(.init(operationID: f.operation), object: object, offset: 0,
            maximumBytes: min(64, object.length), forUID: f.uid)
        let encoded = try JSON.encode(PeerEnrollmentNativeChunk(object: object, offset: 0, bytes: actual.bytes))
        XCTAssertEqual(try NativePeerEnrollment.checkedChunk(encoded, object: object, offset: 0, maximumBytes: min(64,object.length)).bytes, actual.bytes)
        for data in [try JSON.encode(PeerEnrollmentNativeChunk(object: object, offset: 1, bytes: actual.bytes)),
                     try JSON.encode(PeerEnrollmentNativeChunk(object: object, offset: 0, bytes: actual.bytes.dropLast()))] {
            XCTAssertThrowsError(try NativePeerEnrollment.checkedChunk(data, object: object, offset: 0, maximumBytes: min(64,object.length)))
        }
        let requests: [PeerTargetEnrollment.Request] = [
            .init(operation: "resume", packageID: f.material.baseline.packageID, advance: false),
            .init(operation: "append", packageID: f.material.baseline.packageID, ordinal: 0, offset: 0),
            .init(operation: "finish"), .init(operation: "close")]
        for request in requests {
            let encoded = try PeerEnrollmentSupervisor.encodedRequest(request)
            let ordinary = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertEqual(ordinary["operation"] as? String, request.operation)
            XCTAssertEqual(try PeerTargetEnrollment.Request.decode(encoded).operation, request.operation)
            if request.operation == "resume" { XCTAssertEqual(ordinary["advance"] as? Bool, false) }
            if request.operation == "append" { XCTAssertEqual(ordinary["offset"] as? Int, 0) }
        }
        let ready = try JSON.encode(PeerTargetEnrollment.Reply("ready"))
        XCTAssertEqual(try PeerEnrollmentSupervisor.checkedReply(ready, expected: "ready").operation, "ready")
        let old = Data(String(decoding: ready, as: UTF8.self).replacingOccurrences(of: ".v2", with: ".v1").utf8)
        XCTAssertThrowsError(try PeerEnrollmentSupervisor.checkedReply(old, expected: "ready"))
        XCTAssertThrowsError(try PeerEnrollmentSupervisor.checkedReply(ready, expected: "closed"))
        var error = PeerTargetEnrollment.Reply("error"); error.code = "peerRepairRequired"
        XCTAssertThrowsError(try PeerEnrollmentSupervisor.checkedReply(JSON.encode(error), expected: "page")) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "peerRepairRequired")
        }
        error.packageID = object.id
        XCTAssertThrowsError(try PeerEnrollmentSupervisor.checkedReply(JSON.encode(error), expected: "page")) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "invalidHelperReply")
        }
        let record = try PeerEnrollmentTargetOutput.decode(f.bytes).0
        let ackData = try f.source.nativeEnrollmentCall(.init(action: "register", operationID: f.operation), forUID: f.uid)
        let ack = try JSON.decode(PeerEnrollmentOperatorStatus.self, ackData)
        XCTAssertEqual(ack.phase, "registered"); XCTAssertNil(ack.baselineManifest)
        let sequence = try AuthorityStore.configurationSequence(root: f.sourceRoot)
        let files = InitialAuthorityBootstrap.files(f.sourceRoot)
        let marker = [PeerEnrollmentActivation.sourceDirectory, f.operation, "registered.json"]
        let intent = [PeerEnrollmentActivation.sourceDirectory, f.operation, "configuration.json"]
        let markerBefore = try files.read(path: marker, maximumBytes: PeerEnrollmentActivation.maximumBytes)
        let intentBefore = try files.read(path: intent, maximumBytes: PeerEnrollmentActivation.maximumBytes)
        var phase = "readonlyStatus"
        do {
            let inspection = try f.source.nativeEnrollmentStatus(f.operation, forUID: f.uid)
            XCTAssertEqual(inspection.phase, "accepted")
            phase = "registerAgain"
            let repeated = try f.source.nativeEnrollmentCall(.init(action: "register", operationID: f.operation), forUID: f.uid)
            XCTAssertEqual(repeated, ackData)
        } catch {
            let code = (error as? TractandaError)?.code ?? "untyped"
            let safeCode = code.utf8.count <= 64 && code.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) ? code : "unclassified"
            print("B1-CORE-REPLAY phase=\(phase) code=\(safeCode) parentCancelled=\(Task.isCancelled)")
            throw error
        }
        XCTAssertEqual(try AuthorityStore.configurationSequence(root: f.sourceRoot), sequence)
        XCTAssertEqual(try files.read(path: marker, maximumBytes: PeerEnrollmentActivation.maximumBytes), markerBefore)
        XCTAssertEqual(try files.read(path: intent, maximumBytes: PeerEnrollmentActivation.maximumBytes), intentBefore)
        let markerURL = marker.reduce(f.sourceRoot) { $0.appendingPathComponent($1) }
        let conflicting = Data("conflicting isolated registration acknowledgement".utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: markerURL.path)
        try conflicting.write(to: markerURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: markerURL.path)
        XCTAssertThrowsError(try f.source.nativeEnrollmentCall(.init(action: "register", operationID: f.operation), forUID: f.uid)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "enrollmentActivationRequired")
        }
        XCTAssertEqual(try files.read(path: marker, maximumBytes: PeerEnrollmentActivation.maximumBytes), conflicting)
        XCTAssertEqual(try files.read(path: intent, maximumBytes: PeerEnrollmentActivation.maximumBytes), intentBefore)
        XCTAssertEqual(try AuthorityStore.configurationSequence(root: f.sourceRoot), sequence)
        XCTAssertNoThrow(try PeerEnrollmentSupervisor.validate(ack, operationID: f.operation, record: record, registered: true))
        XCTAssertThrowsError(try PeerEnrollmentSupervisor.validate(ack, operationID: f.operation, record: record))
        let wrong = PeerEnrollmentOperatorStatus(operationID: ack.operationID, phase: ack.phase, storeID: ack.storeID,
            sourceReplicaID: ack.sourceReplicaID, targetReplicaID: try UUID.makeVersion1().uuidString.lowercased(),
            bootstrap: ack.bootstrap, approval: ack.approval, baselineManifest: nil)
        XCTAssertThrowsError(try PeerEnrollmentSupervisor.validate(wrong, operationID: f.operation, record: record, registered: true))
        try f.capacity()
    }
}
