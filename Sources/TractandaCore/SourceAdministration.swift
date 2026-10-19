import Foundation

/// Source-host semantics carried only by authenticated configured-server testimony.
/// These names never establish a receiving-host account or numeric privilege.
struct SourceAdministration: Equatable, Sendable {
    let defaultAdministratorGroup: String
    let serviceOwnerPrincipal: String

    init(defaultAdministratorGroup: String, serviceOwnerPrincipal: String) throws {
        try PrincipalNames.validate(defaultAdministratorGroup)
        try PrincipalNames.validate(serviceOwnerPrincipal)
        self.defaultAdministratorGroup = defaultAdministratorGroup
        self.serviceOwnerPrincipal = serviceOwnerPrincipal
    }

    init(_ value: ItemValue) throws {
        let fields = try AuthorityRecord.object(
            value, keys: ["defaultAdministratorGroup", "serviceOwnerPrincipal"])
        try self.init(
            defaultAdministratorGroup: AuthorityRecord.text(fields["defaultAdministratorGroup"]),
            serviceOwnerPrincipal: AuthorityRecord.text(fields["serviceOwnerPrincipal"]))
    }

    var itemValue: ItemValue {
        .object([
            "defaultAdministratorGroup": .text(defaultAdministratorGroup),
            "serviceOwnerPrincipal": .text(serviceOwnerPrincipal),
        ])
    }

    func isAdministrator(
        configuration: AccessConfiguration, principal: String, sourceUID: UInt32,
        groups: Set<String>
    ) -> Bool {
        if configuration.administration == .serviceOwner {
            return principal == serviceOwnerPrincipal
        }
        if sourceUID == 0 { return true }
        let required = configuration.administratorGroup ?? defaultAdministratorGroup
        return groups.contains(required)
    }

    static func administrator(_ configuration: AccessConfiguration, evidence: AuthorityRecord) throws -> Bool
    {
        guard let value = evidence.payload["sourceAdministration"],
            let uid = evidence.payload["sourceUID"]?.integerValue,
            let groups = evidence.payload["groups"]?.map
        else { return false }
        return try Self(value).isAdministrator(
            configuration: configuration, principal: evidence.actorPrincipal,
            sourceUID: UInt32(uid), groups: Set(groups.keys))
    }
}
