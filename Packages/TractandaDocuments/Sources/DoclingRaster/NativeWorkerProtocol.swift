import CoreFoundation
import Foundation
import TractandaClient

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

public struct NativeSourceFileIdentity: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let byteCount: Int64
    public let mode: UInt32
    public let uid: UInt32
    public let gid: UInt32
    public let modificationSeconds: Int64
    public let modificationNanoseconds: Int32

    public init(
        device: UInt64, inode: UInt64, byteCount: Int64, mode: UInt32, uid: UInt32, gid: UInt32,
        modificationSeconds: Int64, modificationNanoseconds: Int32
    ) {
        self.device = device
        self.inode = inode
        self.byteCount = byteCount
        self.mode = mode
        self.uid = uid
        self.gid = gid
        self.modificationSeconds = modificationSeconds
        self.modificationNanoseconds = modificationNanoseconds
    }
}

public struct NativeDocumentBinding: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case protocolName = "protocol"
        case jobID, sessionID, source, identity, file
    }
    public let protocolName: String
    public let jobID: String
    public let sessionID: String
    public let source: AttachmentDocumentSource
    public let identity: DocumentConverterIdentity
    public let file: NativeSourceFileIdentity

    public func validate() throws {
        guard protocolName == NativeWorkerProtocol.name else { throw NativeWorkerProtocol.invalid() }
        try NativeWorkerProtocol.validateID(jobID)
        try NativeWorkerProtocol.validateID(sessionID)
        try source.validate()
        try identity.validateCurrent()
        guard file.byteCount == source.byteCount, file.byteCount > 0,
            file.mode & 0o170000 == 0o100000, file.mode & 0o222 == 0,
            (0...999_999_999).contains(file.modificationNanoseconds)
        else { throw NativeWorkerProtocol.invalid() }
    }
}

public struct NativeWorkerRequest: Codable, Sendable {
    enum CodingKeys: String, CodingKey {
        case protocolName = "protocol"
        case jobID, sessionID, requestID, method, pageNumber
    }
    public let protocolName: String
    public let jobID: String
    public let sessionID: String
    public let requestID: Int64
    public let method: String
    public let pageNumber: Int64?
}

/// This codec is native-local; Core validates the same frozen wire contract independently.
public enum NativeWorkerProtocol {
    public static let name = "tractanda.native-document-worker.v1"
    public static let requestBytes = 65_536
    public static let controlBytes = 4_096
    public static let pageBytes = 2_097_152
    public static let bindingKeys: Set<String> = [
        "protocol", "jobID", "sessionID", "source", "identity", "file",
    ]

