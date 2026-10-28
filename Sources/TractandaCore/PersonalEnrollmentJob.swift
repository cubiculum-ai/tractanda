import Foundation

package struct PersonalEnrollmentSourceJob: Codable, Equatable, Sendable {
    package enum Phase: String, Codable, Sendable {
        case awaitingTarget, planning, staging, committing, copyingBaseline, complete
    }
    package let invitation: PersonalEnrollmentInvitationMetadata
    package let administrator: String
    package let admission: PersonalEnrollmentAdmission
    package var phase: Phase
    package var plan: PersonalEnrollmentPlan?
    package var stagedMembers: [String] = []
    package var committedMembers: [String] = []
    package var lastErrorCode: String?
    package func validate() throws {
        try invitation.validate()
        try admission.validate()
        try PrincipalNames.validate(administrator)
        if let plan {
            try plan.validate()
            guard plan.operationID == invitation.operationID,
                plan.issuerReplicaID == invitation.issuerReplicaID,
                plan.administrator == administrator, plan.admission == admission
            else { throw PersonalEnrollmentError.invalid() }
            let ids = Set(plan.configuration.members.map(\.replicaID))
            guard Set(stagedMembers).isSubset(of: ids), Set(committedMembers).isSubset(of: ids) else {
                throw PersonalEnrollmentError.invalid()
            }
        } else if !stagedMembers.isEmpty || !committedMembers.isEmpty {
            throw PersonalEnrollmentError.invalid()
        }
        guard stagedMembers == Array(Set(stagedMembers)).sorted(),
            committedMembers == Array(Set(committedMembers)).sorted()
        else {
            throw PersonalEnrollmentError.invalid()
        }
        if let lastErrorCode {
            guard lastErrorCode.utf8.count <= 128,
                lastErrorCode.utf8.allSatisfy({
                    (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                })
            else { throw PersonalEnrollmentError.invalid() }
        }
    }
}

package struct PersonalEnrollmentJobRegistry {
    private let files: PersonalEnrollmentStateFiles
    package init(root: URL) { files = .init(root: root) }
    package func job() throws -> PersonalEnrollmentSourceJob? {
        guard let bytes = try files.read("job.bin") else { return nil }
        let job = try JSON.decode(PersonalEnrollmentSourceJob.self, bytes)
        try job.validate()
        guard try JSON.encode(job) == bytes else { throw PersonalEnrollmentError.invalid() }
        return job
    }
    package func write(_ job: PersonalEnrollmentSourceJob, replacing expected: PersonalEnrollmentSourceJob?)
        throws
    {
        try job.validate()
        let old = try files.read("job.bin")
        let current = try self.job()
        guard current == expected else { throw PersonalEnrollmentError.conflict() }
        try files.replace("job.bin", bytes: JSON.encode(job), expected: old)
    }
    private struct KeysHeader: Codable, Equatable {
        let operationID: String
        let configurationDigest: String
        let count: Int
    }
    package func credentials(plan: PersonalEnrollmentPlan) throws -> [PeerCredential] {
        try plan.validate()
        if let bytes = try files.read("keys.bin") { return try decodeKeys(bytes, plan: plan) }
        let members = plan.configuration.members.map(\.replicaID).sorted()
        let digest = try plan.configuration.digest
        var keys: [PeerCredential] = []
        for left in members.indices {
            for right in members.indices where right > left {
                for (initiator, responder) in [
                    (members[left], members[right]), (members[right], members[left]),
                ] {
                    let pairing = try UUID.makeVersion1().uuidString.lowercased()
                    let secret = try PersonalEnrollmentSecret.generate()
                    for (local, remote, starts) in [
                        (initiator, responder, true), (responder, initiator, false),
                    ] {
                        let binding = try PeerExchangeBinding(
                            peerID: remote + (starts ? "-dial" : "-accept"),
                            storeID: plan.configuration.storeID, localReplicaID: local,
                            remoteReplicaID: remote,
                            pairingID: pairing, localIsInitiator: starts, configurationDigest: digest)
                        keys.append(try secret.withBytes { try PeerCredential(binding: binding, secret: $0) })
                    }
                }
            }
        }
        let header = KeysHeader(operationID: plan.operationID, configurationDigest: digest, count: keys.count)
        var bytes = try PersonalEnrollmentPrivateCodec.encode(header, secret: nil)
        for key in keys {
            let encoded = try key.privateEncodedBytes()
            let count = UInt32(encoded.count)
            bytes.append(contentsOf: [
                UInt8(count >> 24), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255),
            ])
            bytes.append(encoded)
        }
        // Complete key material reaches protected disk before any member receives a key.
        try files.replace("keys.bin", bytes: bytes, expected: nil)
        return keys
    }
    private func decodeKeys(_ bytes: Data, plan: PersonalEnrollmentPlan) throws -> [PeerCredential] {
        guard bytes.count >= 4 else { throw PersonalEnrollmentError.invalid() }
        let count = bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard Int(count) <= bytes.count - 4 else { throw PersonalEnrollmentError.invalid() }
        let header = try JSON.decode(KeysHeader.self, Data(bytes.dropFirst(4).prefix(Int(count))))
        guard header.operationID == plan.operationID,
            try header.configurationDigest == plan.configuration.digest,
            header.count == 2 * plan.configuration.members.count * (plan.configuration.members.count - 1),
            header.count <= 512
        else { throw PersonalEnrollmentError.conflict() }
        var offset = 4 + Int(count)
        var keys: [PeerCredential] = []
        for _ in 0..<header.count {
            guard offset <= bytes.count - 4 else { throw PersonalEnrollmentError.invalid() }
            let length = bytes[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            offset += 4
            guard length <= 4096, Int(length) <= bytes.count - offset else {
                throw PersonalEnrollmentError.invalid()
            }
            let key = try PeerCredential.decode(Data(bytes[offset..<(offset + Int(length))]))
            offset += Int(length)
            guard key.binding.configurationDigest == header.configurationDigest,
                key.binding.storeID == plan.configuration.storeID,
                plan.configuration.members.contains(where: { $0.replicaID == key.binding.localReplicaID }),
                plan.configuration.members.contains(where: { $0.replicaID == key.binding.remoteReplicaID })
            else { throw PersonalEnrollmentError.invalid() }
            keys.append(key)
        }
        guard offset == bytes.count,
            Set(keys.map { $0.binding.localReplicaID + "|" + $0.binding.peerID }).count == keys.count
        else { throw PersonalEnrollmentError.invalid() }
        let pairs = Dictionary(grouping: keys, by: { $0.binding.pairingID })
        guard
            pairs.values.allSatisfy({ pair in
                guard pair.count == 2 else { return false }
                let left = pair[0]
                let right = pair[1]
                return left.binding.localReplicaID == right.binding.remoteReplicaID
                    && left.binding.remoteReplicaID == right.binding.localReplicaID
                    && left.binding.localIsInitiator != right.binding.localIsInitiator
                    && left.withTLSInput({ _, bytes in bytes }) == right.withTLSInput({ _, bytes in bytes })
            })
        else { throw PersonalEnrollmentError.invalid() }
        return keys
    }
    package func clearCredentials() throws {
        guard let bytes = try files.read("keys.bin") else { return }
        try files.remove("keys.bin", expected: bytes)
    }
}

package struct PersonalEnrollmentStagePacket: Codable, Sendable {
    package let plan: PersonalEnrollmentPlan
    package let privateCredentials: [String]
    package init(plan: PersonalEnrollmentPlan, credentials: [PeerCredential], localReplicaID: String) throws {
        self.plan = plan
        privateCredentials = try credentials.filter { $0.binding.localReplicaID == localReplicaID }.map {
            try $0.privateEncodedBytes().base64EncodedString()
        }
    }
    package func credentials(localReplicaID: String) throws -> [PeerCredential] {
        try plan.validate()
        guard privateCredentials.count == 2 * (plan.configuration.members.count - 1) else {
            throw PersonalEnrollmentError.invalid()
        }
        var decodedBytes = 0
        let keys = try privateCredentials.map { text in
            guard let bytes = Data(base64Encoded: text), bytes.base64EncodedString() == text,
                bytes.count <= 4096
            else {
                throw PersonalEnrollmentError.invalid()
            }
            let key = try PeerCredential.decode(bytes)
            decodedBytes += bytes.count
            guard key.binding.localReplicaID == localReplicaID,
                try key.binding.configurationDigest == plan.configuration.digest
            else {
                throw PersonalEnrollmentError.invalid()
            }
            return key
        }
        let expected = Set(
            plan.configuration.members.filter { $0.replicaID != localReplicaID }.flatMap {
                [$0.replicaID + "-dial", $0.replicaID + "-accept"]
            })
        guard decodedBytes <= 128 * 1024, Set(keys.map { $0.binding.peerID }) == expected,
            Set(keys.map { $0.binding.pairingID }).count == keys.count,
            keys.allSatisfy({
                $0.binding.peerID == $0.binding.remoteReplicaID
                    + ($0.binding.localIsInitiator ? "-dial" : "-accept")
            })
        else {
            throw PersonalEnrollmentError.invalid()
        }
        return keys
    }
    package static func decodeStrict(_ bytes: Data) throws -> Self {
        guard bytes.count <= 448 * 1024,
            let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            Set(object.keys) == ["plan", "privateCredentials"], let plan = object["plan"]
        else { throw PersonalEnrollmentError.invalid() }
        _ = try PersonalEnrollmentPlan.decodeStrict(JSONSerialization.data(withJSONObject: plan))
        return try JSON.decode(Self.self, bytes)
    }
}
