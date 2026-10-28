import Foundation

/// Logical admission names only. Numeric IDs, legacy numeric mappings, service ownership
/// and OS administrator-group settings are host-local and never cross this boundary.
package struct PersonalEnrollmentAdmission: Codable, Equatable, Sendable {
    package let users: [String]
    package let groups: [String]
    package let userAliases: [String: String]
    package let groupAliases: [String: String]
    package init(configuration: AccessConfiguration) throws {
        users = configuration.users.sorted(); groups = configuration.groups.sorted()
        userAliases = configuration.userAliases; groupAliases = configuration.groupAliases
        try validate()
    }
    package func validate() throws {
        guard users == Array(Set(users)).sorted(), groups == Array(Set(groups)).sorted(),
            try JSON.encode(self).count <= 128 * 1024 else {
            throw TractandaError("configurationDrift", "Shared admission policy exceeds its bounded logical form.")
        }
        _ = try AccessConfiguration(value)
    }
    package var value: ItemValue { .object([
        "profile": .text(AccessConfiguration.profile),
        "users": .list(users.map(ItemValue.text)), "groups": .list(groups.map(ItemValue.text)),
        "userAliases": .object(userAliases.mapValues(ItemValue.text)),
        "groupAliases": .object(groupAliases.mapValues(ItemValue.text)),
    ]) }
    package var digest: String { get throws { try validate(); return try PersonalSyncValidation.digest(JSON.encode(self)) } }

    /// Called only after explicit local join acceptance. It preserves the host's OS admin
    /// and numeric/legacy maps and refuses unknown or ambiguous names rather than dropping
    /// principals, changing accounts or widening the requested logical admission set.
    package func applying(to hostValue: ItemValue, accounts: any AccountDirectory) throws -> ItemValue {
        try validate()
        _ = try AccessConfiguration(hostValue)
        guard var fields = hostValue.map, let shared = value.map else { throw PersonalEnrollmentError.invalid() }
        for key in ["users", "groups", "userAliases", "groupAliases"] { fields[key] = shared[key] }
        let next = ItemValue.object(fields)
        let configuration = try AccessConfiguration(next)
        do {
            try configuration.validate(using: PrincipalResolver(directory: accounts, configuration: configuration))
        } catch {
            throw TractandaError("configurationDrift", "A shared user, group or alias has no unambiguous local OS mapping.")
        }
        return next
    }

    package func requireSameLogicalPolicy(_ host: AccessConfiguration) throws {
        guard try Self(configuration: host) == self else {
            throw TractandaError("configurationDrift", "A retained member's logical user/group admission policy differs.")
        }
    }
}
