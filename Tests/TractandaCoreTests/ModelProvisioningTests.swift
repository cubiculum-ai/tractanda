import Crypto
import Foundation
import XCTest
@testable import TractandaCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class ModelProvisioningTests: XCTestCase {
    private let bytes = Data(repeating: 0x5a, count: 32_768)
    private func fixture() throws -> URL {
        #if os(macOS)
        let parent = URL(fileURLWithPath: "/private/tmp")
        #else
        let parent = URL(fileURLWithPath: "/tmp")
        #endif
        let url = parent.appendingPathComponent("tractanda-model-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func artifact(_ data: Data? = nil, revision: String = String(repeating: "a", count: 40)) -> ModelArtifactManifest {
        let data = data ?? bytes
        return .init(identifier: "fixture", repository: "fixture/model", revision: revision,
            files: [.init(path: "model.safetensors", size: Int64(data.count), sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())])
    }
    private func source(_ root: URL, data: Data? = nil) throws -> URL {
        let folder = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try (data ?? bytes).write(to: folder.appendingPathComponent("model.safetensors")); return folder
    }
    func testOfflineImportActivatesOnlyVerifiedFullManifestAndReuses() throws {
        let base = try fixture(); let src = try source(base); let model = artifact()
        let worker = ModelProvisioner(root: base.appendingPathComponent("models"))
        try worker.provision(model, adopting: src, offline: true)
        XCTAssertTrue(worker.isReady(model)); XCTAssertTrue(ModelProvisioner.activated(model, root: worker.root))
        try FileManager.default.removeItem(at: src)
        try worker.provision(model, offline: true)
        XCTAssertEqual(worker.status().first?.phase, .ready)
    }
    func testActivationAndStatusMetadataArePrivateAcrossCallerUmasksAndReplacement() throws {
        let environment = ProcessInfo.processInfo.environment
        if let root = environment["TRACTANDA_MODEL_METADATA_ROOT"],
            let source = environment["TRACTANDA_MODEL_METADATA_SOURCE"],
            let rawMask = environment["TRACTANDA_MODEL_METADATA_UMASK"],
            let mask = mode_t(rawMask, radix: 8) {
            _ = umask(mask)
            let model = artifact(revision: String(repeating: "b", count: 40))
            let rootURL = URL(fileURLWithPath: root)
            let marker = model.activationMarker(in: rootURL)
            let status = rootURL.appendingPathComponent("incoming").appendingPathComponent(model.identity).appendingPathComponent("status.json")
            let worker = ModelProvisioner(root: rootURL)
            try worker.provision(model, adopting: URL(fileURLWithPath: source), offline: true)
            for path in [marker, status] {
                var metadata = stat()
                XCTAssertEqual(lstat(path.path, &metadata), 0)
                XCTAssertEqual(metadata.st_mode & mode_t(S_IFMT), mode_t(S_IFREG))
                XCTAssertEqual(metadata.st_mode & 0o777, 0o600, "Metadata mode must ignore caller umask \(mask).")
            }
            // Simulate the sudo umask failure on an older sidecar; a safe owner-owned regular
            // file is atomically replaced even when its old mode is group-writable.
            XCTAssertEqual(chmod(marker.path, 0o660), 0)
            XCTAssertEqual(chmod(status.path, 0o660), 0)
            try worker.provision(model, offline: true)
            for path in [marker, status] {
                var metadata = stat()
                XCTAssertEqual(lstat(path.path, &metadata), 0)
                XCTAssertEqual(metadata.st_mode & mode_t(S_IFMT), mode_t(S_IFREG))
                XCTAssertEqual(metadata.st_mode & 0o777, 0o600)
            }
            XCTAssertTrue(worker.isReady(model))
            return
        }

        let selector = "TractandaCoreTests.ModelProvisioningTests/testActivationAndStatusMetadataArePrivateAcrossCallerUmasksAndReplacement"
        for rawMask in ["000", "007", "022", "077"] {
            let base = try fixture(); let src = try source(base)
            let child = Process(); var childEnvironment = environment
            childEnvironment["TRACTANDA_MODEL_METADATA_ROOT"] = base.appendingPathComponent("models").path
            childEnvironment["TRACTANDA_MODEL_METADATA_SOURCE"] = src.path
            childEnvironment["TRACTANDA_MODEL_METADATA_UMASK"] = rawMask
            child.environment = childEnvironment
            #if os(macOS)
            child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            child.arguments = ["xctest", "-XCTest", selector, Bundle(for: Self.self).bundleURL.path]
            #else
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); child.arguments = [selector]
            #endif
            child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
            try child.run(); child.waitUntilExit()
            XCTAssertEqual(child.terminationStatus, 0, "Metadata writer failed under umask \(rawMask).")
        }
    }
    func testMetadataWriterRefusesSymlinkDestinationAndHardLinkedFile() throws {
        let base = try fixture()
        let destination = base.appendingPathComponent("metadata.json")
        let target = base.appendingPathComponent("target.json")
        try Data("preserve".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
        XCTAssertThrowsError(try ModelProvisioner.writePrivateMetadata(Data("replace".utf8), to: destination))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: target), Data("preserve".utf8))
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.linkItem(at: target, to: destination)
        XCTAssertThrowsError(try ModelProvisioner.writePrivateMetadata(Data("replace".utf8), to: destination))
        XCTAssertEqual(try Data(contentsOf: target), Data("preserve".utf8))

        let linkedParent = base.appendingPathComponent("linked-parent")
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: base)
        XCTAssertThrowsError(try ModelProvisioner.writePrivateMetadata(Data("new".utf8), to: linkedParent.appendingPathComponent("new.json")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("new.json").path))
    }
    func testPreinstallStagedPayloadActivatesWithoutSourceOrNetwork() throws {
        let base = try fixture(); let model = artifact(); let root = base.appendingPathComponent("models")
        let payload = root.appendingPathComponent("incoming").appendingPathComponent(model.identity).appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try bytes.write(to: payload.appendingPathComponent("model.safetensors"))
        let worker = ModelProvisioner(root: root)
        try worker.provision(model, offline: true)
        XCTAssertTrue(worker.isReady(model)); XCTAssertFalse(FileManager.default.fileExists(atPath: payload.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.deletingLastPathComponent().appendingPathComponent(".lock").path))
    }
    func testSiblingMarkerKeepsNestedInferenceDirectoryExactlyPinned() throws {
        let base = try fixture(); let src = try source(base); let first = artifact()
        let config = Data("{}".utf8); let nested = src.appendingPathComponent("1_Pooling/config.json")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try config.write(to: nested)
        let model = ModelArtifactManifest(identifier: first.identifier, repository: first.repository, revision: first.revision,
            files: first.files + [.init(path: "1_Pooling/config.json", size: Int64(config.count), sha256: SHA256.hash(data: config).map { String(format: "%02x", $0) }.joined())])
        let worker = ModelProvisioner(root: base.appendingPathComponent("models"))
        try worker.provision(model, adopting: src, offline: true)
        let directory = model.directory(in: worker.root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".verified.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.activationMarker(in: worker.root).path))
        let iterator = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        var files = Set<String>()
        for case let file as URL in iterator where (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            files.insert(String(file.path.dropFirst(directory.path.count + 1)))
        }
        XCTAssertEqual(files, Set(model.files.map(\.path)))
        XCTAssertTrue(worker.isReady(model)); XCTAssertTrue(ModelProvisioner.activated(model, root: worker.root))
    }
    func testMissingSiblingCommitRehashesValidDataWithoutImportOrDownload() throws {
        let base = try fixture(); let src = try source(base); let model = artifact()
        let worker = ModelProvisioner(root: base.appendingPathComponent("models"))
        try worker.provision(model, adopting: src, offline: true)
        let directory = model.directory(in: worker.root)
        let inode = try FileManager.default.attributesOfItem(atPath: directory.path)[.systemFileNumber] as? NSNumber
        try FileManager.default.removeItem(at: model.activationMarker(in: worker.root))
        try FileManager.default.removeItem(at: src)
        XCTAssertFalse(ModelProvisioner.activated(model, root: worker.root))
        try worker.provision(model, offline: true)
        XCTAssertTrue(worker.isReady(model))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.path)[.systemFileNumber] as? NSNumber, inode)
    }
    func testUnexpectedMetadataAndSymlinksCannotReportActivatedAssets() throws {
        for symlink in [false, true] {
            let base = try fixture(); let src = try source(base); let model = artifact()
            let worker = ModelProvisioner(root: base.appendingPathComponent("models"))
            try worker.provision(model, adopting: src, offline: true)
            let extra = model.directory(in: worker.root).appendingPathComponent(symlink ? "extra-link" : ".DS_Store")
            if symlink { try FileManager.default.createSymbolicLink(at: extra, withDestinationURL: src) }
            else { try Data([1]).write(to: extra) }
            XCTAssertFalse(ModelProvisioner.activated(model, root: worker.root)); XCTAssertFalse(worker.isReady(model))
            XCTAssertThrowsError(try worker.provision(model, offline: true))
            XCTAssertFalse(FileManager.default.fileExists(atPath: model.activationMarker(in: worker.root).path))
        }
    }
    func testWrongChecksumNeverActivatesAndOfflineFailureIsExplicit() throws {
        let base = try fixture(); let src = try source(base, data: Data(repeating: 3, count: bytes.count))
        let worker = ModelProvisioner(root: base.appendingPathComponent("models"))
        XCTAssertThrowsError(try worker.provision(.init(artifacts: [artifact()]), adoptionDirectories: ["fixture": src], offline: true))
        XCTAssertFalse(ModelProvisioner.activated(artifact(), root: worker.root))
        XCTAssertEqual(worker.status().first?.phase, .failed)
    }
    func testSameArtifactRevisionWithDifferentManifestCannotReuseActivation() throws {
        let base = try fixture(); let src = try source(base); let worker = ModelProvisioner(root: base.appendingPathComponent("models"))
        try worker.provision(artifact(), adopting: src, offline: true)
        let other = artifact(Data(repeating: 7, count: bytes.count))
        XCTAssertThrowsError(try worker.provision(other, offline: true)); XCTAssertFalse(worker.isReady(other))
    }
    func testCorruptedActivatedBytesFailFullVerification() throws {
        let base = try fixture(); let src = try source(base); let worker = ModelProvisioner(root: base.appendingPathComponent("models")); let model = artifact()
        try worker.provision(model, adopting: src, offline: true)
        try Data(repeating: 0, count: bytes.count).write(to: model.directory(in: worker.root).appendingPathComponent("model.safetensors"))
        XCTAssertFalse(worker.isReady(model)); XCTAssertThrowsError(try worker.provision(model, offline: true))
    }
    func testMissingActivatedFileInvalidatesReadinessAndRepairsFromOfflineSource() throws {
        let base = try fixture(); let src = try source(base); let model = artifact()
        let worker = ModelProvisioner(root: base.appendingPathComponent("models"))
        try worker.provision(model, adopting: src, offline: true)
        try FileManager.default.removeItem(at: model.directory(in: worker.root).appendingPathComponent("model.safetensors"))
        XCTAssertFalse(ModelProvisioner.activated(model, root: worker.root))
        try worker.provision(model, adopting: src, offline: true)
        XCTAssertTrue(worker.isReady(model)); XCTAssertTrue(ModelProvisioner.activated(model, root: worker.root))
    }
    func testCorruptActivatedFileIsRetainedUntilVerifiedOfflineReplacement() throws {
        let base = try fixture(); let src = try source(base); let model = artifact()
        let worker = ModelProvisioner(root: base.appendingPathComponent("models"))
        try worker.provision(model, adopting: src, offline: true)
        try Data(repeating: 3, count: bytes.count).write(to: model.directory(in: worker.root).appendingPathComponent("model.safetensors"))
        try worker.provision(model, adopting: src, offline: true)
        XCTAssertTrue(worker.isReady(model))
        let stage = worker.root.appendingPathComponent("incoming").appendingPathComponent(model.identity)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: stage.path).contains { $0.hasPrefix("rejected-") })
    }
    func testActivationWithoutMarkerRecoversThroughVerifiedImport() throws {
        let base = try fixture(); let src = try source(base); let model = artifact()
        let worker = ModelProvisioner(root: base.appendingPathComponent("models"))
        try worker.provision(model, adopting: src, offline: true)
        try FileManager.default.removeItem(at: model.activationMarker(in: worker.root))
        XCTAssertFalse(ModelProvisioner.activated(model, root: worker.root))
        try worker.provision(model, adopting: src, offline: true)
        XCTAssertTrue(worker.isReady(model))
    }
    func testMissingSecondFileDoesNotPublishPartialModel() throws {
        let base = try fixture(); let src = try source(base); let model = artifact()
        let two = ModelArtifactManifest(identifier: model.identifier, repository: model.repository, revision: model.revision,
            files: model.files + [.init(path: "config.json", size: 1, sha256: String(repeating: "0", count: 64))])
        let worker = ModelProvisioner(root: base.appendingPathComponent("models"))
        XCTAssertThrowsError(try worker.provision(two, adopting: src, offline: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: two.directory(in: worker.root).path))
    }
    func testInsufficientDiskReserveRefusesCopy() throws {
        let base = try fixture(); let src = try source(base)
        let worker = ModelProvisioner(root: base.appendingPathComponent("models"), capacity: { 10 * 1024 * 1024 * 1024 })
        XCTAssertThrowsError(try worker.provision(artifact(), adopting: src, offline: true)) { XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit") }
    }
    func testSymlinkedModelRootRefusedWithoutChangingDestination() throws {
        let base = try fixture(); let src = try source(base); let root = base.appendingPathComponent("models")
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: src)
        XCTAssertThrowsError(try ModelProvisioner(root: root).provision(artifact(), adopting: src, offline: true))
        XCTAssertEqual(try Data(contentsOf: src.appendingPathComponent("model.safetensors")), bytes)
    }
    func testSymlinkImportRefusedAndExternalBytesUntouched() throws {
        let base = try fixture(); let src = try source(base); let external = src.appendingPathComponent("external.safetensors")
        try bytes.write(to: external); try FileManager.default.removeItem(at: src.appendingPathComponent("model.safetensors"))
        try FileManager.default.createSymbolicLink(at: src.appendingPathComponent("model.safetensors"), withDestinationURL: external)
        XCTAssertThrowsError(try ModelProvisioner(root: base.appendingPathComponent("models")).provision(artifact(), adopting: src, offline: true))
        XCTAssertEqual(try Data(contentsOf: external), bytes)
    }
    func testCancellationBeforeTransferLeavesNoActivation() throws {
        let base = try fixture(); let worker = ModelProvisioner(root: base.appendingPathComponent("models")); worker.cancel()
        XCTAssertThrowsError(try worker.provision(.init(artifacts: [artifact()]), retry: false)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(worker.status().first?.phase, .cancelled)
    }
    func testManifestRejectsUnpinnedTraversalCodeAndDuplicateFiles() throws {
        let model = artifact(); let file = model.files[0]
        for bad in ["../model.safetensors", "/model.safetensors", "nested//model.safetensors", "code.py", ".verified.json", "model.safetensors?query=1"] {
            XCTAssertThrowsError(try ModelArtifactManifest(identifier: model.identifier, repository: model.repository, revision: model.revision,
                files: [.init(path: bad, size: file.size, sha256: file.sha256)]).validate())
        }
        XCTAssertThrowsError(try artifact(revision: "main").validate())
        XCTAssertThrowsError(try ModelArtifactManifest(identifier: "../bad", repository: model.repository, revision: model.revision, files: [file]).validate())
        XCTAssertThrowsError(try ModelArtifactManifest(identifier: model.identifier, repository: "https://other/model", revision: model.revision, files: [file]).validate())
        XCTAssertThrowsError(try ModelArtifactManifest(identifier: model.identifier, repository: model.repository, revision: model.revision, files: [file, file]).validate())
    }
    func testMissingDocumentModelCanBeConfiguredButIsNotReady() throws {
        let base = try fixture(); let model = artifact(); let models = base.appendingPathComponent("models")
        let config = DocumentConverterConfiguration(executablePath: "/usr/bin/true", modelDirectory: model.directory(in: models).path,
            scratchDirectory: base.appendingPathComponent("scratch").path, modelArtifact: model, modelStorageDirectory: models.path)
        try config.validate(storeRoot: base.appendingPathComponent("store"), indexDirectory: base.appendingPathComponent("index"))
        XCTAssertFalse(config.modelIsReady)
        try ModelProvisioner(root: models).provision(model, adopting: source(base), offline: true)
        XCTAssertTrue(config.modelIsReady)
    }

    private func server(_ base: URL, mode: String) throws -> (Process, URL) {
        let script = base.appendingPathComponent("server.py")
        try Data("""
        import http.server,socketserver,sys,time,signal
        signal.pthread_sigmask(signal.SIG_UNBLOCK,{signal.SIGTERM,signal.SIGINT})
        signal.signal(signal.SIGTERM,signal.SIG_DFL)
        data=b'Z'*32768
        mode=sys.argv[1]; log=sys.argv[2]; requests=0
        class Handler(http.server.BaseHTTPRequestHandler):
          def log_message(self,*a): pass
          def do_GET(self):
            global requests
            requests+=1
            r=self.headers.get('Range',''); start=int(r[6:-1]) if r else 0
            with open(log,'a') as f: f.write(r+'\\n')
            if mode=='slow': time.sleep(1)
            if mode=='redirect' and self.path!='/resolved':
              body=b'R'*40000
              self.send_response(307); self.send_header('Location','/resolved'); self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body); return
            self.send_response(206 if r and mode!='ignore' else 200)
            if r and mode!='ignore': self.send_header('Content-Range',f'bytes {start}-{len(data)-1}/{len(data)}')
            out=data[start:] if mode!='ignore' else data
            if mode=='oversize': out=data+data
            self.send_header('Content-Length',str(len(out))); self.end_headers()
            if (mode=='interrupt' and not r) or (mode=='ignore' and requests==1): self.wfile.write(out[:8192]); self.wfile.flush(); self.close_connection=True
            elif mode=='blocked':
              self.wfile.write(out[:8192]); self.wfile.flush()
              while not __import__('os').path.exists(log+'.release'): time.sleep(0.01)
              self.wfile.write(out[8192:]); self.wfile.flush()
            elif mode=='bad': self.wfile.write(b'X'*len(out))
            else: self.wfile.write(out)
        with socketserver.TCPServer(('127.0.0.1',0),Handler) as s:
          print(s.server_address[1],flush=True); s.serve_forever()
        """.utf8).write(to: script)
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = [script.path, mode, base.appendingPathComponent("requests.txt").path]
        let pipe = Pipe(); child.standardOutput = pipe; child.standardError = FileHandle.nullDevice
        try child.run(); addTeardownBlock { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        var line = Data()
        while let data = try pipe.fileHandleForReading.read(upToCount: 1), !data.isEmpty, data != Data([10]) { line.append(data) }
        let port = try XCTUnwrap(Int(String(decoding: line, as: UTF8.self)))
        return (child, URL(string: "http://127.0.0.1:\(port)")!)
    }
    func testInterruptedHTTPTransferResumesFromActualPartialLength() throws {
        let base = try fixture(); let (_, origin) = try server(base, mode: "interrupt")
        let worker = ModelProvisioner(root: base.appendingPathComponent("models"), testingOrigin: origin); let model = artifact()
        XCTAssertThrowsError(try worker.provision(model))
        XCTAssertFalse(ModelProvisioner.activated(model, root: worker.root))
        try worker.provision(model)
        XCTAssertTrue(worker.isReady(model))
        XCTAssertTrue(try String(contentsOf: base.appendingPathComponent("requests.txt"), encoding: .utf8).contains("bytes=8192-"))
    }
    func testIgnoredResumeRangeDiscardsAmbiguousPartialBeforeCleanRetry() throws {
        let base = try fixture(); let (_, origin) = try server(base, mode: "ignore")
        let worker = ModelProvisioner(root: base.appendingPathComponent("models"), testingOrigin: origin); let model = artifact()
        XCTAssertThrowsError(try worker.provision(model))
        XCTAssertThrowsError(try worker.provision(model))
        XCTAssertFalse(ModelProvisioner.activated(model, root: worker.root))
        try worker.provision(model)
        XCTAssertTrue(worker.isReady(model))
        XCTAssertTrue(try String(contentsOf: base.appendingPathComponent("requests.txt"), encoding: .utf8).contains("bytes=8192-"))
    }
    func testCancellationTerminatesOwnedTransferAndPreservesNoActivation() throws {
        let base = try fixture(); let (_, origin) = try server(base, mode: "slow")
        let worker = ModelProvisioner(root: base.appendingPathComponent("models"), testingOrigin: origin); let model = artifact()
        let errors = ModelTestErrors(); let group = DispatchGroup(); group.enter()
        DispatchQueue.global().async { defer { group.leave() }; do { try worker.provision(.init(artifacts: [model]), retry: false) } catch { errors.append(error) } }
        for _ in 0..<100 where worker.status().first?.phase != .downloading { Thread.sleep(forTimeInterval: 0.01) }
        worker.cancel()
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(errors.count, 1); XCTAssertEqual(worker.status().first?.phase, .cancelled)
        XCTAssertFalse(ModelProvisioner.activated(model, root: worker.root))
    }
    func testRedirectMetadataCanExceedPinnedFinalFileWithoutChangingActivationSize() throws {
        let base = try fixture(); let (_, origin) = try server(base, mode: "redirect")
        let worker = ModelProvisioner(root: base.appendingPathComponent("models"), testingOrigin: origin); let model = artifact()
        try worker.provision(model)
        XCTAssertTrue(worker.isReady(model))
        XCTAssertEqual(try Data(contentsOf: model.directory(in: worker.root).appendingPathComponent("model.safetensors")), bytes)
        XCTAssertEqual(try String(contentsOf: base.appendingPathComponent("requests.txt"), encoding: .utf8).filter { $0 == "\n" }.count, 2)
    }
    func testRedirectAllowanceNeverAdmitsAnOversizedFinalPayload() throws {
        let base = try fixture(); let (_, origin) = try server(base, mode: "oversize")
        let worker = ModelProvisioner(root: base.appendingPathComponent("models"), testingOrigin: origin); let model = artifact()
        XCTAssertThrowsError(try worker.provision(model))
        XCTAssertFalse(ModelProvisioner.activated(model, root: worker.root)); XCTAssertFalse(worker.isReady(model))
    }
    func testHTTPChecksumMismatchNeverPublishes() throws {
        let base = try fixture(); let (_, origin) = try server(base, mode: "bad")
        let worker = ModelProvisioner(root: base.appendingPathComponent("models"), testingOrigin: origin)
        XCTAssertThrowsError(try worker.provision(artifact())); XCTAssertFalse(ModelProvisioner.activated(artifact(), root: worker.root))
    }
    func testCancellationReapsTransferBeforeHeldResponseIsReleased() throws {
        let base = try fixture(); let (_, origin) = try server(base, mode: "blocked"); let model = artifact()
        let worker = ModelProvisioner(root: base.appendingPathComponent("models"), testingOrigin: origin)
        let errors = ModelTestErrors(); let group = DispatchGroup(); group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            do { try worker.provision(.init(artifacts: [model]), retry: false) } catch { errors.append(error) }
        }
        let partial = worker.root.appendingPathComponent("incoming").appendingPathComponent(model.identity).appendingPathComponent("payload/model.safetensors")
        var held = false
        for _ in 0..<500 {
            let size = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.intValue ?? 0
            if size >= 8192 { held = true; break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(held, "Cancellation must target an actual held transfer, never a pre-start waiter.")
        let release = base.appendingPathComponent("requests.txt.release")
        defer { try? Data().write(to: release) }
        worker.cancel()
        let completed = group.wait(timeout: .now() + 10)
        XCTAssertEqual(completed, .success, "Explicit cancellation must reap the child while its server response remains held.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: release.path))
        XCTAssertEqual(errors.count, 1); XCTAssertEqual(worker.status().first?.phase, .cancelled)
        XCTAssertFalse(ModelProvisioner.activated(model, root: worker.root))
        if completed == .success {
            let lockFD = open(model.coordinationLock(in: worker.root).path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(lockFD, 0)
            if lockFD >= 0 {
                let acquired = flock(lockFD, LOCK_EX | LOCK_NB)
                XCTAssertEqual(acquired, 0, "No surviving child may retain or write the artifact after cancellation returned.")
                if acquired == 0 { _ = flock(lockFD, LOCK_UN) }; _ = close(lockFD)
            }
        }
    }
    func testAbruptOwnerDeathKeepsSurvivingTransferLockedUntilItExits() throws {
        let environment = ProcessInfo.processInfo.environment
        if let root = environment["TRACTANDA_MODEL_OWNER_CRASH_ROOT"], let origin = environment["TRACTANDA_MODEL_OWNER_CRASH_ORIGIN"] {
            try Data(String(getpid()).utf8).write(to: URL(fileURLWithPath: root).appendingPathComponent("owner.pid"))
            let worker = ModelProvisioner(root: URL(fileURLWithPath: root).appendingPathComponent("models"), testingOrigin: URL(string: origin)!)
            try worker.provision(artifact())
            _exit(73)
        }
        let base = try fixture(); let (_, origin) = try server(base, mode: "blocked"); let model = artifact()
        let child = Process(); var childEnvironment = environment
        childEnvironment["TRACTANDA_MODEL_OWNER_CRASH_ROOT"] = base.path
        childEnvironment["TRACTANDA_MODEL_OWNER_CRASH_ORIGIN"] = origin.absoluteString
        child.environment = childEnvironment
        let selector = "TractandaCoreTests.ModelProvisioningTests/testAbruptOwnerDeathKeepsSurvivingTransferLockedUntilItExits"
        #if os(macOS)
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest", selector, Bundle(for: Self.self).bundleURL.path]
        #else
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); child.arguments = [selector]
        #endif
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run()
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        let models = base.appendingPathComponent("models")
        let stage = models.appendingPathComponent("incoming").appendingPathComponent(model.identity)
        let partial = stage.appendingPathComponent("payload/model.safetensors")
        var started = false
        for _ in 0..<500 {
            let size = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.intValue ?? 0
            if size >= 8192 { started = true; break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(started, "The tiny transfer must actually be in progress before the owner is killed.")
        guard started else { return }
        let ownerPID = try XCTUnwrap(Int32(String(contentsOf: base.appendingPathComponent("owner.pid"), encoding: .utf8)))
        XCTAssertEqual(kill(ownerPID, SIGKILL), 0); child.waitUntilExit()
        let lockFD = open(model.coordinationLock(in: models).path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(lockFD, 0); defer { if lockFD >= 0 { _ = close(lockFD) } }
        guard lockFD >= 0 else { return }
        let acquired = flock(lockFD, LOCK_EX | LOCK_NB)
        if acquired == 0 { _ = flock(lockFD, LOCK_UN) }
        XCTAssertNotEqual(acquired, 0, "Surviving curl must retain the artifact lock after abrupt owner death.")
        let worker = ModelProvisioner(root: models, testingOrigin: origin); let errors = ModelTestErrors(); let group = DispatchGroup(); group.enter()
        DispatchQueue.global().async { defer { group.leave() }; do { try worker.provision(model) } catch { errors.append(error) } }
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertFalse(ModelProvisioner.activated(model, root: models))
        try Data().write(to: base.appendingPathComponent("requests.txt.release"))
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success); XCTAssertEqual(errors.count, 0)
        XCTAssertTrue(worker.isReady(model))
        XCTAssertEqual(try String(contentsOf: base.appendingPathComponent("requests.txt"), encoding: .utf8).filter { $0 == "\n" }.count, 1)
    }
    func testDifferentManifestsForOneRevisionSerializeBeforeReadyCommit() throws {
        let base = try fixture(); let (_, origin) = try server(base, mode: "blocked"); let model = artifact()
        let other = artifact(Data(repeating: 3, count: bytes.count))
        let first = ModelProvisioner(root: base.appendingPathComponent("models"), testingOrigin: origin)
        let second = ModelProvisioner(root: first.root, testingOrigin: origin)
        let firstErrors = ModelTestErrors(); let secondErrors = ModelTestErrors(); let group = DispatchGroup()
        group.enter(); DispatchQueue.global().async { defer { group.leave() }; do { try first.provision(model) } catch { firstErrors.append(error) } }
        let partial = first.root.appendingPathComponent("incoming").appendingPathComponent(model.identity).appendingPathComponent("payload/model.safetensors")
        for _ in 0..<500 {
            if ((try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.intValue ?? 0) >= 8192 { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        group.enter(); DispatchQueue.global().async { defer { group.leave() }; do { try second.provision(other, offline: true) } catch { secondErrors.append(error) } }
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(second.status().first?.phase, .waiting)
        XCTAssertFalse(ModelProvisioner.activated(model, root: first.root))
        try Data().write(to: base.appendingPathComponent("requests.txt.release"))
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(firstErrors.count, 0); XCTAssertEqual(secondErrors.count, 1)
        XCTAssertTrue(first.isReady(model)); XCTAssertFalse(second.isReady(other))
        let marker = try JSONDecoder().decode(ModelArtifactManifest.self, from: Data(contentsOf: model.activationMarker(in: first.root)))
        XCTAssertEqual(marker, model)
    }
    func testConcurrentProvisionersShareOneVerifiedDownload() throws {
        let base = try fixture(); let (_, origin) = try server(base, mode: "slow"); let model = artifact()
        let a = ModelProvisioner(root: base.appendingPathComponent("models"), testingOrigin: origin)
        let b = ModelProvisioner(root: a.root, testingOrigin: origin)
        let errors = ModelTestErrors(); let group = DispatchGroup()
        for worker in [a,b] { group.enter(); DispatchQueue.global().async { defer { group.leave() }; do { try worker.provision(model) } catch { errors.append(error) } } }
        XCTAssertEqual(group.wait(timeout: .now() + 15), .success); XCTAssertEqual(errors.count, 0)
        XCTAssertTrue(a.isReady(model))
        XCTAssertEqual(try String(contentsOf: base.appendingPathComponent("requests.txt"), encoding: .utf8).filter { $0 == "\n" }.count, 1)
    }
}
private final class ModelTestErrors: @unchecked Sendable {
    private let lock = NSLock(); private var values: [Error] = []
    func append(_ value: Error) { lock.lock(); values.append(value); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
}
