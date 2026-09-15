import Foundation

/// Optional starter data. Names, rules and facets are supplied by the template, never by the engine.
public struct CategoryTemplate: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public let key: String
        public let classID: String
        public let parents: [String]
        public let fields: [String: ItemValue]
        public let viewCategoryKeys: [String]?
        public let excludedCategoryKeys: [String]?
    }
    public let identifier: String
    public let entries: [Entry]

    public func install(in store: ItemStore, timeZone: String, actorUID: UInt32) throws -> [String: String] {
        _ = try QueryCalendar.make(timeZone: timeZone)
        func validateKey(_ key: String) throws {
            guard !key.isEmpty, key.utf8.count <= 100,
                key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) })
            else {
                throw TractandaError(
                    "invalidTemplate",
                    "Template keys use 1–100 ASCII letters, digits, dots, hyphens or underscores.")
            }
        }
        try validateKey(identifier)
        guard !entries.isEmpty, entries.count <= 256 else {
            throw TractandaError("invalidTemplate", "Templates need 1–256 entries in parent-first order.")
        }
        var seen: Set<String> = []
        // Validate the entire specification before the first commit. Individual canonical
        // commits remain independently durable; an interrupted install resumes by template key.
        for entry in entries {
            try validateKey(entry.key)
            guard !seen.contains(entry.key), entry.parents.allSatisfy(seen.contains),
                entry.viewCategoryKeys?.allSatisfy(seen.contains) ?? true,
                entry.excludedCategoryKeys?.allSatisfy(seen.contains) ?? true,
                entry.fields["categoryParents"] == nil, entry.fields["templateKey"] == nil
            else {
                throw TractandaError("invalidTemplate", "Duplicate, forward or reserved template property.")
            }
            var fields = entry.fields
            fields.merge([
                "itemID": .text(Identifier.make()), "revisionID": .text(Identifier.make()),
                "classID": .text(entry.classID), "schemaVersion": .integer(1),
                "createdAt": .date(Timestamp.now()), "modifiedAt": .date(Timestamp.now()),
                "actor": .text("template"), "operationID": .text("template"),
                "requestIdentity": .text("template"),
            ]) { _, new in new }
            try ItemSemantics.validate(Revision(fields: fields))
            seen.insert(entry.key)
        }
        var existing: [String: Revision] = [:]
        for item in try store.candidates(includeDeleted: true) {
            if let key = item.fields["templateKey"]?.string, key.hasPrefix(identifier + "/") {
                guard existing[key] == nil else {
                    throw TractandaError(
                        "invalidTemplate",
                        "Several items claim the same template key; resolve the duplicate first.")
                }
                existing[key] = item
            }
        }
        var installed: [String: Revision] = [:]
        for entry in entries {
            let key = identifier + "/" + entry.key
            if let item = existing[key] {
                installed[entry.key] = item
                continue
            }
            var fields = entry.fields
            fields["templateKey"] = .text(key)
            fields["categoryParents"] = .list(
                entry.parents.compactMap { parent in
                    guard let item = installed[parent], !item.isDeleted, item.fields["selection"] != nil
                    else { return nil }
                    return .reference(ItemReference(item.itemID))
                })
            if var selection = fields["selection"]?.map {
                selection["timeZone"] = .text(timeZone)
                fields["selection"] = .object(selection)
            }
            if let keys = entry.viewCategoryKeys, var view = fields["viewDefinition"]?.map {
                view["categoryPath"] = .list(
                    keys.compactMap { installed[$0].map { .reference(ItemReference($0.itemID)) } })
                fields["viewDefinition"] = .object(view)
            }
            if let keys = entry.excludedCategoryKeys {
                let value = ItemValue.list(
                    keys.compactMap { installed[$0].map { .reference(ItemReference($0.itemID)) } })
                for key in ["selection", "viewDefinition"] {
                    if var definition = fields[key]?.map {
                        definition["excludedCategoryIDs"] = value
                        fields[key] = .object(definition)
                    }
                }
            }
            installed[entry.key] = try store.commit(
                CommitRequest(classID: entry.classID, changes: fields, operationID: Identifier.make()),
                actorUID: actorUID
            ).revision
        }
        return installed.mapValues(\.itemID)
    }
}
