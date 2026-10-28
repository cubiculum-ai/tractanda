import Foundation
import TractandaCore

public struct ModelProvisioningConfiguration: Codable, Sendable {
    public let manifestPath: String
    public let storageDirectory: String
    public let adoptionDirectory: String?
    public init(manifestPath: String, storageDirectory: String, adoptionDirectory: String? = nil) {
        self.manifestPath = manifestPath
        self.storageDirectory = storageDirectory
        self.adoptionDirectory = adoptionDirectory
    }
    public func validate() throws {
        for path in [manifestPath, storageDirectory, adoptionDirectory].compactMap({ $0 }) {
            guard path.hasPrefix("/"), path != "/", path.utf8.count <= 4096, !path.contains("\0"),
                path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy({
                    !$0.isEmpty && $0 != "." && $0 != ".."
                })
            else {
                throw TractandaError(
                    "invalidConfiguration", "Model provisioning requires dedicated absolute paths.")
            }
        }
        _ = try ModelProvisioningCatalog.load(manifestPath)
    }
}

/// One detached worker per artifact lets unavailable embedding and Docling downloads retry independently.
final class ModelProvisioningRuntime: Sendable {
    let workers: [ModelProvisioner]
    let tasks: [Task<Void, Never>]
    init(
        configuration: ModelProvisioningConfiguration, testingOrigin: URL? = nil,
        onReady: @escaping @Sendable (ModelArtifactManifest) async -> Void = { _ in }
    ) throws {
        let catalog = try ModelProvisioningCatalog.load(configuration.manifestPath)
        var runners: [ModelProvisioner] = []
        var jobs: [Task<Void, Never>] = []
        for artifact in catalog.artifacts {
            let root = URL(fileURLWithPath: configuration.storageDirectory)
            let worker =
                testingOrigin.map { ModelProvisioner(root: root, testingOrigin: $0) }
                ?? ModelProvisioner(root: root)
            runners.append(worker)
            let adoption = configuration.adoptionDirectory.map {
                URL(fileURLWithPath: $0).appendingPathComponent(artifact.identifier)
            }
            jobs.append(
                Task.detached(priority: .utility) {
                    do {
                        try await Self.runBlocking {
                            try worker.provision(
                                .init(artifacts: [artifact]),
                                adoptionDirectories: adoption.map { [artifact.identifier: $0] } ?? [:])
                        }
                        await onReady(artifact)
                    } catch {
                        // The worker's bounded status retains failure/cancellation; core remains usable.
                    }
                })
        }
        workers = runners
        tasks = jobs
    }
    /// Curl polling, retry waits and hashing never occupy Swift's cooperative actor executor.
    static func runBlocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result(catching: body))
            }
        }
    }
    func close() async {
        for worker in workers { worker.cancel() }
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }
}
