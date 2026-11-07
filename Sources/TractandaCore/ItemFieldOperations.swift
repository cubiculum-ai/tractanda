import Foundation
import TractandaClient

/// Request-only edits. Canonical publication still records a complete snapshot and ordinary
/// top-level applied writes; neither retry receipts nor this plan supply peer merge semantics.
struct ItemFieldOperationPlan {
    static let maximumOperations = 256
    private static let forbiddenFields = RevisionMerge.managedFields.union([
        "classID", "schemaVersion", "attachments", "attachmentText", "attachmentDocument",
    ])
    let byField: [String: [ItemFieldOperation]]
    var fields: Set<String> { Set(byField.keys) }

    init(_ request: CommitRequest) throws {
        let operations = request.fieldOperations ?? []
        guard operations.count <= Self.maximumOperations else {
            throw TractandaError("invalidArguments", "At most 256 field operations are allowed.")
        }
        guard operations.isEmpty || request.action == .revise else {
            throw TractandaError("invalidArguments", "Field operations require the revise action.")
        }
        var grouped: [String: [ItemFieldOperation]] = [:]
        var keyed: [String: Set<String>] = [:]
        for operation in operations {
            guard !operation.field.isEmpty, !operation.field.contains("\0"),
                !Self.forbiddenFields.contains(operation.field)
            else {
                throw TractandaError("invalidArguments", "Invalid or reserved field operation target.")
            }
            switch operation.op {
            case .append:
                guard operation.key == nil, let value = operation.value else {
                    throw TractandaError("invalidArguments", "Append needs a value and no key.")
                }
                try value.validate()
            case .setKey, .removeKey:
                guard let key = operation.key, !key.isEmpty, !key.contains("\0"),
                    (operation.op == .setKey) == (operation.value != nil)
                else {
                    throw TractandaError("invalidArguments", "Invalid object field operation key or value.")
                }
                try operation.value?.validate()
                guard keyed[operation.field, default: []].insert(key).inserted else {
                    throw TractandaError("invalidArguments", "A map key may be addressed only once.")
                }
            }
            if let first = grouped[operation.field]?.first {
                guard (first.op == .append) == (operation.op == .append) else {
                    throw TractandaError("invalidArguments", "Do not mix list and map operations on a field.")
                }
            }
            grouped[operation.field, default: []].append(operation)
        }
        guard Set(grouped.keys).isDisjoint(with: Set(request.changes.keys).union(request.unset)) else {
            throw TractandaError("invalidArguments", "A field cannot have whole-field and partial edits.")
        }
        byField = grouped
    }

    /// Materialize each addressed collection once. This avoids copying a large list/map once
    /// per operation, while preserving list order and equal-valued independent additions.
    func apply(to fields: inout [String: ItemValue]) throws -> Set<String> {
        var addressed: Set<String> = []
        for (field, operations) in byField {
            if operations[0].op == .append {
                guard fields[field] == nil || fields[field]?.array != nil else {
                    throw TractandaError("invalidArguments", "Append target must be a list or absent.")
                }
                var values = fields[field]?.array ?? []
                for operation in operations { values.append(operation.value!) }
                fields[field] = .list(values)
                addressed.insert(field)
            } else {
                guard fields[field] == nil || fields[field]?.map != nil else {
                    throw TractandaError(
                        "invalidArguments", "Key operation target must be an object or absent.")
                }
                let wasPresent = fields[field] != nil
                var values = fields[field]?.map ?? [:]
                var didSet = false
                for operation in operations {
                    if operation.op == .setKey {
                        values[operation.key!] = operation.value!
                        didSet = true
                    } else {
                        values.removeValue(forKey: operation.key!)
                    }
                }
                // Removing a nonexistent member from an absent object does not author a
                // whole-field unset. A present object still receives its normal field write.
                if wasPresent || didSet {
                    fields[field] = .object(values)
                    addressed.insert(field)
                }
            }
        }
        return addressed
    }
}
