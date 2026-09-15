import Foundation
import TractandaCore

/// First-store initialization, executed as the selected service UID. It resumes only the
/// exact access configuration it created; it never adopts or rewrites another database.
enum StoreBootstrap {
    static func initialize(store root: URL, indexDirectory: URL, owner: String, instance: String) throws {
        _ = try SystemAccountDirectory().user(named: owner)
        let configuration: ItemValue = .object([
            "profile": .text(AccessConfiguration.profile),
            "users": .list([.text(owner)]), "groups": .list([]),
            "administration": .text("system"),
            "administratorGroup": .text(SetupPlatform.host == .macos ? "admin" : "sudo"),
        ])
        let store = try ItemStore(root: root, indexDirectory: indexDirectory)
        let existing = try store.candidates(includeDeleted: true)
        let operation = "setup-access-v1-" + instance
        if existing.isEmpty {
            _ = try store.configureAccess(configuration, operationID: operation)
        } else {
            guard existing.count == 1, let record = existing.first,
                record.classID == AccessConfiguration.classID, !record.isDeleted,
                record.fields["operationID"]?.string == operation,
                record.fields["accessConfiguration"] == configuration
            else {
                throw SetupError(
                    "Initialization found existing data or a different access policy; nothing was overwritten."
                )
            }
        }
    }
}
