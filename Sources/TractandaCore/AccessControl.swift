import CTractandaPlatform
import Foundation

/// An OS account snapshot, refreshed at each authenticated request.
public struct AccountIdentity: Sendable {
    public let uid: UInt32
    public let name: String
    public let primaryGroupName: String
    public let groupIDs: Set<UInt32>

    public init(uid: UInt32, name: String, primaryGroupName: String, groupIDs: Set<UInt32>) {
        self.uid = uid
        self.name = name
        self.primaryGroupName = primaryGroupName
        self.groupIDs = groupIDs
    }
}

public protocol AccountDirectory {
    func user(forUID uid: UInt32) throws -> AccountIdentity
    func user(named name: String) throws -> AccountIdentity
    func groupID(named name: String) throws -> UInt32
}

/// Uses the host account database; request arguments never establish an identity.
public struct SystemAccountDirectory: AccountDirectory {
    public init() {}

    public func user(forUID uid: UInt32) throws -> AccountIdentity {
        var name = [CChar](repeating: 0, count: 1024)
        var primary: UInt32 = 0
        guard tractanda_user_name(uid, &name, name.count, &primary) == 0 else {
            throw TractandaError("unresolvedPrincipal", "The OS user is unavailable.")
        }
        let username = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        var groupName = [CChar](repeating: 0, count: 1024)
        guard tractanda_group_name(primary, &groupName, groupName.count) == 0 else {
            throw TractandaError("unresolvedPrincipal", "The primary OS group is unavailable.")
        }
        var count: Int32 = 32
        var groups = [UInt32](repeating: 0, count: Int(count))
        var result = tractanda_user_groups(username, primary, &groups, &count)
        if result < 0, count > 32, count <= 65536 {
            groups = [UInt32](repeating: 0, count: Int(count))
            result = tractanda_user_groups(username, primary, &groups, &count)
        }
        guard result >= 0, count > 0, Int(count) <= groups.count else {
            throw TractandaError("unresolvedPrincipal", "Cannot resolve current OS group membership.")
        }
        return AccountIdentity(
            uid: uid, name: username,
            primaryGroupName: String(
                decoding: groupName.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self),
            groupIDs: Set(groups.prefix(Int(count))).union([primary]))
    }

    public func user(named name: String) throws -> AccountIdentity {
        try PrincipalNames.validate(name)
        var uid: UInt32 = 0
        guard tractanda_user_id(name, &uid) == 0 else {
            throw TractandaError("unresolvedPrincipal", "Unknown OS user: \(name).")
        }
        return try user(forUID: uid)
    }

    public func groupID(named name: String) throws -> UInt32 {
        try PrincipalNames.validate(name)
        var gid: UInt32 = 0
        guard tractanda_group_id(name, &gid) == 0 else {
            throw TractandaError("unresolvedPrincipal", "Unknown OS group: \(name).")
        }
        return gid
    }
}

enum PrincipalNames {
    static func validate(_ name: String) throws {
        guard !name.isEmpty, name.utf8.count <= 128,
            name.utf8.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                    || [45, 46, 95, 36].contains($0)
            })
        else { throw TractandaError("invalidPrincipal", "Use a Unix account name of at most 128 bytes.") }
    }
}

/// Canonical, administrator-owned configuration; aliases are direct many-to-one mappings.
public struct AccessConfiguration: Sendable {
    public static let profile = "tractanda.access.v1"
    public static let classID = "AccessConfigurationItem"
    public let users: [String]
    public let groups: [String]
    public let userAliases: [String: String]
    public let groupAliases: [String: String]
    /// Absent configurations retain the original service-owner administration rule.
    public let administration: Administration
    public let administratorGroup: String?
    /// Explicit migration bridge for receipts made by an earlier service UID.
    public let legacyUsers: [UInt32: String]

    public enum Administration: String, Sendable {
        case serviceOwner
        case system
    }

