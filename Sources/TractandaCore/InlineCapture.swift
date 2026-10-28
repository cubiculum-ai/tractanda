import Foundation
import TractandaClient

public typealias CapturePreparation = TractandaClient.CapturePreparation
public typealias CaptureMention = TractandaClient.CaptureMention
public typealias CaptureIssue = TractandaClient.CaptureIssue
public typealias CapturePlan = TractandaClient.CapturePlan

/// Category-owned date interpretation. No name has built-in temporal meaning.
struct CategoryCaptureDate {
    let property: String
    let dayOffset: Int
    let calendar: Calendar

    init(_ value: ItemValue) throws {
        let reserved: Set<String> = [
            "itemID", "revisionID", "classID", "schemaVersion", "createdAt", "modifiedAt",
            "supersedes", "actor", "operationID", "requestIdentity", "revisionAncestry", "permissions",
            "body", "subject", "selection", "categoryParents", "categoryOrder", "categoryOverrides",
            "personalOverrides", "target", "accessConfiguration", "templateKey", "viewDefinition",
            "captureDate", "captureAliases", "inlineCaptureBindings", "attachments",
            "attachmentText", "attachmentDocument", "isDeleted",
        ]
        guard let map = value.map, let property = map["property"]?.string,
            !property.isEmpty, property.utf8.count <= 200, !property.contains("\0"),
            !reserved.contains(property), let offset = map["dayOffset"]?.integerValue,
            !["category", "personal", "capture", "inlineCapture"].contains(where: property.hasPrefix),
            (-1200...1200).contains(offset), let zone = map["timeZone"]?.string
        else {
            throw TractandaError(
                "invalidCapture", "captureDate needs an ordinary date property, dayOffset and named timeZone."
            )
        }
        self.property = property
        dayOffset = Int(offset)
        calendar = try QueryCalendar.make(timeZone: zone)
    }

    func date(at anchor: Date) throws -> String {
        guard let shifted = calendar.date(byAdding: .day, value: dayOffset, to: anchor) else {
            throw TractandaError("invalidCapture", "Cannot resolve the configured calendar day.")
        }
        let parts = calendar.dateComponents([.year, .month, .day], from: shifted)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}

enum InlineCapture {
    static let maximumMentions = 128
    static let maximumPlanBytes = 512 * 1024 - 4096
    static let maximumRequestBytes = 256 * 1024
    static let maximumCandidates = 16
    static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased()
    }

    static func validate(_ fields: [String: ItemValue]) throws {
        if let value = fields["captureDate"] { _ = try CategoryCaptureDate(value) }
        if let value = fields["captureAliases"] {
            guard let aliases = value.array, aliases.count <= 32,
                aliases.allSatisfy({ alias in
                    guard let text = alias.string else { return false }
                    return !text.isEmpty && text.utf8.count <= 256 && !text.contains("\0")
                        && !text.contains(where: { "#/[]\\\n\r".contains($0) })
                })
            else {
                throw TractandaError("invalidCapture", "captureAliases is a list of at most 32 plain names.")
            }
        }
        if let value = fields["inlineCaptureBindings"] {
            guard let bindings = value.map, bindings.count <= maximumMentions else {
                throw TractandaError("invalidCapture", "Capture bindings exceed the authoring limit.")
            }
            for (token, value) in bindings {
                guard token.utf8.count <= 512, let binding = value.map,
                    let ref = binding["category"]?.link, ref.revisionID == nil,
                    let at = binding["capturedAt"]?.dateString, Timestamp.parse(at) != nil,
                    (binding["dateProperty"] == nil && binding["dateValue"] == nil)
                        || (binding["dateProperty"]?.string != nil && binding["dateValue"]?.string != nil)
                else { throw TractandaError("invalidCapture", "Invalid capture binding provenance.") }
                try Identifier.validate(ref.itemID)
            }
        }
    }

    struct Token {
        let text: String
        let name: String
        var key: String { normalize(text) }
    }

