#if os(Linux)
    import Crypto
    import Foundation
    import Glibc
    import XCTest
    @testable import TractandaCore

    final class DocumentLinuxRuntimeClosureTests: XCTestCase {
        private func digest(_ bytes: Data) -> String {
            SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
        private func fixture() throws -> (URL, String, String) {
            // Estimated fixture <16KiB; existing guarded helpers enforce reserve/cap.
            try AttachmentFixtureCapacity.requireFree()
            let root = try GuardedFixtureDirectory.create(
                prefix: "closure-", source: #fileID, test: #function)
            for relative in ["", "lib", "lib/tractanda"] {
                try FileManager.default.createDirectory(
                    at: root.appendingPathComponent(relative),
                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            let bytes = Data("tiny private commitment fixture".utf8)
            let payload = root.appendingPathComponent("lib/private-fixture")
            try bytes.write(to: payload)
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: payload.path)
            #if arch(arm64)
                let arch = "arm64"
                let machine = 183
            #else
                let arch = "amd64"
                let machine = 62
            #endif
            let descriptor: [String: Any] = [
                "schema": "tractanda.document-native-closure.v1", "operatingSystem": "linux",
                "architecture": arch, "backend": "tractanda.linux-raster.v1-pdfium-agg-srgb",
                "runtimeBaseRevision": "61a4b20d4ad01b10466e8fc94c50402a9f994430",
                "modelAssetsSHA256": "64894c93726b0b76d2eb5c20f001c61d6fc2eea1ef848b23773ba60cae9e00ef",
                "preprocessing": "opaque-rgb-content-crop-hf4561-pillow123-grid-v2",
                "parser": "doctags-strict-v1",
                "sourceRevisions": ["fixture": "not-runtime-admission"], "patchSHA256s": [String: String](),
                "buildProvenanceSHA256": String(repeating: "a", count: 64),
                "files": [
                    [
                        "path": "lib/private-fixture", "sha256": digest(bytes), "size": bytes.count,
                        "mode": 0o444,
                    ]
                ],
                "privateDependencies": [
                    [
                        "path": "bin/tractanda-document-converter", "soname": NSNull(),
                        "needed": ["libc.so.6"], "runpath": [String](), "machine": machine,
                    ]
                ],
                "osDependencies": [
                    [
                        "soname": "libc.so.6", "provider": "libc6", "version": "2.41",
                        "requiredSymbolVersions": ["GLIBC_2.2.5"],
                    ]
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: descriptor, options: [.sortedKeys])
            try data.write(to: root.appendingPathComponent(DocumentLinuxRuntimeClosure.relativePath))
            return (root, digest(data), arch)
        }
        private func verify(_ value: (URL, String, String)) throws -> String {
            try DocumentLinuxRuntimeClosure.verify(
                prefix: value.0.path, expected: value.1,
                architecture: value.2, owner: getuid())
        }
        func testExactPrivateCommitmentAndOSPolicyProvenance() throws {
            let value = try fixture()
            defer { try? FileManager.default.removeItem(at: value.0) }
            XCTAssertEqual(try verify(value), value.1)
            // This focused guard fixture neither executes nor admits its fake ELF declaration.
            // OS entries are ABI/provider metadata, not SDK file hash/path pins.
        }
        func testChangedDescriptorAndChangedPrivateFileFailClosed() throws {
            let value = try fixture()
            defer { try? FileManager.default.removeItem(at: value.0) }
            let descriptor = value.0.appendingPathComponent(DocumentLinuxRuntimeClosure.relativePath)
            let original = try Data(contentsOf: descriptor)
            try (original + Data([10])).write(to: descriptor)
            XCTAssertThrowsError(try verify(value))
            try original.write(to: descriptor)
            let payload = value.0.appendingPathComponent("lib/private-fixture")
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: payload.path)
            try Data("different".utf8).write(to: payload)
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: payload.path)
            XCTAssertThrowsError(try verify(value))
        }
        func testSymbolicPrivateFileAndWritableFileFailClosed() throws {
            let value = try fixture()
            defer { try? FileManager.default.removeItem(at: value.0) }
            let payload = value.0.appendingPathComponent("lib/private-fixture")
            try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: payload.path)
            XCTAssertThrowsError(try verify(value))
            try FileManager.default.removeItem(at: payload)
            try FileManager.default.createSymbolicLink(
                atPath: payload.path, withDestinationPath: "/etc/passwd")
            XCTAssertThrowsError(try verify(value))
        }
        func testRuntimeClaimsCannotSelectCompiledAdmissionBranch() throws {
            let value = try fixture()
            defer { try? FileManager.default.removeItem(at: value.0) }
            let compiled = try DocumentLinuxRuntimeClosure.compiledCurrentDigest()
            let path = value.0.appendingPathComponent(DocumentLinuxRuntimeClosure.relativePath)
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
            object["claimedCurrentIdentity"] = "unadmitted-helper"
            try JSONSerialization.data(withJSONObject: object).write(to: path)
            XCTAssertEqual(try DocumentLinuxRuntimeClosure.compiledCurrentDigest(), compiled)
            let configuration = DocumentConverterConfiguration(
                executablePath: value.0.appendingPathComponent("bin/tractanda-document-converter").path,
                modelDirectory: value.0.path, scratchDirectory: value.0.path)
            XCTAssertThrowsError(try DocumentLinuxRuntimeClosure.preflight(configuration))
            XCTAssertThrowsError(try verify(value))
            let altered = try Data(contentsOf: path)
            XCTAssertThrowsError(
                try DocumentLinuxRuntimeClosure.verify(
                    prefix: value.0.path, expected: digest(altered), architecture: value.2, owner: getuid()),
                "Unknown claimed-identity fields remain invalid even with a self-computed manifest hash")
        }
    }
#endif
