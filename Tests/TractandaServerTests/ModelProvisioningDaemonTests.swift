import Foundation
import Crypto
import XCTest
import TractandaClient
@testable import TractandaCore
@testable import TractandaServer
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class ModelProvisioningDaemonTests: XCTestCase {
    func testHeldModelTransferLeavesDaemonActorsStatusWritesAndFTSUsable() async throws {
        let outsideTask = try await ModelProvisioningRuntime.runBlocking { withUnsafeCurrentTask { $0 == nil } }
        XCTAssertTrue(outsideTask, "Blocking provision/hash work must leave the cooperative task executor.")
        #if os(macOS)
        let parent = URL(fileURLWithPath: "/private/tmp")
        #else
        let parent = URL(fileURLWithPath: "/tmp")
        #endif
        let root = parent.appendingPathComponent("th-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data(repeating: 0x5a, count: 32768)
        let artifact = ModelArtifactManifest(identifier: "granite-docling-258m-mlx", repository: "fixture/docling", revision: String(repeating: "a", count: 40),
            files: [.init(path: "model.safetensors", size: Int64(data.count), sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())])
        let manifest = root.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(ModelProvisioningCatalog(artifacts: [artifact])).write(to: manifest)
        let script = root.appendingPathComponent("server.py")
        try Data("""
        import http.server,socketserver,sys,os,time,signal
        signal.pthread_sigmask(signal.SIG_UNBLOCK,{signal.SIGTERM,signal.SIGINT})
        signal.signal(signal.SIGTERM,signal.SIG_DFL)
        held=sys.argv[1]; release=sys.argv[2]
        class H(http.server.BaseHTTPRequestHandler):
          def log_message(self,*args): pass
          def do_GET(self):
            data=b'Z'*32768
            self.send_response(200); self.send_header('Content-Length',str(len(data))); self.end_headers()
            self.wfile.write(data[:8192]); self.wfile.flush()
            open(held,'w').close()
            while not os.path.exists(release): time.sleep(0.01)
            self.wfile.write(data[8192:]); self.wfile.flush()
        with socketserver.TCPServer(('127.0.0.1',0),H) as server:
          print(server.server_address[1],flush=True); server.serve_forever()
        """.utf8).write(to: script)
        let held = root.appendingPathComponent("held"); let release = root.appendingPathComponent("release")
        let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [script.path, held.path, release.path]
        let portPipe = Pipe(); server.standardOutput = portPipe; server.standardError = FileHandle.nullDevice
        try server.run(); defer { if server.isRunning { server.terminate() }; server.waitUntilExit() }
        var line = Data()
        while let byte = try portPipe.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data([10]) { line.append(byte) }
        let port = try XCTUnwrap(Int(String(decoding: line, as: UTF8.self)))
        // This is a deadlock cleanup fence, not a hardware-speed requirement. The assertions
        // below require core replies before the test deliberately releases the held response.
        let failSafe = DispatchWorkItem { try? Data().write(to: release) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30, execute: failSafe)
        defer { failSafe.cancel(); try? Data().write(to: release) }
        let store = root.appendingPathComponent("store")
        do { _ = try ItemStore.initializeFresh(root: store) }
        let models = root.appendingPathComponent("models"); let socket = root.appendingPathComponent("s").path
        let converter = DocumentConverterConfiguration(executablePath: "/usr/bin/true", modelDirectory: artifact.directory(in: models).path,
            scratchDirectory: root.appendingPathComponent("scratch").path, modelArtifact: artifact, modelStorageDirectory: models.path)
        let daemon = try await SharedDaemon.startForTesting(configuration: .init(storePath: store.path, socketPath: socket, httpPort: nil,
            documentConverter: converter, modelProvisioning: .init(manifestPath: manifest.path, storageDirectory: models.path)),
            makeAccountDirectory: { SystemAccountDirectory() }, modelProvisioningOriginForTesting: URL(string: "http://127.0.0.1:\(port)")!)
        do {
            for _ in 0..<1000 {
                if FileManager.default.fileExists(atPath: held.path) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: held.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: release.path))
            func call(_ method: String, _ arguments: [String: Any]) async throws -> [String: Any] {
                let request = try JSONSerialization.data(withJSONObject: ["using": TractandaJMAP.using, "methodCalls": [[method, arguments, "m"]]])
                let reply = try await ModelProvisioningRuntime.runBlocking { try LocalTransport.call(socket: socket, request: request) }
                let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
                let response = try XCTUnwrap((envelope["methodResponses"] as? [[Any]])?.first)
                XCTAssertEqual(response[0] as? String, method, String(decoding: reply, as: UTF8.self))
                return try XCTUnwrap(response[1] as? [String: Any])
            }
            let discovery = try await call(TractandaJMAP.discoveryMethod, [:])
            let account = try XCTUnwrap((discovery["accounts"] as? [String: Any])?.keys.first)
            let info = try await call("TractandaStore/info", ["accountId": account])
            XCTAssertEqual((info["documentExtraction"] as? [String: Any])?["state"] as? String, "awaitingModel")
            let status = try await call("TractandaModel/status", ["accountId": account])
            XCTAssertEqual((status["artifacts"] as? [[String: Any]])?.first?["phase"] as? String, "downloading")
            let commit = CommitRequest(classID: "Item", changes: ["subject": .text("heldtransferneedle")], operationID: "held-model-write")
            var commitArguments = try XCTUnwrap(JSONSerialization.jsonObject(with: JSON.encode(commit)) as? [String: Any]); commitArguments["accountId"] = account
            _ = try await call("TractandaItem/commit", commitArguments)
            let query = try await call("TractandaItem/query", ["accountId": account, "filter": ["text": "heldtransferneedle"]])
            XCTAssertEqual((query["ids"] as? [String])?.count, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: release.path), "Core/actor/status/write/FTS replies must precede releasing the actual transfer.")
            XCTAssertFalse(ModelProvisioner.activated(artifact, root: models))
            failSafe.cancel(); try Data().write(to: release)
            for _ in 0..<1000 {
                if ModelProvisioner.activated(artifact, root: models) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(ModelProvisioner.activated(artifact, root: models))
            let readyInfo = try await call("TractandaStore/info", ["accountId": account])
            XCTAssertEqual((readyInfo["documentExtraction"] as? [String: Any])?["state"] as? String, "configured")
            await daemon.close()
        } catch { try? Data().write(to: release); await daemon.close(); throw error }
    }
    func testMissingDocumentModelDoesNotGateDaemonItemReadsOrFTS() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("tm-" + String(UUID().uuidString.prefix(8)))
        #if os(Linux)
        let physicalRoot = URL(fileURLWithPath: "/tmp").appendingPathComponent(root.lastPathComponent)
        #else
        let physicalRoot = root
        #endif
        try FileManager.default.createDirectory(at: physicalRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: physicalRoot) }
        let storeURL = physicalRoot.appendingPathComponent("store")
        let id: String
        do {
            let store = try ItemStore.initializeFresh(root: storeURL)
            id = try store.commit(.init(classID: "Item", changes: ["subject": .text("provisioncanary"), "body": .text("searchablewithoutmodels")], operationID: "model-test-note")).revision.itemID
        }
        let artifact = ModelArtifactManifest(identifier: "fixture", repository: "fixture/model", revision: String(repeating: "a", count: 40),
            files: [.init(path: "model.safetensors", size: 1, sha256: String(repeating: "0", count: 64))])
        let models = physicalRoot.appendingPathComponent("models")
        let converter = DocumentConverterConfiguration(executablePath: "/usr/bin/true", modelDirectory: artifact.directory(in: models).path,
            scratchDirectory: physicalRoot.appendingPathComponent("scratch").path, modelArtifact: artifact, modelStorageDirectory: models.path)
        let socket = physicalRoot.appendingPathComponent("s").path
        let daemon = try await SharedDaemon.start(configuration: .init(storePath: storeURL.path, socketPath: socket, httpPort: nil, documentConverter: converter))
        do {
            let discoveryRequest = try JSONSerialization.data(withJSONObject: ["using": TractandaJMAP.using,
                "methodCalls": [[TractandaJMAP.discoveryMethod, [String: String](), "discovery"]]])
            let discoveryReply = try await Task.detached { try LocalTransport.call(socket: socket, request: discoveryRequest) }.value
            let discoveryEnvelope = try XCTUnwrap(JSONSerialization.jsonObject(with: discoveryReply) as? [String: Any])
            let discoveryPayload = try XCTUnwrap((discoveryEnvelope["methodResponses"] as? [[Any]])?.first?[1] as? [String: Any])
            let account = try XCTUnwrap((discoveryPayload["accounts"] as? [String: Any])?.keys.first)
            func request(_ method: String, _ arguments: [String: Any] = [:]) throws -> Data {
                var args = arguments; args["accountId"] = account
                return try JSONSerialization.data(withJSONObject: ["using": TractandaJMAP.using, "methodCalls": [[method, args, "m"]]])
            }
            let infoRequest = try request("TractandaStore/info")
            let reply = try await Task.detached { try LocalTransport.call(socket: socket, request: infoRequest) }.value
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
            let response = try XCTUnwrap((envelope["methodResponses"] as? [[Any]])?.first)
            XCTAssertEqual(response[0] as? String, "TractandaStore/info", String(decoding: reply, as: UTF8.self))
            let info = try XCTUnwrap(response[1] as? [String: Any])
            XCTAssertEqual((info["documentExtraction"] as? [String: Any])?["state"] as? String, "awaitingModel")
            let modelRequest = try request("TractandaModel/status")
            let modelReply = try await Task.detached { try LocalTransport.call(socket: socket, request: modelRequest) }.value
            let modelEnvelope = try XCTUnwrap(JSONSerialization.jsonObject(with: modelReply) as? [String: Any])
            let modelResponse = try XCTUnwrap((modelEnvelope["methodResponses"] as? [[Any]])?.first)
            XCTAssertEqual(modelResponse[0] as? String, "TractandaModel/status", String(decoding: modelReply, as: UTF8.self))
            XCTAssertNotNil((modelResponse[1] as? [String: Any])?["artifacts"])
            let coordinator = await daemon.coordinatorForTesting()
            let query = try await coordinator.handle(request("TractandaItem/query", ["filter": ["text": "searchablewithoutmodels"]]), forUID: getuid())
            let result = try XCTUnwrap(JSONSerialization.jsonObject(with: query) as? [String: Any])
            let calls = try XCTUnwrap(result["methodResponses"] as? [[Any]])
            XCTAssertEqual(calls.first?.first as? String, "TractandaItem/query", String(decoding: query, as: UTF8.self))
            XCTAssertTrue(String(decoding: query, as: UTF8.self).contains(id), String(decoding: query, as: UTF8.self))
            await daemon.close()
        } catch { await daemon.close(); throw error }
    }
}
