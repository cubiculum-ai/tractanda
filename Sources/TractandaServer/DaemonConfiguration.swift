import Foundation
import TractandaCore

public struct DaemonConfiguration: Codable, Sendable {
    public let storePath: String
    public let indexDirectory: String?
    public let socketPath: String
    public let httpPort: Int?
    public let managed: Bool
    public let viewItemID: String?
    public let projectRootID: String?
    public let statusRootID: String?
    public let initialProjectID: String?

    public init(
        storePath: String, indexDirectory: String? = nil, socketPath: String, httpPort: Int? = 48_728,
        managed: Bool = false,
        viewItemID: String? = nil, projectRootID: String? = nil, statusRootID: String? = nil,
        initialProjectID: String? = nil
    ) {
        self.storePath = storePath
        self.indexDirectory = indexDirectory
        self.socketPath = socketPath
        self.httpPort = httpPort
        self.managed = managed
        self.viewItemID = viewItemID
        self.projectRootID = projectRootID
        self.statusRootID = statusRootID
        self.initialProjectID = initialProjectID
    }
    public func validate() throws {
        guard storePath.hasPrefix("/"), storePath != "/", !storePath.contains("\0") else {
            throw TractandaError("invalidConfiguration", "Choose a dedicated absolute store path.")
        }
        guard
            indexDirectory == nil
                || (indexDirectory!.hasPrefix("/") && indexDirectory! != "/"
                    && !indexDirectory!.contains("\0"))
        else {
            throw TractandaError("invalidConfiguration", "Choose a dedicated absolute index directory.")
        }
        guard socketPath.hasPrefix("/"), !socketPath.contains("\0"), socketPath.utf8.count <= 103 else {
            throw TractandaError("invalidConfiguration", "Choose a short absolute socket path.")
        }
        guard httpPort == nil || (0...65_535).contains(httpPort!) else {
            throw TractandaError("invalidConfiguration", "HTTP port is invalid.")
        }
        guard (projectRootID == nil) == (statusRootID == nil),
            initialProjectID == nil || projectRootID != nil,
            !(viewItemID != nil && projectRootID != nil)
        else { throw TractandaError("invalidConfiguration", "Board mode configuration is inconsistent.") }
        for value in [viewItemID, projectRootID, statusRootID, initialProjectID].compactMap({ $0 }) {
            try Identifier.validate(value)
        }
    }
}
