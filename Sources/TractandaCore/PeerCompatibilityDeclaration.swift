import Foundation
import TractandaClient

package struct PeerCompatibilityDeclaration: Codable, Equatable, Sendable {
    package static let semanticProfile = "tractanda.peer-exchange.v2"
    package static let maximumBytes = 65_536

    package let profile: String
    package let support: CanonicalFormatSupport
    package let requirement: CanonicalReaderRequirement

    package init(support: CanonicalFormatSupport, requirement: CanonicalReaderRequirement) throws {
        profile = Self.semanticProfile
        self.support = support
        self.requirement = requirement
        try validate()
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case profile, support, requirement
    }

    package init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: PeerCompatibilityCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw Self.failure("Unknown peer compatibility declaration fields.")
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profile = try container.decode(String.self, forKey: .profile)
        support = try container.decode(CanonicalFormatSupport.self, forKey: .support)
        requirement = try container.decode(CanonicalReaderRequirement.self, forKey: .requirement)
        try validate()
    }

    package func validate() throws {
        guard profile == Self.semanticProfile else {
            throw Self.failure("Unsupported peer semantic profile.")
        }
        try support.validate()
        try requirement.validate()
        try support.require(requirement)
    }

    package func encoded() throws -> Data {
        try validate()
        let data = try JSON.encode(self)
        guard data.count <= Self.maximumBytes else {
            throw TractandaError("resourceLimit", "Peer compatibility declaration exceeds its byte limit.")
        }
        return data
    }

    package static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else {
            throw TractandaError("resourceLimit", "Peer compatibility declaration exceeds its byte limit.")
        }
        let value = try JSON.decode(Self.self, data)
        try value.validate()
        guard try value.encoded() == data else {
            throw failure("Peer compatibility declaration is not in canonical encoding.")
        }
        return value
    }

    package func requireCompatible(with other: Self) throws {
        try validate()
        try other.validate()
        guard profile == other.profile, requirement.storeID == other.requirement.storeID else {
            throw Self.failure("Peer declarations identify different semantic profiles or stores.")
        }
        try support.require(other.requirement)
        try support.requireWriter(other.support)
        try other.support.require(requirement)
        try other.support.requireWriter(support)
    }

    private static func failure(_ message: String) -> TractandaError {
        TractandaError("incompatiblePeer", message)
    }
}

package struct PeerCompatibilityAcknowledgement: Codable, Equatable, Sendable {
    package static let semanticProfile = PeerCompatibilityDeclaration.semanticProfile
    private static let maximumBytes = 4096

    package let profile: String
    package let declarationSHA256: String

    package init(declaration: PeerCompatibilityDeclaration) throws {
        profile = Self.semanticProfile
        declarationSHA256 = AuthorityRecordCodec.sha256(try declaration.encoded())
        try validate()
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case profile, declarationSHA256
    }

    package init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: PeerCompatibilityCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw Self.failure("Unknown peer compatibility acknowledgement fields.")
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profile = try container.decode(String.self, forKey: .profile)
        declarationSHA256 = try container.decode(String.self, forKey: .declarationSHA256)
        try validate()
    }

    package func encoded() throws -> Data {
        try validate()
        let data = try JSON.encode(self)
        guard data.count <= Self.maximumBytes else {
            throw TractandaError(
                "resourceLimit", "Peer compatibility acknowledgement exceeds its byte limit.")
        }
        return data
    }

    package static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else {
            throw TractandaError(
                "resourceLimit", "Peer compatibility acknowledgement exceeds its byte limit.")
        }
        let value = try JSON.decode(Self.self, data)
        try value.validate()
        guard try value.encoded() == data else {
            throw failure("Peer compatibility acknowledgement is not in canonical encoding.")
        }
        return value
    }

    package func matches(declaration: PeerCompatibilityDeclaration) throws {
        try validate()
        let digest = AuthorityRecordCodec.sha256(try declaration.encoded())
        guard profile == Self.semanticProfile, declarationSHA256 == digest else {
            throw Self.failure("Peer acknowledgement does not match this declaration.")
        }
    }

    private func validate() throws {
        guard profile == Self.semanticProfile, Self.isSHA256(declarationSHA256) else {
            throw Self.failure("Invalid peer compatibility acknowledgement.")
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }

    private static func failure(_ message: String) -> TractandaError {
        TractandaError("incompatiblePeer", message)
    }
}

private struct PeerCompatibilityCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