    public init(_ value: ItemValue) throws {
        guard let fields = value.map, fields["profile"]?.string == Self.profile,
            Set(fields.keys).isSubset(of: [
                "profile", "users", "groups", "userAliases", "groupAliases", "administration",
                "administratorGroup", "legacyUsers",
            ])
        else { throw TractandaError("invalidAccessConfiguration", "Unknown access profile or fields.") }
        func names(_ key: String) throws -> [String] {
            guard let entries = fields[key]?.array ?? (fields[key] == nil ? [] : nil), entries.count <= 256
            else { throw TractandaError("invalidAccessConfiguration", "Expected bounded user/group lists.") }
            let names = try entries.map { entry -> String in
                guard let name = entry.string else {
                    throw TractandaError("invalidAccessConfiguration", "Principal names must be text.")
                }
                try PrincipalNames.validate(name)
                return name
            }
            guard Set(names).count == names.count else {
                throw TractandaError("invalidAccessConfiguration", "Duplicate principal name.")
            }
            return names
        }
        func aliases(_ key: String) throws -> [String: String] {
            guard let entries = fields[key]?.map ?? (fields[key] == nil ? [:] : nil), entries.count <= 256
            else { throw TractandaError("invalidAccessConfiguration", "Expected a bounded alias object.") }
            var result: [String: String] = [:]
            for (name, value) in entries {
                guard let target = value.string else {
                    throw TractandaError("invalidAccessConfiguration", "Alias targets must be names.")
                }
                try PrincipalNames.validate(name)
                try PrincipalNames.validate(target)
                result[name] = target
            }
            guard result.allSatisfy({ $0.key == $0.value || result[$0.value] == nil }) else {
                throw TractandaError(
                    "invalidAccessConfiguration", "Aliases must resolve directly; no chains or cycles.")
            }
            return result
        }
        users = try names("users")
        groups = try names("groups")
        userAliases = try aliases("userAliases")
        groupAliases = try aliases("groupAliases")
        if let value = fields["administration"] {
            guard let text = value.string, let administration = Administration(rawValue: text) else {
                throw TractandaError(
                    "invalidAccessConfiguration", "Administration must be system or serviceOwner.")
            }
            self.administration = administration
        } else {
            administration = .serviceOwner
        }
        if let value = fields["administratorGroup"] {
            guard administration == .system, let name = value.string else {
                throw TractandaError(
                    "invalidAccessConfiguration",
                    "administratorGroup is only valid for system administration.")
            }
            try PrincipalNames.validate(name)
            administratorGroup = name
        } else {
            administratorGroup = nil
        }
        guard let entries = fields["legacyUsers"]?.map ?? (fields["legacyUsers"] == nil ? [:] : nil),
            entries.count <= 256
        else { throw TractandaError("invalidAccessConfiguration", "Expected a bounded legacyUsers object.") }
        var mapped: [UInt32: String] = [:]
        for (actor, value) in entries {
            guard actor.hasPrefix("uid:"), let uid = UInt32(actor.dropFirst(4)), actor == "uid:\(uid)",
                mapped[uid] == nil, let name = value.string
            else {
                throw TractandaError(
                    "invalidAccessConfiguration", "legacyUsers maps exact uid:<number> actors to user names.")
            }
            try PrincipalNames.validate(name)
            mapped[uid] = name
        }
        legacyUsers = mapped
    }

    func validate(using resolver: PrincipalResolver) throws {
        for name in users { _ = try resolver.userID(name) }
        for name in groups { _ = try resolver.groupID(name) }
        for (alias, target) in userAliases {
            let uid = try resolver.userID(target)
            if let existing = try? resolver.directory.user(named: alias), existing.uid != uid {
                throw TractandaError("ambiguousPrincipal", "A user alias conflicts with an OS account.")
            }
        }
        for (alias, target) in groupAliases {
            let gid = try resolver.groupID(target)
            if let existing = try? resolver.directory.groupID(named: alias), existing != gid {
                throw TractandaError("ambiguousPrincipal", "A group alias conflicts with an OS group.")
            }
        }
        for name in legacyUsers.values { _ = try resolver.userID(name) }
        if administration == .system {
            // Administration must be anchored in the OS directory, never in editable aliases.
            _ = try resolver.directory.groupID(named: administratorGroup ?? Self.defaultAdministratorGroup)
        }
    }

    static var defaultAdministratorGroup: String {
        #if os(macOS)
            return "admin"
        #else
            return "sudo"
        #endif
    }
}

/// Memoized only for one synchronous request; OS membership is refreshed on the next request.
final class PrincipalResolver {
    let directory: any AccountDirectory
    let configuration: AccessConfiguration?
    private var users: [String: UInt32] = [:]
    private var groups: [String: UInt32] = [:]

    init(directory: any AccountDirectory, configuration: AccessConfiguration?) {
        self.directory = directory
        self.configuration = configuration
    }

    func userID(_ name: String) throws -> UInt32 {
        if let value = users[name] { return value }
        let value = try directory.user(named: configuration?.userAliases[name] ?? name).uid
        users[name] = value
        return value
    }

    func groupID(_ name: String) throws -> UInt32 {
        if let value = groups[name] { return value }
        let value = try directory.groupID(named: configuration?.groupAliases[name] ?? name)
        groups[name] = value
        return value
    }
}

