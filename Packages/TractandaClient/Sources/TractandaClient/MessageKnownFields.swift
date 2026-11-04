import Foundation

/// Compact headers for established field shapes. Other shapes stay in typed field headers.
enum MessageKnownFields {
    private static let permissionsProfile = "tractanda.permissions.posix.v1"

    static func write(_ fields: inout [String: ItemValue], emit: MessageHeaderEmitter) throws {
        if let permissions = fields["permissions"]?.map,
            Set(permissions.keys) == ["profile", "owner", "group", "mode", "acl"],
            permissions["profile"]?.string == permissionsProfile,
            let owner = permissions["owner"]?.string, let group = permissions["group"]?.string,
            MessageHeaderText.isLiteral(owner), MessageHeaderText.isLiteral(group),
            let mode = permissions["mode"]?.integerValue, (0...0o777).contains(mode),
            let acl = permissions["acl"]?.map
        {
            try emit("X-Permissions-Profile", permissionsProfile)
            try emit("X-Permissions-Owner", owner)
            try emit("X-Permissions-Group", group)
            let octal = String(mode, radix: 8)
            try emit("X-Permissions-Mode", String(repeating: "0", count: 4 - octal.count) + octal)
            try MessageTypedFields.write(acl, prefix: "X-ACL-", emit: emit)
            fields["permissions"] = nil
        }
        if let ancestry = try fields["revisionAncestry"].map(RevisionProvenance.init(value:)) {
            try emit("X-Ancestry-Kind", ancestry.kind.rawValue)
            try emit("X-Ancestry-Origin", ancestry.originReplicaID)
            for parent in ancestry.parents { try emit("X-Ancestry-Parent", parent) }
            for key in ancestry.writtenFields {
                try emit("X-Ancestry-Written-Field", MessageHeaderText.escaped(key))
            }
            for key in ancestry.unsetFields {
                try emit("X-Ancestry-Unset-Field", MessageHeaderText.escaped(key))
            }
            for id in ancestry.frontier { try emit("X-Ancestry-Frontier", id) }
            if let profile = ancestry.mergeProfile { try emit("X-Ancestry-Merge-Profile", profile) }
            if let witness = ancestry.authorityWitness {
                try emit("X-Ancestry-Witness", witness.recordID + " " + witness.sha256)
            }
            fields["revisionAncestry"] = nil
        }
        if let parents = currentReferences(fields["categoryParents"]) {
            for parent in parents { try emit("X-Category-Parent", parent.itemID) }
            fields["categoryParents"] = nil
        }
        if let overrides = fields["categoryOverrides"]?.map, !overrides.isEmpty,
            overrides.allSatisfy({ (try? Identifier.validate($0.key)) != nil && $0.value.string != nil })
        {
            for id in MessageTypedFields.sortedKeys(overrides) {
                try emit("X-Category-Override", id + " " + MessageHeaderText.escaped(overrides[id]!.string!))
            }
            fields["categoryOverrides"] = nil
        }
        if let attachments = try? AttachmentDescriptor.descriptors(in: fields), !attachments.isEmpty {
            for attachment in attachments {
                let parts = [
                    attachment.attachmentID, MessageHeaderText.escaped(attachment.filename, quoted: true),
                    attachment.mediaType, String(attachment.byteCount), attachment.sha256,
                ]
                try emit("X-Attachment", parts.joined(separator: " "))
            }
            fields["attachments"] = nil
        }
    }

