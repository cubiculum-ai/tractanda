import Crypto
import XCTest

@testable import TractandaCore

final class DocumentCoordinatorIntegrationTests: XCTestCase {
    private final class Accounts: AccountDirectory, @unchecked Sendable {
        let alice: UInt32 = 61001
        private let lock = NSLock()
        private var admitted = true
        func revoke() {
            lock.lock()
            admitted = false
            lock.unlock()
        }
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            guard uid == getuid() || uid == alice else {
                throw TractandaError("unresolvedPrincipal", "Unknown test account")
            }
            lock.lock()
            let groups: Set<UInt32> = uid != alice || admitted ? [71001] : []
            lock.unlock()
            return AccountIdentity(
                uid: uid, name: uid == alice ? "alice" : "admin", primaryGroupName: "staff", groupIDs: groups)
        }
        func user(named name: String) throws -> AccountIdentity {
            guard ["alice", "admin"].contains(name) else {
                throw TractandaError("unresolvedPrincipal", "Unknown test account")
            }
            return try user(forUID: name == "alice" ? alice : getuid())
        }
        func groupID(named name: String) throws -> UInt32 {
            guard name == "staff" else { throw TractandaError("unresolvedPrincipal", "Unknown test group") }
            return 71001
        }
    }

    private struct Fixture {
        let directory: URL
        let storeRoot: URL
        let model: URL
        let configuration: DocumentConverterConfiguration
        let attached: Revision
        let descriptor: AttachmentDescriptor
    }

    private func fixture(
        accounts: Accounts? = nil, timeout: Double = 10, delay: Double = 0.25,
        handshake: Bool = false
    ) throws -> Fixture {
        try AttachmentFixtureCapacity.requireFree()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "document-coordinator-" + Identifier.make())
        let root = directory.appendingPathComponent("store")
        let model = directory.appendingPathComponent("fake-model")
        try FileManager.default.createDirectory(
            at: model, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let executable = directory.appendingPathComponent("fake-converter.py")
        let script = """
            #!/usr/bin/env python3
            import hashlib,json,pathlib,sys,time
            model,original,media,output=sys.argv[2:6]
            pathlib.Path(model,'started').write_text('ready')
            if \(handshake ? "True" : "False"):
                deadline=time.monotonic()+8
                while not pathlib.Path(model,'release').exists():
                    if time.monotonic()>deadline: raise RuntimeError('bounded handshake deadline')
                    time.sleep(0.01)
            else:
                time.sleep(\(delay))
            pathlib.Path(model,'finished').write_text('finished')
            mode=pathlib.Path(model,'mode')
            if mode.exists():
                if mode.read_text()=='output':
                    pathlib.Path(output).write_bytes(b'x'*(2*1024*1024+1))
                    raise SystemExit(0)
                if mode.read_text()=='log':
                    sys.stdout.write('x'*(64*1024+1))
                    raise SystemExit(0)
            identity={'converter':'tractanda.docling-native.v2-idefics3-gelu-f32','model':'ibm-granite/granite-docling-258M-mlx','modelRevision':'a8b999991fe8c521a0cec749973414eaaf823731','runtimeRevision':'61a4b20d4ad01b10466e8fc94c50402a9f994430','preprocessing':'opaque-rgb-content-crop-hf4561-pillow123-grid-v2','parser':'doctags-strict-v1'}
            if mode.exists() and mode.read_text()=='legacy':
                identity['preprocessing']='opaque-rgb2048-17tiles-v1'
                identity['converter']='tractanda.docling-native.v1'
            geometry={'sourceWidth':512,'sourceHeight':256,'sourceOriginX':0,'sourceOriginY':0,'sourceRotation':0,'sourceUnit':'pixel','displayWidth':512,'displayHeight':256,'canvasWidth':2048,'canvasHeight':1024,'contentLeft':0,'contentTop':0,'contentWidth':2048,'contentHeight':1024}
            page={'pageNumber':1,'geometry':geometry,'rasterSHA256':'b'*64,'rawDocTags':'<doctag><text>fixture-only conversion</text></doctag>','generatedTokens':40,'stopReason':'stop'}
            pathlib.Path(output).write_text(json.dumps({'identity':identity,'inputSHA256':hashlib.sha256(pathlib.Path(original).read_bytes()).hexdigest(),'pages':[page]}))
            """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let attached: Revision
        let descriptor: AttachmentDescriptor
        do {
            let store = try AttachmentFixtureCapacity.makeStore(
                root: root, accounts: accounts ?? SystemAccountDirectory())
            var changes: [String: ItemValue] = [:]
            if accounts != nil {
                _ = try store.configureAccess(
                    .object([
                        "profile": .text(AccessConfiguration.profile), "groups": .list([.text("staff")]),
                    ]), operationID: "admit")
                changes["permissions"] = .object([
                    "profile": .text(ItemPermissions.profile), "owner": .text("admin"),
                    "group": .text("staff"), "mode": .integer(0o660), "acl": .object([:]),
                ])
            }
            let base = try store.commit(
                CommitRequest(classID: "Item", changes: changes, operationID: "create")
            ).revision
            let data = Data([137, 80, 78, 71, 13, 10, 26, 10])
            let upload = try store.beginAttachment(
                AttachmentUploadRequest(
                    itemID: base.itemID, expectedRevisionID: base.revisionID, operationID: "attach",
                    filename: "fake.png",
                    mediaType: "image/png", byteCount: Int64(data.count),
                    sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
            _ = try store.appendAttachment(uploadID: XCTUnwrap(upload.uploadID), offset: 0, data: data)
            attached = try store.finishAttachment(uploadID: XCTUnwrap(upload.uploadID)).revision
            descriptor = upload.attachment
        }
        return Fixture(
            directory: directory, storeRoot: root, model: model,
            configuration: DocumentConverterConfiguration(
                executablePath: executable.path, modelDirectory: model.path,
                scratchDirectory: directory.appendingPathComponent("scratch").path, timeoutSeconds: timeout),
            attached: attached, descriptor: descriptor)
    }

    private func request(_ method: String, _ arguments: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "using": [ItemService.capability], "methodCalls": [[method, arguments, "test"]],
        ])
    }

    private func extraction(_ fixture: Fixture, operation: String = "extract") throws -> Data {
        try request(
            "TractandaAttachment/extractDocument",
            [
                "itemID": fixture.attached.itemID,
                "expectedRevisionID": fixture.attached.revisionID,
                "attachmentID": fixture.descriptor.attachmentID, "operationID": operation,
            ])
    }

    private func started(_ fixture: Fixture) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: fixture.model.appendingPathComponent("started").path) {
            guard ContinuousClock.now < deadline else {
                throw TractandaError("test", "Fake child did not start")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func errorCode(_ data: Data) throws -> String? {
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        if let code = root["code"] as? String { return code }
        let response = (root["methodResponses"] as? [[Any]])?.first
        return response?[0] as? String == "error" ? (response?[1] as? [String: Any])?["type"] as? String : nil
    }

    func testRetiredSynchronousRouteDoesNotStartConverterOrWriteContent() async throws {
        let fixture = try fixture(delay: 0)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let coordinator = try await ServiceCoordinator(
            opening: fixture.storeRoot, documentConverter: fixture.configuration)
        let result = try await coordinator.handle(extraction(fixture), forUID: getuid())
        XCTAssertEqual(try errorCode(result), "unknownMethod")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.model.appendingPathComponent("started").path))
        let get = try await coordinator.handle(
            request("TractandaItem/get", ["ids": [fixture.attached.itemID]]), forUID: getuid())
        XCTAssertFalse(String(decoding: get, as: UTF8.self).contains("attachmentDocument"))
        await coordinator.close()
    }

    func testMockedCapacityAndSmallOversizedOutputOrLogFailClosed() async throws {
        let fixture = try fixture(delay: 0)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try AttachmentFixtureCapacity.makeStore(root: fixture.storeRoot)
        try fixture.configuration.validate(storeRoot: fixture.storeRoot, indexDirectory: store.indexDirectory)
        guard
            case .prepared(let snapshot) = try store.prepareAttachmentDocument(
                itemID: fixture.attached.itemID, expectedRevisionID: fixture.attached.revisionID,
                attachmentID: fixture.descriptor.attachmentID, operationID: "guards", identity: .init())
        else { return XCTFail("Expected admission") }
        let binarySHA = try DocumentProcess.executableSHA256(fixture.configuration.executablePath)
        let providers: [@Sendable () throws -> UInt64] = [
            { 0 }, { throw TractandaError("test", "Capacity unavailable") },
        ]
        for provider in providers {
            XCTAssertThrowsError(
                try DocumentProcess.convert(
                    snapshot, configuration: fixture.configuration,
                    expectedExecutableSHA256: binarySHA, cancellation: DocumentConversionCancellation(),
                    availableBytes: provider)
            ) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
            }
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: fixture.model.appendingPathComponent("started").path))
        }
        for mode in ["output", "log"] {
            try Data(mode.utf8).write(to: fixture.model.appendingPathComponent("mode"))
            XCTAssertThrowsError(
                try DocumentProcess.convert(
                    snapshot, configuration: fixture.configuration,
                    expectedExecutableSHA256: binarySHA, cancellation: DocumentConversionCancellation())
            ) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
            }
            XCTAssertNil(try store.get(fixture.attached.itemID).fields["attachmentDocument"])
        }
    }
}
