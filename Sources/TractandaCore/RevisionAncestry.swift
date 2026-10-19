import Foundation

/// An applied write is distinct from a carried snapshot value and from retry intent.
enum RevisionFieldWrite: Equatable, Sendable {
    case set(ItemValue)
    case unset
}

/// Pure graph input, not a persisted format or permission to import a revision.
enum RevisionAncestry {
    enum Kind: Equatable, Sendable {
        case authored(writes: [String: RevisionFieldWrite])
        case automaticMerge(profile: String, frontier: [String])
        case resolution(reviewedFrontier: [String], writes: [String: RevisionFieldWrite])

        var writes: [String: RevisionFieldWrite] {
            switch self {
            case .authored(let writes), .resolution(_, let writes): return writes
            case .automaticMerge: return [:]
            }
        }

        var isAutomatic: Bool {
            if case .automaticMerge = self { return true }
            return false
        }
    }
}
