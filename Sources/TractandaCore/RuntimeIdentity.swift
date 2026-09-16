import Crypto
import Foundation

/// Captured once per process. A file digest identifies a build even when its release version is unchanged.
public struct RuntimeIdentity: Codable, Sendable {
    public let name: String
    public let version: String
    public let executableSHA256: String?
    public let processID: Int32
    public let instanceID: String

    public static let current: RuntimeIdentity = {
        #if os(Linux)
            let executable = URL(fileURLWithPath: "/proc/self/exe")
            let location = executable.resolvingSymlinksInPath()
        #else
            let executable = Bundle.main.executableURL
            let location = executable?.resolvingSymlinksInPath()
        #endif
        return capture(executable: executable, location: location)
    }()

    static func capture(executable: URL?, location: URL?) -> RuntimeIdentity {
        var digest: String?
        if let executable, let handle = try? FileHandle(forReadingFrom: executable) {
            defer { try? handle.close() }
            do {
                var hash = SHA256()
                while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty {
                    hash.update(data: bytes)
                }
                digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            } catch { digest = nil }
        }
        var version = "development"
        if let location, let digest {
            let manifest = location.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("bundle-manifest.json")
            if let data = try? Data(contentsOf: manifest), data.count <= 8 * 1024 * 1024,
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                object["profile"] as? String == "tractanda.bundle.v1",
                let candidate = object["version"] as? String, !candidate.isEmpty, candidate.utf8.count <= 80,
                let files = object["files"] as? [[String: Any]],
                files.contains(where: {
                    $0["path"] as? String == "bin/" + location.lastPathComponent
                        && $0["sha256"] as? String == digest
                })
            {
                version = candidate
            }
        }
        return RuntimeIdentity(
            name: "Tractanda", version: version, executableSHA256: digest,
            processID: ProcessInfo.processInfo.processIdentifier, instanceID: UUID().uuidString.lowercased())
    }
}
