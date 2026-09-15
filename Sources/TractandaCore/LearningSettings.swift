import Foundation
import TractandaLearning

/// Stored on the category item. Scores are cosine margins, not probabilities.
public struct CategoryLearningSettings: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case off, suggestions }
    public static let profile = "tractanda.category-learning.v1"
    public var mode: Mode = .suggestions
    public var threshold: Double = 0.1
    public var minimumExamplesPerLabel: Int = 2
    public var maximumExamplesPerLabel: Int = 256
    public var usesRuleMatches: Bool = false
    public var configuration = LSMConfiguration()

    public init() {}

    /// Canonical fields are tagged like other item properties; absent keys use these versioned defaults.
    public init(_ value: ItemValue?) throws {
        self.init()
        guard let value else { return }
        guard let map = value.map,
            Set(map.keys).isSubset(of: [
                "profile", "mode", "threshold", "minimumExamplesPerLabel",
                "maximumExamplesPerLabel", "usesRuleMatches", "dimensions", "composition",
            ]),
            map["profile"]?.string == Self.profile
        else { throw TractandaError("invalidLearningSettings", "Unknown learning settings or profile.") }
        if let value = map["mode"] {
            guard let text = value.string, let mode = Mode(rawValue: text) else {
                throw TractandaError("invalidLearningSettings", "Mode must be off or suggestions.")
            }
            self.mode = mode
        }
        if let value = map["threshold"] {
            switch value {
            case .real(let number): threshold = number
            case .integer(let number): threshold = Double(number)
            default: throw TractandaError("invalidLearningSettings", "threshold must be a number.")
            }
        }
        func integer(_ key: String, _ fallback: Int) throws -> Int {
            guard let value = map[key] else { return fallback }
            guard case .integer(let number) = value, let result = Int(exactly: number) else {
                throw TractandaError("invalidLearningSettings", "\(key) must be an integer.")
            }
            return result
        }
        minimumExamplesPerLabel = try integer("minimumExamplesPerLabel", minimumExamplesPerLabel)
        maximumExamplesPerLabel = try integer("maximumExamplesPerLabel", maximumExamplesPerLabel)
        configuration.dimensions = try integer("dimensions", configuration.dimensions)
        if let value = map["usesRuleMatches"] {
            guard let flag = value.booleanValue else {
                throw TractandaError("invalidLearningSettings", "usesRuleMatches must be Boolean.")
            }
            usesRuleMatches = flag
        }
        if let value = map["composition"] {
            guard let text = value.string, let composition = LSMConfiguration.Composition(rawValue: text)
            else {
                throw TractandaError("invalidLearningSettings", "Unknown LSM composition recipe.")
            }
            configuration.composition = composition
        }
        try validate()
    }

    public func validate() throws {
        guard threshold.isFinite, (-2...2).contains(threshold),
            (1...400).contains(minimumExamplesPerLabel),
            (minimumExamplesPerLabel...400).contains(maximumExamplesPerLabel)
        else { throw TractandaError("invalidLearningSettings", "Invalid threshold or example limits.") }
        do { try configuration.validate() } catch {
            throw TractandaError("invalidLearningSettings", "Invalid LSM configuration.")
        }
    }

    public var itemValue: ItemValue {
        .object([
            "profile": .text(Self.profile), "mode": .text(mode.rawValue), "threshold": .real(threshold),
            "minimumExamplesPerLabel": .integer(Int64(minimumExamplesPerLabel)),
            "maximumExamplesPerLabel": .integer(Int64(maximumExamplesPerLabel)),
            "usesRuleMatches": .boolean(usesRuleMatches),
            "dimensions": .integer(Int64(configuration.dimensions)),
            "composition": .text(configuration.composition.rawValue),
        ])
    }
}

/// Portable text recipe v1: subject followed by body, Unicode folding and alphanumeric tokens.
/// References and attachment text are not followed implicitly. At most 4,096 tokens are retained.
public enum LearningText {
    public static let profile = "tractanda.learning-text.v1"

    public static func tokens(in item: Revision) -> [String] {
        tokens(in: (item.fields["subject"]?.string ?? "") + "\n" + (item.fields["body"]?.string ?? ""))
    }

    public static func tokens(in text: String) -> [String] {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
        var result: [String] = []
        var token = String.UnicodeScalarView()
        var isOverlong = false
        func appendToken() {
            if !token.isEmpty && !isOverlong {
                let number = token.allSatisfy { CharacterSet.decimalDigits.contains($0) }
                result.append(number ? "__number__" : String(token))
            }
            token.removeAll(keepingCapacity: true)
            isOverlong = false
        }
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if token.count < 64 { token.append(scalar) } else { isOverlong = true }
            } else {
                appendToken()
                if result.count == 4096 { break }
            }
        }
        if result.count < 4096 { appendToken() }
        return result
    }
}

public enum LearningFeedbackAction: String, Codable, Sendable {
    case accept, exclude, negative, dismiss, clear
}

struct LearningFeedback: Equatable {
    let action: LearningFeedbackAction
    let revisionID: String
    let modelID: String?

    init(_ value: ItemValue) throws {
        guard let map = value.map, Set(map.keys).isSubset(of: ["action", "revisionID", "modelID"]),
            let action = map["action"]?.string.flatMap(LearningFeedbackAction.init), action != .clear,
            let revisionID = map["revisionID"]?.string,
            map["modelID"] == nil || map["modelID"]?.string != nil
        else { throw TractandaError("invalidLearningFeedback", "Invalid category feedback record.") }
        try Identifier.validate(revisionID)
        if let id = map["modelID"]?.string { try Identifier.validate(id) }
        self.action = action
        self.revisionID = revisionID
        self.modelID = map["modelID"]?.string
    }
}
