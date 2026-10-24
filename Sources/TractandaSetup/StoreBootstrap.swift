import Foundation
import TractandaCore

/// First-store initialization, executed as the selected service UID. It resumes only the
/// current personal/workgroup access configuration it created; it never adopts historical
/// authority/raw content. Existing roots require separately authorized in-place preparation.
enum StoreBootstrap {
    static func initialize(
        store root: URL, indexDirectory: URL, owner: String, instance: String,
        accounts: any AccountDirectory = SystemAccountDirectory()
    ) throws {
        _ = try accounts.user(named: owner)
        let configuration: ItemValue = .object([
            "profile": .text(AccessConfiguration.profile),
            "users": .list([.text(owner)]), "groups": .list([]),
            "administration": .text("system"),
            "administratorGroup": .text(SetupPlatform.host == .macos ? "admin" : "sudo"),
        ])
        _ = try ItemStore.initializeFresh(
            root: root, indexDirectory: indexDirectory, accounts: accounts,
            initialAccessConfiguration: configuration, initializationKey: "setup:" + instance)
    }
}
