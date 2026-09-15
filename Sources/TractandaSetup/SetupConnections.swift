import Foundation

extension SetupEngine {
    var profileURL: URL { roots.configuration.appendingPathComponent("connections.json") }

    func globalProfilesSnapshot() throws -> Data? {
        guard exists(profileURL) else { return nil }
        try requireOwned(profileURL, uid: 0, directory: false)
        guard try fileSize(profileURL) <= 1024 * 1024 else {
            throw SetupError("Global connection registry is oversized.")
        }
        return try Data(contentsOf: profileURL)
    }
    func globalProfiles() throws -> [String: Any] {
        guard let data = try globalProfilesSnapshot() else { return ["version": 1, "profiles": [:]] }
        guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            document["version"] as? Int == 1, let profiles = document["profiles"] as? [String: Any],
            profiles.values.allSatisfy({ ($0 as? [String: Any])?["managedService"] == nil })
        else { throw SetupError("Global connection registry has an unsupported shape.") }
        return document
    }
    func ensureNoGlobalProfile(_ name: String) throws {
        let document = try globalProfiles()
        guard (document["profiles"] as? [String: Any])?[name] == nil else {
            throw SetupError("A connection with this name already exists without an installation receipt.")
        }
    }
    func writeGlobalProfile(_ receipt: InstallationReceipt) throws {
        var document = try globalProfiles()
        var profiles = document["profiles"] as! [String: Any]
        if let existing = profiles[receipt.instance] as? [String: Any] {
            guard existing["socketPath"] as? String == receipt.socket,
                existing["serverUser"] as? String == roots.platform.serviceUser
            else { throw SetupError("The connection entry was changed outside the installer.") }
        }
        profiles[receipt.instance] = ["socketPath": receipt.socket, "serverUser": roots.platform.serviceUser]
        document["profiles"] = profiles
        if document["defaultProfile"] == nil { document["defaultProfile"] = receipt.instance }
        try writeProtected(
            try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]),
            to: profileURL, mode: 0o644)
    }
    func removeGlobalProfile(_ receipt: InstallationReceipt) throws {
        guard exists(profileURL) else { return }
        var document = try globalProfiles()
        var profiles = document["profiles"] as! [String: Any]
        guard let existing = profiles[receipt.instance] as? [String: Any] else { return }
        guard existing["socketPath"] as? String == receipt.socket,
            existing["serverUser"] as? String == roots.platform.serviceUser
        else { throw SetupError("Refusing to remove a changed connection entry.") }
        profiles.removeValue(forKey: receipt.instance)
        document["profiles"] = profiles
        if document["defaultProfile"] as? String == receipt.instance {
            document["defaultProfile"] = profiles.keys.sorted().first
        }
        if profiles.isEmpty {
            try FileManager.default.removeItem(at: profileURL)
        } else {
            try writeProtected(
                try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]),
                to: profileURL, mode: 0o644)
        }
    }
    func restoreGlobalProfiles(_ previous: Data?) throws {
        if let previous {
            try writeProtected(previous, to: profileURL, mode: 0o644)
        } else if exists(profileURL) {
            try requireOwned(profileURL, uid: 0, directory: false)
            try FileManager.default.removeItem(at: profileURL)
        }
    }
}