/// POSIX file read/write semantics. Execute and directory inheritance are outside this item profile.
public struct ItemPermissions: Sendable {
    public static let profile = "tractanda.permissions.posix.v1"
    public let owner: String
    public let group: String
    public let mode: Int
    public let users: [String: Int]
    public let groups: [String: Int]
    public let mask: Int?
    public let owningGroupPermissions: Int

    public init(_ value: ItemValue) throws {
        guard let fields = value.map, fields["profile"]?.string == Self.profile,
            Set(fields.keys) == ["profile", "owner", "group", "mode", "acl"],
            let owner = fields["owner"]?.string, let group = fields["group"]?.string,
            case .integer(let mode)? = fields["mode"], mode >= 0, mode <= 0o777, mode & 0o111 == 0,
            let acl = fields["acl"]?.map,
            Set(acl.keys).isSubset(of: ["users", "groups", "mask", "owningGroup"])
        else { throw TractandaError("invalidPermissions", "Expected a POSIX read/write item descriptor.") }
        try PrincipalNames.validate(owner)
        try PrincipalNames.validate(group)
        func entries(_ key: String) throws -> [String: Int] {
            guard let entries = acl[key]?.map ?? (acl[key] == nil ? [:] : nil), entries.count <= 256 else {
                throw TractandaError("invalidPermissions", "Expected bounded named ACL entries.")
            }
            var result: [String: Int] = [:]
            for (name, entry) in entries {
                try PrincipalNames.validate(name)
                guard case .integer(let rights) = entry, rights >= 0, rights <= 6, rights & 1 == 0 else {
                    throw TractandaError("invalidPermissions", "ACL rights are 0, 2, 4 or 6.")
                }
                result[name] = Int(rights)
            }
            return result
        }
        self.owner = owner
        self.group = group
        self.mode = Int(mode)
        users = try entries("users")
        groups = try entries("groups")
        if let value = acl["mask"] {
            guard case .integer(let value) = value, value >= 0, value <= 6, value & 1 == 0,
                Int(value) == (Int(mode) >> 3) & 7
            else {
                throw TractandaError("invalidPermissions", "The ACL mask must match the group mode bits.")
            }
            mask = Int(value)
            guard case .integer(let groupRights)? = acl["owningGroup"], groupRights >= 0,
                groupRights <= 6, groupRights & 1 == 0
            else { throw TractandaError("invalidPermissions", "An extended ACL needs owningGroup rights.") }
            owningGroupPermissions = Int(groupRights)
        } else {
            guard users.isEmpty, groups.isEmpty, acl["owningGroup"] == nil else {
                throw TractandaError("invalidPermissions", "Named ACL entries require a mask.")
            }
            mask = nil
            owningGroupPermissions = (Int(mode) >> 3) & 7
        }
    }

    public static func privateValue(for account: AccountIdentity) -> ItemValue {
        .object([
            "profile": .text(profile), "owner": .text(account.name), "group": .text(account.primaryGroupName),
            "mode": .integer(0o600), "acl": .object([:]),
        ])
    }

    func validate(using resolver: PrincipalResolver) throws {
        _ = try resolver.userID(owner)
        _ = try resolver.groupID(group)
        let userIDs = try users.keys.map { try resolver.userID($0) }
        let groupIDs = try groups.keys.map { try resolver.groupID($0) }
        guard Set(userIDs).count == userIDs.count, Set(groupIDs).count == groupIDs.count else {
            throw TractandaError("ambiguousPrincipal", "Several ACL entries resolve to the same principal.")
        }
    }

    func allows(_ rights: Int, for account: AccountIdentity, using resolver: PrincipalResolver) throws -> Bool
    {
        try validate(using: resolver)
        if try resolver.userID(owner) == account.uid { return ((mode >> 6) & rights) == rights }
        let mask = mask ?? ((mode >> 3) & 7)
        for (name, permissions) in users where try resolver.userID(name) == account.uid {
            return permissions & mask & rights == rights
        }
        var matchedGroup = false
        if try account.groupIDs.contains(resolver.groupID(group)) {
            matchedGroup = true
            if owningGroupPermissions & mask & rights == rights { return true }
        }
        for (name, permissions) in groups where try account.groupIDs.contains(resolver.groupID(name)) {
            matchedGroup = true
            if permissions & mask & rights == rights { return true }
        }
        // POSIX does not fall through to 'other' after a user/group match.
        return !matchedGroup && mode & rights == rights
    }
}

struct StoreAccessContext {
    let uid: UInt32
    let account: AccountIdentity?
    let resolver: PrincipalResolver
    let isAdministrator: Bool
}
