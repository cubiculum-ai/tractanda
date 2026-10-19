#if os(Linux)
    import Foundation
    import Glibc
    import Crypto
    import TractandaClient

    enum LinuxNativeAdmission {
        struct File: Decodable {
            let path: String
            let sha256: String
            let size: Int64
            let mode: UInt16
        }
        struct PrivateDependency: Decodable {
            let path: String
            let soname: String?
            let needed: [String]
            let runpath: [String]
            let machine: UInt16
        }
        struct OSDependency: Decodable {
            let soname: String
            let provider: String
            let version: String
            let requiredSymbolVersions: [String]
        }
        struct Descriptor: Decodable {
            let schema: String
            let operatingSystem: String
            let architecture: String
            let backend: String
            let runtimeBaseRevision: String
            let modelAssetsSHA256: String
            let preprocessing: String
            let parser: String
            let sourceRevisions: [String: String]
            let patchSHA256s: [String: String]
            let buildProvenanceSHA256: String
            let files: [File]
            let privateDependencies: [PrivateDependency]
            let osDependencies: [OSDependency]
        }
        static let relativePath = "lib/tractanda/document-native-closure.json"
        static func active() throws -> String {
            guard let expected = ApprovedLinuxDocumentClosure.sha256 else {
                throw TractandaError("documentConverter", "Linux native document closure is not admitted")
            }
            #if arch(x86_64)
                let architecture = "amd64"
            #elseif arch(arm64)
                let architecture = "arm64"
            #else
                throw TractandaError("documentConverter", "Unsupported Linux document architecture")
            #endif
            // Core must verify the same closure before launching the worker and add
            // this actual verified digest to its existing job configuration hash.
            let verified = try verify(
                prefix: ApprovedLinuxDocumentClosure.installPrefix,
                expected: expected, architecture: architecture, owner: ApprovedLinuxDocumentClosure.owner)
            try require(
                DocumentConverterIdentity().converter
                    == "tractanda.docling-native.v2-idefics3-gelu-f32+linux-raster." + verified,
                "Linux converter identity has not been admitted")
            return verified
        }
        static func verify(prefix: String, expected: String, architecture: String, owner: UInt32) throws
            -> String
        {
            try require(
                isHash(expected) && prefix.hasPrefix("/"), "Invalid compiled Linux closure commitment")
            var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            try require(directory >= 0, "Cannot open trusted filesystem root")
            defer { close(directory) }
            for part in prefix.split(separator: "/") {
                try require(part != "." && part != "..", "Invalid native prefix")
                let next = openat(directory, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                try require(next >= 0, "Native prefix contains an unavailable or symbolic directory")
                do {
                    var value = stat()
                    try require(fstat(next, &value) == 0, "Native prefix metadata failed")
                    let testSticky = owner != 0 && value.st_uid == 0 && value.st_mode & 0o1777 == 0o1777
                    try require(
                        (value.st_uid == 0 || value.st_uid == owner)
                            && (value.st_mode & 0o022 == 0 || testSticky),
                        "Native prefix is writable or foreign")
                } catch {
                    close(next)
                    throw error
                }
                close(directory)
                directory = next
            }
            let data = try read(
                directory: directory, path: relativePath, owner: owner, expectedSize: nil, expectedMode: nil,
                limit: 262144
            ).data
            try require(sha256(data) == expected, "Native descriptor commitment differs")
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let keys: Set<String> = [
                "schema", "operatingSystem", "architecture", "backend", "runtimeBaseRevision",
                "modelAssetsSHA256", "preprocessing", "parser", "sourceRevisions", "patchSHA256s",
                "buildProvenanceSHA256", "files", "privateDependencies", "osDependencies",
            ]
            try require(Set(object?.keys.map { $0 } ?? []) == keys, "Unknown native closure fields")
            let rawFiles = object?["files"] as? [[String: Any]]
            try require(
                rawFiles != nil
                    && rawFiles!.allSatisfy { Set($0.keys) == ["path", "sha256", "size", "mode"] },
                "Unknown native file fields")
            let descriptor = try JSONDecoder().decode(Descriptor.self, from: data)
            let identity = DocumentConverterIdentity()
            let manifest = try Data(
                contentsOf: Bundle.module.url(forResource: "ModelAssets", withExtension: "json")!)
            try require(
                descriptor.schema == "tractanda.document-native-closure.v1"
                    && descriptor.operatingSystem == "linux"
                    && descriptor.architecture == architecture
                    && descriptor.backend == "tractanda.linux-raster.v1-pdfium-agg-srgb"
                    && descriptor.runtimeBaseRevision == "61a4b20d4ad01b10466e8fc94c50402a9f994430"
                    && descriptor.modelAssetsSHA256 == sha256(manifest)
                    && descriptor.preprocessing == identity.preprocessing
                    && descriptor.parser == identity.parser && isHash(descriptor.buildProvenanceSHA256),
                "Native profile/provenance differs")
            try require(
                !descriptor.files.isEmpty && descriptor.files.count <= 256
                    && Set(descriptor.files.map(\.path)).count == descriptor.files.count,
                "Invalid native file set")
            let paths = Set(descriptor.files.map(\.path))
            let dependencies = descriptor.privateDependencies
            let privateNames = dependencies.compactMap(\.soname)
            let osNames = descriptor.osDependencies.map(\.soname)
            try require(
                Set(privateNames).count == privateNames.count && Set(osNames).count == osNames.count
                    && Set(privateNames).isDisjoint(with: Set(osNames)), "Ambiguous native library providers")
            try require(
                Set(dependencies.map(\.path)).count == dependencies.count
                    && dependencies.contains { $0.path == "bin/tractanda-document-converter" },
                "Missing native converter dependency root")
            let providers = Set(privateNames + osNames)
            for edge in dependencies {
                try require(
                    (paths.contains(edge.path) || edge.path == "bin/tractanda-document-converter")
                        && edge.machine == (architecture == "amd64" ? 62 : 183)
                        && edge.needed.allSatisfy { !$0.contains("/") && providers.contains($0) },
                    "Unclosed native dependency edge")
            }
            try require(
                descriptor.osDependencies.allSatisfy {
                    !$0.soname.isEmpty && !$0.provider.isEmpty && !$0.version.isEmpty
                }, "Missing OS provider provenance")
            for file in descriptor.files {
                try require(
                    file.path != relativePath && file.path != "bin/tractanda-document-converter"
                        && isHash(file.sha256)
                        && file.size > 0 && file.size <= 2 * 1024 * 1024 * 1024 && file.mode & 0o6022 == 0,
                    "Invalid native file commitment")
                let bytes = try read(
                    directory: directory, path: file.path, owner: owner,
                    expectedSize: file.size, expectedMode: file.mode, limit: file.size, collect: false)
                try require(bytes.digest == file.sha256, "Private native file hash differs")
            }
            return expected
        }
        private static func isHash(_ value: String) -> Bool {
            value.utf8.count == 64
                && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        private static func stamp(_ value: stat) -> [UInt64] {
            [
                UInt64(value.st_dev), UInt64(value.st_ino), UInt64(bitPattern: Int64(value.st_size)),
                UInt64(value.st_mode),
                UInt64(value.st_uid), UInt64(value.st_gid), UInt64(bitPattern: Int64(value.st_mtim.tv_sec)),
                UInt64(value.st_mtim.tv_nsec), UInt64(bitPattern: Int64(value.st_ctim.tv_sec)),
                UInt64(value.st_ctim.tv_nsec),
            ]
        }
        private static func read(
            directory: Int32, path: String, owner: UInt32, expectedSize: Int64?, expectedMode: UInt16?,
            limit: Int64, collect: Bool = true
        ) throws -> (data: Data, digest: String) {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            try require(
                !path.hasPrefix("/") && !parts.isEmpty
                    && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") },
                "Unsafe native file path")
            var parent = dup(directory)
            try require(parent >= 0, "Native directory duplication failed")
            defer { close(parent) }
            for part in parts.dropLast() {
                let next = openat(parent, String(part), O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
                try require(next >= 0, "Native directory unavailable")
                var value = stat()
                guard fstat(next, &value) == 0, value.st_uid == owner, value.st_mode & 0o022 == 0 else {
                    close(next)
                    throw TractandaError("documentConverter", "Native directory is foreign or writable")
                }
                close(parent)
                parent = next
            }
            let fd = openat(parent, String(parts.last!), O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            try require(fd >= 0, "Private native file unavailable")
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? file.close() }
            var before = stat()
            try require(
                fstat(fd, &before) == 0 && before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
                    && before.st_uid == owner && before.st_mode & 0o6022 == 0 && before.st_size > 0
                    && before.st_size <= limit,
                "Private native file is unsafe")
            if let expectedSize {
                try require(before.st_size == expectedSize, "Private native file size differs")
            }
            if let expectedMode {
                try require(
                    before.st_mode & 0o7777 == mode_t(expectedMode), "Private native file mode differs")
            }
            var data = Data()
            var count: Int64 = 0
            var hasher = SHA256()
            while let bytes = try file.read(upToCount: 1024 * 1024), !bytes.isEmpty {
                try require(Int64(bytes.count) <= limit - count, "Private native file grew")
                hasher.update(data: bytes)
                count += Int64(bytes.count)
                if collect { data.append(bytes) }
            }
            var after = stat()
            try require(
                fstat(fd, &after) == 0 && stamp(before) == stamp(after) && count == before.st_size,
                "Private native file changed while verifying")
            return (data, hasher.finalize().map { String(format: "%02x", $0) }.joined())
        }
    }
#endif