    public static func invalid() -> TractandaError {
        TractandaError("invalidNativeProtocol", "Native document protocol validation failed.")
    }
    public static func validateID(_ id: String) throws {
        try Identifier.validate(id)
        guard let uuid = UUID(uuidString: id) else { throw invalid() }
        var raw = uuid.uuid
        let bytes = withUnsafeBytes(of: &raw) { Array($0) }
        guard bytes[6] >> 4 == 1, bytes[8] & 0xC0 == 0x80 else { throw invalid() }
    }
    public static func object(_ data: Data, limit: Int) throws -> [String: Any] {
        guard data.count <= limit, String(data: data, encoding: .utf8) != nil else { throw invalid() }
        try rejectDuplicateKeys(data)
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw invalid()
        }
        return value
    }
    public static func keys(_ value: [String: Any], _ expected: Set<String>) throws {
        guard Set(value.keys) == expected, !value.values.contains(where: { $0 is NSNull }) else {
            throw invalid()
        }
    }
    public static func binding(_ data: Data) throws -> NativeDocumentBinding {
        let value = try object(data, limit: requestBytes)
        try validateBindingKeys(value)
        let binding = try JSONDecoder().decode(NativeDocumentBinding.self, from: data)
        try binding.validate()
        return binding
    }
    private static func validateBindingKeys(_ value: [String: Any]) throws {
        try keys(value, bindingKeys)
        guard let source = value["source"] as? [String: Any],
            let identity = value["identity"] as? [String: Any], let file = value["file"] as? [String: Any]
        else { throw invalid() }
        try keys(source, ["itemID", "revisionID", "attachmentID", "sha256", "byteCount", "mediaType"])
        try keys(
            identity, ["converter", "model", "modelRevision", "runtimeRevision", "preprocessing", "parser"])
        try keys(
            file,
            [
                "device", "inode", "byteCount", "mode", "uid", "gid", "modificationSeconds",
                "modificationNanoseconds",
            ])
    }
    public static func request(
        _ data: Data, binding: NativeDocumentBinding, previousID: Int64, pageCount: Int64
    ) throws -> NativeWorkerRequest {
        let value = try object(data, limit: requestBytes)
        guard let method = value["method"] as? String, ["close", "convertPage"].contains(method) else {
            throw invalid()
        }
        var expected: Set<String> = ["protocol", "jobID", "sessionID", "requestID", "method"]
        if method == "convertPage" { expected.insert("pageNumber") }
        try keys(value, expected)
        let request = try JSONDecoder().decode(NativeWorkerRequest.self, from: data)
        guard request.protocolName == name, request.jobID == binding.jobID,
            request.sessionID == binding.sessionID, request.requestID > previousID, request.requestID > 0
        else { throw invalid() }
        if method == "convertPage" {
            guard let number = request.pageNumber, number > 0, number <= pageCount else { throw invalid() }
        } else if request.pageNumber != nil {
            throw invalid()
        }
        return request
    }
    public static func boundObject(_ binding: NativeDocumentBinding) throws -> [String: Any] {
        try object(JSONEncoder().encode(binding), limit: requestBytes)
    }
    public static func integer(_ value: Any) throws -> Int64 {
        // Decode from its JSON representation, rejecting bool, fractional and overflowing values.
        guard let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID()
        else { throw invalid() }
        let encoded = try JSONSerialization.data(withJSONObject: [number])
        return try JSONDecoder().decode([Int64].self, from: encoded)[0]
    }
    public static func validateResponse(
        _ data: Data, binding expectedBinding: NativeDocumentBinding,
        outstanding: NativeWorkerRequest?, pageCount: Int64
    ) throws {
        let value = try object(data, limit: pageBytes)
        guard let type = value["type"] as? String else { throw invalid() }
        let bindingValue = value.filter { bindingKeys.contains($0.key) }
        let actual = try binding(JSONSerialization.data(withJSONObject: bindingValue))
        guard actual == expectedBinding else { throw invalid() }
        var expected = bindingKeys.union(["type"])
        switch type {
        case "hello":
            expected.formUnion(["pageCount", "modelLoaded", "modelForwardCalls"])
            guard outstanding == nil, try integer(value["pageCount"] as Any) > 0,
                let loaded = value["modelLoaded"] as? NSNumber,
                CFGetTypeID(loaded) == CFBooleanGetTypeID(), !loaded.boolValue,
                try integer(value["modelForwardCalls"] as Any) == 0
            else { throw invalid() }
        case "error":
            expected.insert("failureCode")
            try failureCode(value["failureCode"])
        case "closed":
            expected.insert("requestID")
            guard let outstanding, outstanding.method == "close",
                try integer(value["requestID"] as Any) == outstanding.requestID
            else { throw invalid() }
        case "progress", "page":
            expected.formUnion(["requestID", "pageNumber"])
            guard let outstanding, outstanding.method == "convertPage",
                try integer(value["requestID"] as Any) == outstanding.requestID,
                try integer(value["pageNumber"] as Any) == outstanding.pageNumber,
                try integer(value["pageNumber"] as Any) <= pageCount
            else { throw invalid() }
            if type == "progress" {
                expected.formUnion(["phase", "completed", "total"])
                guard let phase = value["phase"] as? String,
                    [
                        "modelVerify", "modelLoad", "modelReady", "render", "prepare", "prefill", "generate",
                        "drain",
                    ].contains(phase)
                else { throw invalid() }
                let completed = try integer(value["completed"] as Any)
                let total = try integer(value["total"] as Any)
                guard completed >= 0, completed <= total else { throw invalid() }
                if ["modelLoad", "modelReady", "render", "prepare", "drain"].contains(phase) {
                    guard completed == 0, total == 0 else { throw invalid() }
                }
                if phase == "generate" { guard total == 262_144 else { throw invalid() } }
            } else {
                expected.insert("status")
                guard let status = value["status"] as? String else { throw invalid() }
                if status == "converted" {
                    expected.insert("page")
                    guard let page = value["page"] as? [String: Any] else { throw invalid() }
                    try keys(
                        page,
                        [
                            "pageNumber", "geometry", "rasterSHA256", "rawDocTags", "generatedTokens",
                            "stopReason",
                        ])
                    guard let geometry = page["geometry"] as? [String: Any] else { throw invalid() }
                    try keys(
                        geometry,
                        [
                            "sourceWidth", "sourceHeight", "sourceOriginX", "sourceOriginY", "sourceRotation",
                            "sourceUnit", "displayWidth", "displayHeight", "canvasWidth", "canvasHeight",
                            "contentLeft", "contentTop", "contentWidth", "contentHeight",
                        ])
                    let candidate = try JSONDecoder().decode(
                        DocumentGeneratedPage.self, from: JSONSerialization.data(withJSONObject: page))
                    guard Int64(candidate.pageNumber) == outstanding.pageNumber,
                        candidate.rawDocTags.utf8.count <= 262_144,
                        candidate.stopReason == "stop", (0..<1024).contains(candidate.generatedTokens),
                        candidate.rasterSHA256.utf8.count == 64,
                        candidate.rasterSHA256.utf8.allSatisfy({
                            (48...57).contains($0) || (97...102).contains($0)
                        })
                    else { throw invalid() }
                    try candidate.geometry.validateContentCrop()
                } else {
                    expected.insert("failureCode")
                    guard ["unsupported", "truncated", "timeout", "failed"].contains(status) else {
                        throw invalid()
                    }
                    try failureCode(value["failureCode"])
                }
            }
        default: throw invalid()
        }
        try keys(value, expected)
        guard data.count <= (type == "page" ? pageBytes : controlBytes) else { throw invalid() }
    }
    private static func failureCode(_ value: Any?) throws {
        guard let code = value as? String, (1...64).contains(code.utf8.count),
            let first = code.utf8.first, (65...90).contains(first) || (97...122).contains(first),
            code.utf8.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
            })
        else { throw invalid() }
    }
    private static func rejectDuplicateKeys(_ data: Data) throws {
        struct Scope {
            var object: Bool
            var wantsKey = true
            var keys: Set<String> = []
        }
        let bytes = Array(data)
        var scopes: [Scope] = []
        var index = 0
        while index < bytes.count {
            switch bytes[index] {
            case 123, 91:
                scopes.append(Scope(object: bytes[index] == 123))
                guard scopes.count <= 32 else { throw invalid() }
            case 125, 93:
                guard !scopes.isEmpty else { throw invalid() }
                scopes.removeLast()
            case 44:
                if !scopes.isEmpty, scopes[scopes.count - 1].object {
                    scopes[scopes.count - 1].wantsKey = true
                }
            case 34:
                let start = index
                index += 1
                while index < bytes.count, bytes[index] != 34 {
                    if bytes[index] == 92 { index += 1 }
                    index += 1
                }
                guard index < bytes.count else { throw invalid() }
                if !scopes.isEmpty, scopes[scopes.count - 1].object, scopes[scopes.count - 1].wantsKey {
                    let key = try JSONDecoder().decode(String.self, from: Data(bytes[start...index]))
                    guard scopes[scopes.count - 1].keys.insert(key).inserted else { throw invalid() }
                    scopes[scopes.count - 1].wantsKey = false
                }
            default: break
            }
            index += 1
        }
        guard scopes.isEmpty else { throw invalid() }
    }
}

/// Bounded buffered framing; idle EOF is distinct from an incomplete line.
public final class NativeWorkerLineReader {
    private let file: FileHandle
    private var pending = Data()
    public init(file: FileHandle) { self.file = file }
    public func next(limit: Int) throws -> Data? {
        while true {
            if let newline = pending.firstIndex(of: 10) {
                guard newline <= limit else { throw NativeWorkerProtocol.invalid() }
                let result = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                return result
            }
            guard pending.count <= limit else { throw NativeWorkerProtocol.invalid() }
            // FileHandle.read(upToCount:) can wait for the requested count or EOF on a
            // Darwin pipe. A retained worker must return a complete request while stdin
            // stays open for subsequent requests, so consume one available POSIX read.
            var bytes = [UInt8](repeating: 0, count: min(8192, limit + 1 - pending.count))
            let count = bytes.withUnsafeMutableBytes {
                read(file.fileDescriptor, $0.baseAddress, $0.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            if count == 0 {
                guard pending.isEmpty else { throw NativeWorkerProtocol.invalid() }
                return nil
            }
            pending.append(contentsOf: bytes.prefix(count))
        }
    }
}
