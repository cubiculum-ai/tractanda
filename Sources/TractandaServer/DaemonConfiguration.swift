import Foundation
import TractandaCore

public struct DaemonConfiguration: Codable, Sendable {
    public let storePath: String
    public let indexDirectory: String?
    public let socketPath: String
    public let httpPort: Int?
    public let publicJMAP: PublicJMAPConfiguration?
    public let managed: Bool
    public let viewItemID: String?
    public let projectRootID: String?
    public let statusRootID: String?
    public let initialProjectID: String?
    public let rebuildNoProgressTimeoutSeconds: Double?
    public let attachmentUploadPolicy: AttachmentUploadPolicy?
    public let documentConverter: DocumentConverterConfiguration?
    public let modelProvisioning: ModelProvisioningConfiguration?
    public let documentJobResources: DocumentJobResources?
    /// Optional explicit local peer runtime settings path; absent keeps peer networking disabled.
    public let peerRuntimeConfigurationPath: String?

    public init(
        storePath: String, indexDirectory: String? = nil, socketPath: String, httpPort: Int? = 48_728,
        managed: Bool = false,
        viewItemID: String? = nil, projectRootID: String? = nil, statusRootID: String? = nil,
        initialProjectID: String? = nil, documentConverter: DocumentConverterConfiguration? = nil,
        documentJobResources: DocumentJobResources? = nil, modelProvisioning: ModelProvisioningConfiguration? = nil,
        attachmentUploadPolicy: AttachmentUploadPolicy? = nil,
        rebuildNoProgressTimeoutSeconds: Double? = nil, peerRuntimeConfigurationPath: String? = nil,
        publicJMAP: PublicJMAPConfiguration? = nil
    ) {
        self.storePath = storePath
        self.indexDirectory = indexDirectory
        self.socketPath = socketPath
        self.httpPort = httpPort
        self.publicJMAP = publicJMAP
        self.managed = managed
        self.viewItemID = viewItemID
        self.projectRootID = projectRootID
        self.statusRootID = statusRootID
        self.initialProjectID = initialProjectID
        self.documentConverter = documentConverter
        self.documentJobResources = documentJobResources
        self.modelProvisioning = modelProvisioning
        self.attachmentUploadPolicy = attachmentUploadPolicy
        self.rebuildNoProgressTimeoutSeconds = rebuildNoProgressTimeoutSeconds
        self.peerRuntimeConfigurationPath = peerRuntimeConfigurationPath
    }
    public func validate() throws {
        try modelProvisioning?.validate()
        try publicJMAP?.validate()
        try documentJobResources?.validate()
        guard
            rebuildNoProgressTimeoutSeconds == nil
                || (rebuildNoProgressTimeoutSeconds!.isFinite && rebuildNoProgressTimeoutSeconds! > 0)
        else {
            throw TractandaError(
                "invalidConfiguration", "Rebuild no-progress timeout must be positive and finite.")
        }
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
        guard
            peerRuntimeConfigurationPath == nil
                || (peerRuntimeConfigurationPath!.hasPrefix("/") && peerRuntimeConfigurationPath! != "/"
                    && peerRuntimeConfigurationPath!.utf8.count <= 4096
                    && !peerRuntimeConfigurationPath!.contains("\0")
                    && !peerRuntimeConfigurationPath!.contains("\n")
                    && !peerRuntimeConfigurationPath!.contains("\r"))
        else {
            throw TractandaError("invalidConfiguration", "Peer runtime configuration path must be absolute.")
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