    /// Conservatively skips escaped mentions, fenced/inline code, URL fragments and word interiors.
    static func tokens(in body: String) throws -> [Token] {
        guard body.utf8.count <= 64 * 1024 else {
            throw TractandaError("captureLimit", "Inline authoring supports bodies up to 64 KiB.")
        }
        let chars = Array(body)
        var result: [Token] = []
        var seen: Set<String> = []
        var i = 0
        var codeMarker: Character?
        var codeLength = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "\\" {
                i += min(2, chars.count - i)
                continue
            }
            if codeMarker == nil, ch == "(", i > 0, chars[i - 1] == "]" {
                // Markdown link destinations, including local #fragment URLs, are literal.
                var depth = 1
                i += 1
                while i < chars.count && depth > 0 {
                    if chars[i] == "\\" {
                        i += min(2, chars.count - i)
                        continue
                    }
                    if chars[i] == "(" { depth += 1 }
                    if chars[i] == ")" { depth -= 1 }
                    i += 1
                }
                continue
            }
            if ch == "`" || ch == "~" {
                var end = i + 1
                while end < chars.count && chars[end] == ch { end += 1 }
                let count = end - i
                if codeMarker == nil && (ch == "`" || count >= 3) {
                    codeMarker = ch
                    codeLength = count
                } else if codeMarker == ch && count == codeLength {
                    codeMarker = nil
                }
                i = end
                continue
            }
            guard codeMarker == nil, ch == "#",
                i == 0 || chars[i - 1].isWhitespace || "({[,;:!?\"'".contains(chars[i - 1])
            else {
                i += 1
                continue
            }
            let start = i
            var end = i + 1
            var name = ""
            if end < chars.count, chars[end] == "[" {
                end += 1
                while end < chars.count && chars[end] != "]" && !chars[end].isNewline {
                    name.append(chars[end])
                    end += 1
                }
                guard end < chars.count, chars[end] == "]", !name.isEmpty else {
                    i += 1
                    continue
                }
                end += 1
            } else {
                while end < chars.count
                    && (chars[end].isLetter || chars[end].isNumber || "_-".contains(chars[end]))
                {
                    name.append(chars[end])
                    end += 1
                }
                guard !name.isEmpty else {
                    i += 1
                    continue
                }
            }
            let token = Token(text: String(chars[start..<end]), name: name)
            guard token.text.utf8.count <= 512 else {
                throw TractandaError("captureLimit", "Hashtag names must be at most 512 bytes.")
            }
            if seen.insert(token.key).inserted { result.append(token) }
            guard result.count <= maximumMentions else {
                throw TractandaError("captureLimit", "Use at most 128 distinct hashtags.")
            }
            i = end
        }
        return result
    }

    static func prepare(
        _ request: CommitRequest, base: Revision?, categories: [Revision], at: String,
        isExcluded: (String) throws -> Bool, pathEvaluation: (() -> Void)? = nil
    ) throws -> CapturePlan {
        guard try JSON.encode(request).count <= maximumRequestBytes else {
            throw TractandaError(
                "captureLimit", "Capture requests must fit 256 KiB; no fields are truncated.")
        }
        guard request.action == .create || request.action == .revise || request.action == .retype,
            request.changes["inlineCaptureBindings"] == nil,
            !request.unset.contains("inlineCaptureBindings"), let anchor = Timestamp.parse(at)
        else {
            throw TractandaError(
                "invalidCapture", "Capture supports create/revise/retype; edit provenance separately.")
        }
        var fields = base?.fields ?? [:]
        for key in request.unset { fields.removeValue(forKey: key) }
        fields.merge(request.changes) { _, new in new }
        let body = fields["body"]?.string ?? ""
        let tokens = try tokens(in: body)
        var bindings = base?.fields["inlineCaptureBindings"]?.map ?? [:]
        let previousTokens =
            bindings.isEmpty
            ? Set<String>()
            : Set(try Self.tokens(in: base?.fields["body"]?.string ?? "").map(\.key))
        var overrides = fields["categoryOverrides"]?.map ?? [:]
        let byID = Dictionary(uniqueKeysWithValues: categories.map { ($0.itemID, $0) })
        var commit = request
        var mentions: [CaptureMention] = []
        var issues: [CaptureIssue] = []
        var guards: [String: String] = [:]
        func issue(_ token: Token, _ code: String, _ message: String) {
            issues.append(CaptureIssue(token: token.text, code: code, message: message))
        }
        func named(_ category: Revision, _ name: String) -> Bool {
            let names =
                [category.fields["subject"]?.string ?? ""]
                + (category.fields["captureAliases"]?.array ?? []).compactMap(\.string)
            return names.contains { normalize($0) == normalize(name) }
        }
        var pathMatches: [String: Bool] = [:]
        func matches(_ category: Revision, _ path: ArraySlice<String>) -> Bool {
            let key = "\(category.itemID):\(path.count)"
            if let known = pathMatches[key] { return known }
            pathEvaluation?()
            guard let last = path.last, named(category, last) else {
                pathMatches[key] = false
                return false
            }
            if path.count == 1 {
                pathMatches[key] = true
                return true
            }
            let result = (category.fields["categoryParents"]?.array ?? []).contains { value in
                guard let id = value.link?.itemID, let parent = byID[id] else { return false }
                return matches(parent, path.dropLast())
            }
            pathMatches[key] = result
            return result
        }
        for token in tokens {
            let reused = previousTokens.contains(token.key) ? bindings[token.key]?.map : nil
            let candidates: [String]
            if let id = reused?["category"]?.link?.itemID {
                candidates = byID[id] == nil ? [] : [id]
                if candidates.isEmpty {
                    mentions.append(CaptureMention(token: token.text, categoryID: nil, reusedBinding: true))
                    issue(
                        token, "unavailable",
                        "The bound category is no longer readable or enabled; escape or replace this mention."
                    )
                    continue
                }
            } else {
                pathMatches.removeAll(keepingCapacity: true)
                let path = token.name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                guard path.count <= 32, !path.contains("") else {
                    issue(token, "unknown", "Use a category name, stable ID, or consecutive category path.")
                    continue
                }
                if let direct = byID[normalize(token.name)] {
                    candidates = [direct.itemID]
                } else {
                    candidates = categories.filter { matches($0, path[...]) }.map(\.itemID).sorted()
                }
            }
            guard candidates.count == 1, let category = byID[candidates[0]] else {
                mentions.append(
                    CaptureMention(
                        token: token.text, categoryID: nil,
                        candidates: Array(candidates.prefix(maximumCandidates))))
                issue(
                    token, candidates.isEmpty ? "unknown" : "ambiguous",
                    candidates.isEmpty
                        ? "No readable category matches; escape literal hashtags."
                        : "Several readable categories match; use #[Parent/Child] or #[categoryID].")
                continue
            }
            guards[category.itemID] = category.revisionID
            if let reused {
                mentions.append(
                    CaptureMention(
                        token: token.text, categoryID: category.itemID,
                        reusedBinding: true, dateProperty: reused["dateProperty"]?.string,
                        dateValue: reused["dateValue"]?.string))
                continue
            }
            var binding: [String: ItemValue] = [
                "category": .reference(ItemReference(category.itemID)), "capturedAt": .date(at),
            ]
            let dateConfig = try category.fields["captureDate"].map(CategoryCaptureDate.init)
            let dateValue = try dateConfig.map { try $0.date(at: anchor) }
            mentions.append(
                CaptureMention(
                    token: token.text, categoryID: category.itemID,
                    dateProperty: dateConfig?.property, dateValue: dateValue))
            if try overrides[category.itemID]?.string == "exclude" || isExcluded(category.itemID) {
                issue(
                    token, "excluded",
                    "An explicit shared or personal exclusion is authoritative; review it separately.")
                continue
            }
            if let dateConfig, let dateValue {
                if overrides[category.itemID]?.string == "include",
                    base?.fields["categoryOverrides"]?.map?[category.itemID]?.string != "include"
                {
                    issue(
                        token, "dateOverrideConflict",
                        "This date category also has a new manual include; remove that pin to use its ordinary date rule."
                    )
                    continue
                }
                let property = dateConfig.property
                let proposed = ItemValue.text(dateValue)
                if request.unset.contains(property)
                    || (fields[property] != nil && fields[property] != proposed)
                {
                    issue(
                        token, "dateConflict",
                        "The configured date conflicts with existing or explicit \(property); reconcile it before capture."
                    )
                    continue
                }
                if fields[property] == nil {
                    commit.changes[property] = proposed
                    fields[property] = proposed
                }
                binding["dateProperty"] = .text(property)
                binding["dateValue"] = proposed
            } else if overrides[category.itemID] == nil {
                if request.unset.contains("categoryOverrides") {
                    issue(
                        token, "overrideConflict",
                        "The edit explicitly removes categoryOverrides; reconcile the requested assignment before capture."
                    )
                    continue
                }
                overrides[category.itemID] = .text("include")
                commit.changes["categoryOverrides"] = .object(overrides)
            }
            bindings[token.key] = .object(binding)
        }
        if bindings != (base?.fields["inlineCaptureBindings"]?.map ?? [:]) {
            commit.changes["inlineCaptureBindings"] = .object(bindings)
        }
        guard bindings.count <= maximumMentions else {
            throw TractandaError(
                "captureLimit",
                "Capture provenance exceeds 128 bindings; reset it explicitly before further capture.")
        }
        let plan = CapturePlan(
            request: request, evaluatedAt: at, commitRequest: commit,
            categoryRevisionIDs: guards, mentions: mentions, issues: issues)
        guard try JSON.encode(plan).count <= maximumPlanBytes else {
            throw TractandaError(
                "captureLimit", "Capture plan must fit the 512 KiB transport budget; no fields are truncated."
            )
        }
        return plan
    }
}

extension ItemClient {
    public func prepareCapture(_ preparation: CapturePreparation) throws -> CapturePlan {
        let args = try JSONSerialization.jsonObject(with: JSON.encode(preparation)) as! [String: Any]
        return try JSON.decode(CapturePlan.self, call("TractandaItem/prepareCapture", arguments: args))
    }
    public func commitCapture(_ plan: CapturePlan) throws -> MutationReceipt {
        let args = try JSONSerialization.jsonObject(with: JSON.encode(plan)) as! [String: Any]
        let receipt = try JSON.decode(MutationReceipt.self, call("TractandaItem/commitCapture", arguments: args))
        guard receipt.operationID == plan.commitRequest.operationID,
            plan.commitRequest.action == .create || plan.commitRequest.action == .copy
                || receipt.itemID == plan.commitRequest.itemID
        else { throw TractandaError("protocolError", "Capture receipt does not match its intent.") }
        return receipt
    }
}