    static func read(_ headers: inout MessageHeaderReader, into fields: inout [String: ItemValue]) throws {
        if let profile = try headers.single("x-permissions-profile") {
            let text = try MessageHeaderText.word(headers.required("x-permissions-mode"))
            guard profile == permissionsProfile, text.utf8.count == 4, text.utf8.first == 48,
                text.utf8.allSatisfy({ (48...55).contains($0) }), let mode = Int64(text, radix: 8)
            else { throw MessageHeaderText.invalid("Malformed permissions headers.") }
            let owner = try MessageHeaderText.literal(headers.required("x-permissions-owner"))
            let group = try MessageHeaderText.literal(headers.required("x-permissions-group"))
            let acl = try headers.typed(prefix: "x-acl-")
            try MessageRecordCodec.insert(
                .object([
                    "profile": .text(profile), "owner": .text(owner), "group": .text(group),
                    "mode": .integer(mode), "acl": .object(acl),
                ]), key: "permissions", into: &fields)
        }
        if let kind = try headers.single("x-ancestry-kind") {
            guard let parsedKind = RevisionProvenance.Kind(rawValue: try MessageHeaderText.word(kind)) else {
                throw MessageHeaderText.invalid("Unknown ancestry kind.")
            }
            let witness: AuthorityBinding?
            if let value = try headers.single("x-ancestry-witness") {
                var tokens = MessageHeaderTokens(value)
                let id = try tokens.takeWord()
                try tokens.takeSpace()
                let sha = try tokens.takeWord()
                try tokens.requireEnd()
                witness = try AuthorityBinding(recordID: id, sha256: sha)
            } else {
                witness = nil
            }
            let provenance = try RevisionProvenance(
                kind: parsedKind,
                originReplicaID: MessageHeaderText.word(headers.required("x-ancestry-origin")),
                parents: headers.many("x-ancestry-parent").map(MessageHeaderText.word),
                writtenFields: headers.many("x-ancestry-written-field").map(MessageHeaderText.unescaped),
                unsetFields: headers.many("x-ancestry-unset-field").map(MessageHeaderText.unescaped),
                frontier: headers.many("x-ancestry-frontier").map(MessageHeaderText.word),
                mergeProfile: headers.single("x-ancestry-merge-profile"), authorityWitness: witness)
            try MessageRecordCodec.insert(provenance.itemValue, key: "revisionAncestry", into: &fields)
        }
        let parents = headers.many("x-category-parent")
        if !parents.isEmpty {
            let values = try parents.map { row in
                let id = try MessageHeaderText.word(row)
                try Identifier.validate(id)
                return ItemValue.reference(ItemReference(id))
            }
            try MessageRecordCodec.insert(.list(values), key: "categoryParents", into: &fields)
        }
        let overrides = headers.many("x-category-override")
        if !overrides.isEmpty {
            var map: [String: ItemValue] = [:]
            for row in overrides {
                var tokens = MessageHeaderTokens(row)
                let id = try tokens.takeWord()
                try Identifier.validate(id)
                try tokens.takeSeparator()
                try MessageRecordCodec.insert(.text(tokens.takeText()), key: id, into: &map)
            }
            try MessageRecordCodec.insert(.object(map), key: "categoryOverrides", into: &fields)
        }
        let attachments = headers.many("x-attachment")
        if !attachments.isEmpty {
            let values = try attachments.map { row in
                var tokens = MessageHeaderTokens(row)
                let id = try tokens.takeWord()
                try tokens.takeSpace()
                let filename = try tokens.takeQuoted()
                try tokens.takeSpace()
                let mediaType = try tokens.takeWord()
                try tokens.takeSpace()
                guard let byteCount = try Int64(tokens.takeWord()) else {
                    throw MessageHeaderText.invalid("Invalid attachment length.")
                }
                try tokens.takeSpace()
                let sha = try tokens.takeWord()
                try tokens.requireEnd()
                return try AttachmentDescriptor(
                    attachmentID: id, filename: filename,
                    mediaType: mediaType, byteCount: byteCount, sha256: sha
                ).itemValue
            }
            try MessageRecordCodec.insert(.list(values), key: "attachments", into: &fields)
        }
    }

    static func currentReferences(_ field: ItemValue?) -> [ItemReference]? {
        guard let values = field?.array, !values.isEmpty else { return nil }
        let references = values.compactMap(\.link)
        guard references.count == values.count, references.allSatisfy({ $0.revisionID == nil }) else {
            return nil
        }
        return references
    }
}
