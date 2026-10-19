import Foundation

/// Actual policy evaluation for metadata intake. Source group numbers are testimony; names are
/// evaluated against exact attested canonical policies. Current rights use fresh local NSS data.
struct RuntimeAuthorityEvaluator {
    let accounts: any AccountDirectory
    let currentConfigurations: [AccessConfiguration]
    let currentItemPolicies: [Revision]
    let ownerUID: UInt32
    let loadBinding: (ItemValue) throws -> AuthorityRevision?

    func evaluate(
        _ node: AuthorityRevision, evidence: AuthorityRecord, sourceOnly: Bool = false,
        allowPolicy: Bool = false, historicalPreserved: Bool = false, originalsVerified: Bool = false
    ) throws -> AuthorityStore.Evaluation {
        let revision = node.revision
        let payload = evidence.payload
        let target = try AuthorityRecord.binding(payload["target"])
        guard target.revisionID == revision.revisionID, target.itemID == revision.itemID,
            target.sha256 == node.sha256, evidence.kind == .authoredEvidence,
            evidence.originReplicaID == (try revision.provenance?.originReplicaID),
            evidence.actorPrincipal == payload["principal"]?.string,
            revision.fields["actor"]?.string == "user:" + evidence.actorPrincipal
                || revision.fields["actor"]?.string == "uid:" + String(payload["sourceUID"]!.integerValue!),
            try AuthorityRecord.ids(payload["parents"], maximum: 1024) == node.parents,
            let provenance = try revision.provenance, provenance.kind == .authored,
            payload["intent"]?.map?["writtenFields"] == .list(provenance.writtenFields.map(ItemValue.text)),
            payload["intent"]?.map?["unsetFields"] == .list(provenance.unsetFields.map(ItemValue.text))
        else {
            throw TractandaError(
                "invalidAuthority", "Authored evidence differs from original identity/intent.")
        }
        guard payload["evaluated"] == .boolean(true) else {
            return held("Source did not authorize this intent.")
        }
        guard try AuthorityRecord.list(payload["acceptedAuthority"]).isEmpty
        else {
            return held("Protected review acceptance requires the atomic review stage.")
        }
        // This internal readiness fact covers bytes only; every source/current authority check
        // below still applies. Unknown callers retain the default storage denial.
        if try !originalsVerified
            && (!AttachmentDescriptor.descriptors(in: revision.fields).isEmpty
                || !AttachmentDocumentRepresentation.representations(in: revision.fields).isEmpty)
        {
            return .init(
                disposition: .missingDependencies,
                reason: "Exact original/document storage closure is unavailable.")
        }
        // Verified original/text storage updates use the same source/current item-write proof
        // as their dedicated local APIs. They do not authorize any protected policy change.
        let protectedFields =
            originalsVerified
            ? RevisionMerge.protectedFields.subtracting([
                "attachments", "attachmentText", "attachmentDocument",
            ])
            : RevisionMerge.protectedFields
        let policyTransition =
            allowPolicy && revision.classID == AccessConfiguration.classID && !node.parents.isEmpty
        if !policyTransition
            && (revision.classID != "Item" || RevisionMerge.protectedClasses.contains(revision.classID)
                || (!node.parents.isEmpty
                    && !Set(provenance.writtenFields + provenance.unsetFields).isDisjoint(
                        with: protectedFields)))
        {
            return held("Protected metadata requires the reviewed admission stage.")
        }
        if node.parents.isEmpty {
            let allowedRootMetadata: Set<String> = ["classID", "schemaVersion", "permissions", "isDeleted"]
            if !Set(provenance.writtenFields).intersection(RevisionMerge.protectedFields).subtracting(
                allowedRootMetadata
            ).isEmpty
                || revision.isDeleted
            {
                return held("Protected new-item metadata requires reviewed admission.")
            }
        }
        let principal = evidence.actorPrincipal
        let sourceGroups = Set(payload["groups"]!.map!.keys)
        let admissions = try AuthorityRecord.list(payload["admissionPolicies"])
        // Empty legacy admission has no portable service-owner identity. Only the explicit
        // baseline may carry that history; do not invent a source administrator from a UID.
        guard !admissions.isEmpty else { return held("Source admission policy is unknown.") }
        var canonicalAliases: [String: String] = [:]
        var sourceAdministrator = true
        for binding in admissions {
            guard let policy = try loadBinding(binding),
                policy.revision.classID == AccessConfiguration.classID,
                let value = policy.revision.fields["accessConfiguration"]
            else { return missing() }
            let configuration = try AccessConfiguration(value)
            for (alias, target) in configuration.userAliases.merging(
                configuration.groupAliases, uniquingKeysWith: { left, right in left == right ? left : "" })
            {
                guard !target.isEmpty, canonicalAliases[alias] == nil || canonicalAliases[alias] == target
                else {
                    return held("Source alias namespaces require explicit mapping review.")
                }
                canonicalAliases[alias] = target
            }
            let name = principal
            let admitted =
                configuration.users.contains { (configuration.userAliases[$0] ?? $0) == name }
                || configuration.groups.contains { group in
                    sourceGroups.contains {
                        (configuration.groupAliases[$0] ?? $0) == (configuration.groupAliases[group] ?? group)
                    }
                }
            let administrator = try SourceAdministration.administrator(configuration, evidence: evidence)
            sourceAdministrator = sourceAdministrator && administrator
            guard admitted || administrator else {
                return held("Canonical source admission does not allow the principal.")
            }
        }
        guard payload["aliases"]?.map == canonicalAliases.mapValues(ItemValue.text) else {
            throw TractandaError(
                "invalidAuthority", "Alias testimony differs from bound canonical source configuration.")
        }
        if policyTransition && !sourceAdministrator {
            return held("Source policy transition requires its current administrator.")
        }
        let itemPolicies = try AuthorityRecord.list(payload["itemPolicies"])
        if node.parents.isEmpty {
            guard itemPolicies.isEmpty, let value = revision.fields["permissions"],
                try ItemPermissions(value).owner == principal
            else { return held("New item owner does not match its author.") }
        } else {
            guard !itemPolicies.isEmpty else { return missing() }
            for binding in itemPolicies {
                guard let policy = try loadBinding(binding), policy.revision.itemID == revision.itemID
                else { return missing() }
                if policyTransition {
                    guard sourceAdministrator,
                        policy.revision.classID == AccessConfiguration.classID,
                        policy.revision.fields["accessConfiguration"] != nil
                    else {
                        return held(
                            "Policy transition requires its exact administrator-authorized predecessor.")
                    }
                    continue  // Store configuration has administrator authority, not an item ACL.
                }
                guard let value = policy.revision.fields["permissions"] else { return missing() }
                guard
                    try sourceAdministrator
                        || (Self.sourceAllows(
                            ItemPermissions(value), principal: principal, groups: sourceGroups,
                            aliases: payload["aliases"]!.map!))
                else {
                    return held("Canonical source item policy does not allow the intent.")
                }
            }
        }
        if sourceOnly || historicalPreserved {
            return .init(
                disposition: .eligible,
                reason: sourceOnly
                    ? "Exact source-cut authority permits this intent."
                    : "Validated pre-revocation acceptance preserves this historical intent.")
        }
        do {
            let configuration = currentConfigurations.first
            let resolver = PrincipalResolver(directory: accounts, configuration: configuration)
            let account = try accounts.user(named: configuration?.userAliases[principal] ?? principal)
            if currentConfigurations.isEmpty {
                guard account.uid == ownerUID else {
                    return held("Current store admission denies the principal.")
                }
            }
            var currentAdministrator = !currentConfigurations.isEmpty
            for configuration in currentConfigurations {
                let localResolver = PrincipalResolver(directory: accounts, configuration: configuration)
                let admitted =
                    try configuration.users.contains { try localResolver.userID($0) == account.uid }
                    || configuration.groups.contains {
                        try account.groupIDs.contains(localResolver.groupID($0))
                    }
                let administrator: Bool
                if configuration.administration == .serviceOwner {
                    administrator = account.uid == ownerUID
                } else if account.uid == 0 {
                    administrator = true
                } else {
                    administrator = try account.groupIDs.contains(
                        accounts.groupID(
                            named: configuration.administratorGroup
                                ?? AccessConfiguration.defaultAdministratorGroup))
                }
                currentAdministrator = currentAdministrator && administrator
                guard admitted || administrator else {
                    return held("Current store admission requires review.")
                }
            }
            if policyTransition && !currentAdministrator {
                return held("Current policy transition requires administrator review.")
            }
            let policies = currentItemPolicies.isEmpty ? [revision] : currentItemPolicies
            for policy in policies {
                guard
                    try currentAdministrator
                        || (policy.fields["permissions"].map {
                            try ItemPermissions($0).allows(6, for: account, using: resolver)
                        } == true)
                else {
                    return held("Current item policy requires administrator review.")
                }
            }
        } catch let error as TractandaError
            where ["unresolvedPrincipal", "ambiguousPrincipal"].contains(error.code)
        {
            return held("Current principal mapping is unknown; original evidence is retained.")
        }
        return .init(
            disposition: .eligible,
            reason: "Source and current canonical authority permit this metadata intent.")
    }
    static func sourceAllows(
        _ policy: ItemPermissions, principal: String, groups: Set<String>, aliases: [String: ItemValue],
        identityAliases: [String: ItemValue]? = nil
    ) throws -> Bool {
        func name(_ value: String) -> String { aliases[value]?.string ?? value }
        if name(policy.owner) == principal { return (policy.mode >> 6) & 6 == 6 }
        let mask = policy.mask ?? ((policy.mode >> 3) & 7)
        let named = policy.users.filter { name($0.key) == principal }
        guard named.count <= 1 else {
            throw TractandaError("invalidAuthority", "Ambiguous source ACL testimony.")
        }
        if let rights = named.first?.value { return rights & mask & 6 == 6 }
        let identity = identityAliases ?? aliases
        let names = Set(groups.map { identity[$0]?.string ?? $0 })
        var matched = false
        if names.contains(name(policy.group)) {
            matched = true
            if policy.owningGroupPermissions & mask & 6 == 6 { return true }
        }
        for (group, rights) in policy.groups where names.contains(name(group)) {
            matched = true
            if rights & mask & 6 == 6 { return true }
        }
        return !matched && policy.mode & 6 == 6
    }
    private func held(_ reason: String) -> AuthorityStore.Evaluation {
        .init(disposition: .held, reason: reason)
    }
    private func missing() -> AuthorityStore.Evaluation {
        .init(disposition: .missingDependencies, reason: "Canonical policy dependency is missing.")
    }
}
