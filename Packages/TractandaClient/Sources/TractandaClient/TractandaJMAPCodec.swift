import Foundation

/// Strict, declared-schema wire adapters. Canonical ItemValue Codable and arbitrary JSON are untouched.
public enum TractandaJMAPCodec {
    private static func argumentPaths(_ method: String) -> [[String]] {
        switch method {
        case "TractandaItem/commit", "TractandaItem/resolveConflict", "TractandaSync/acceptReview":
            return [["changes", "*"]]
        case "TractandaItem/prepareCapture": return [["request", "changes", "*"]]
        case "TractandaItem/commitCapture":
            return [["request", "changes", "*"], ["commitRequest", "changes", "*"]]
        case "TractandaItem/setSharing": return [["permissions"]]
        case "TractandaLearning/settings": return [["settings"]]
        case "TractandaStore/configureAccess": return [["configuration"]]
        case "TractandaCategory/installTemplate": return [["template", "entries", "*", "fields", "*"]]
        case "TractandaPeerPersonal/admin": return [["fields", "*"]]
        default: return []
        }
    }
    private static func resultPaths(_ method: String) -> [[String]] {
        switch method {
        case "TractandaItem/prepareCapture":
            return [["request", "changes", "*"], ["commitRequest", "changes", "*"]]
        case "TractandaItem/sharing", "TractandaItem/setSharing": return [["permissions"]]
        case "TractandaItem/resolve": return [["value"]]
        default: return []
        }
    }
    private static func transform(
        _ value: JMAPValue, path: ArraySlice<String>, leaf: (JMAPValue) throws -> JMAPValue
    ) throws -> JMAPValue {
        guard let token = path.first else { return value == .null ? value : try leaf(value) }
        if token == "*" {
            if let values = value.elements {
                return .array(try values.map { try transform($0, path: path.dropFirst(), leaf: leaf) })
            }
            if let members = value.members {
                return .object(
                    try members.map {
                        .init($0.name, try transform($0.value, path: path.dropFirst(), leaf: leaf))
                    })
            }
            throw TractandaError("invalidArguments", "Declared codec collection must be an object or array.")
        }
        guard let members = value.members else {
            throw TractandaError("invalidArguments", "Declared codec parent must be an object.")
        }
        return .object(
            try members.map { member in
                member.name.utf8.elementsEqual(token.utf8)
                    ? .init(member.name, try transform(member.value, path: path.dropFirst(), leaf: leaf))
                    : member
            })
    }
    private static func checkDictionaryNames(_ value: JMAPValue) throws {
        if let members = value.members {
            var names: Set<String> = []
            for member in members {
                guard names.insert(member.name).inserted else {
                    throw TractandaError(
                        "invalidArguments", "Domain dictionary cannot distinguish these keys.")
                }
                try checkDictionaryNames(member.value)
            }
        } else if let values = value.elements {
            for value in values { try checkDictionaryNames(value) }
        }
    }
    private static func codec(_ value: JMAPValue, paths: [[String]], fromWire: Bool) throws -> JMAPValue {
        var result = value
        for path in paths {
            result = try transform(result, path: path[...]) { item in
                try checkDictionaryNames(item)
                if fromWire {
                    let domain = try JSON.decode(JMAPItemValue.self, item.encoded()).value
                    return try .decode(JSON.encode(domain))
                }
                let domain = try JSON.decode(ItemValue.self, item.encoded())
                return try .decode(JSON.encode(JMAPItemValue(domain)))
            }
        }
        return result
    }
    public static func argumentsToWire(method: String, arguments: JMAPValue) throws -> JMAPValue {
        try codec(arguments, paths: argumentPaths(method), fromWire: false)
    }
    public static func argumentsFromWire(
        method: String, arguments: JMAPValue, createdIDs: [String: String] = [:]
    ) throws -> JMAPValue {
        guard TractandaJMAP.scope(of: method) == .account else { return arguments }
        do {
            let resolved = try resolveCreationIDs(
                method: method, arguments: arguments, createdIDs: createdIDs)
            return try codec(resolved, paths: argumentPaths(method), fromWire: true)
        } catch {
            throw TractandaError("invalidArguments", "Invalid declared method value: \(error)")
        }
    }
    /// Standard read DTO wrappers encode themselves; they deliberately have no result-path adapter here.
    public static func extensionResultToWire(method: String, result: JMAPValue) throws -> JMAPValue {
        try codec(result, paths: resultPaths(method), fromWire: false)
    }
    public static func extensionResultFromWire(method: String, result: JMAPValue) throws -> JMAPValue {
        try codec(result, paths: resultPaths(method), fromWire: true)
    }
    private static func resolveCreationIDs(method: String, arguments: JMAPValue, createdIDs: [String: String])
        throws -> JMAPValue
    {
        guard
            [
                "TractandaItem/commit", "TractandaItem/prepareCapture", "TractandaItem/commitCapture",
                "TractandaItem/resolveConflict", "TractandaSync/acceptReview", "TractandaItem/setSharing",
                "TractandaLearning/settings", "TractandaLearning/feedback",
                "TractandaCategory/installTemplate",
            ].contains(method)
        else { return arguments }
        var paths: [[String]]
        switch method {
        case "TractandaItem/get", "TractandaItem/getBounded", "TractandaRevision/get", "TractandaItem/query":
            return arguments
        default:
            paths = [
                ["itemID"], ["revisionID"], ["expectedRevisionID"], ["categoryID"],
                ["reviewedFrontier", "*"],
            ]
        }
        if method == "TractandaItem/prepareCapture" || method == "TractandaItem/commitCapture" {
            paths = ["request", "commitRequest"].flatMap { prefix in
                [[prefix, "itemID"], [prefix, "expectedRevisionID"]]
            }
        }
        var result = arguments
        func replace(_ value: JMAPValue) throws -> JMAPValue {
            guard let text = value.text, text.hasPrefix("#") else { return value }
            guard let id = createdIDs[String(text.dropFirst())] else {
                throw TractandaError("invalidArguments", "Unknown creation ID.")
            }
            return .string(id)
        }
        for path in paths { result = try transform(result, path: path[...], leaf: replace) }
        // References are resolved ONLY inside schema-declared tagged ItemValues, never arbitrary JSON.
        func references(_ value: JMAPValue) throws -> JMAPValue {
            guard let type = value["type"]?.text else { return value }
            if type == "reference" {
                var reference = value
                for path in [["value", "itemID"], ["value", "revisionID"]] {
                    reference = try transform(reference, path: path[...], leaf: replace)
                }
                return reference
            }
            if type == "list" || type == "object" {
                return try transform(value, path: ["value", "*"][...], leaf: references)
            }
            return value
        }
        for path in argumentPaths(method) {
            result = try transform(result, path: path[...], leaf: references)
        }
        return result
    }
}
