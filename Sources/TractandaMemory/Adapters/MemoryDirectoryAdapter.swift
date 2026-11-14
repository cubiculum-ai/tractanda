import Foundation
import TractandaCore
import Yams

/// Imports only the directory explicitly selected by the caller. Never locates native memory stores.
public enum MemoryDirectoryAdapter {
    public static func preview(
        source: URL, namespace: String, origin: String = "directory", limits: ImportLimits = ImportLimits()
    ) throws -> ImportPlan {
        guard ["directory", "codex", "claude"].contains(origin) else {
            throw TractandaError("importAdapter", "Unsupported selected-note origin.")
        }
        return try DirectoryMemoryPreview.build(
            source: source, namespace: namespace, limits: limits, okf: false, origin: origin)
    }
}

/// Pinned OKF v0.2 semantics, with inert provenance and explicit parser limitations.
public enum OKFMemoryAdapter {
    public static let specification = "6a2845dd6ce30c3a866a5d55ef8221964fd96372"

    public static func preview(source: URL, namespace: String, limits: ImportLimits = ImportLimits()) throws
        -> ImportPlan
    {
        try DirectoryMemoryPreview.build(
            source: source, namespace: namespace, limits: limits, okf: true, origin: "okf")
    }
}

private enum DirectoryMemoryPreview {
    static func build(source: URL, namespace: String, limits: ImportLimits, okf: Bool, origin: String) throws
        -> ImportPlan
    {
        let files = try ImportSourceFiles(root: source, limits: limits)
        let paths = try files.list()
        let knownPaths = Set(paths)
        var records: [ImportRecord] = []
        for path in paths {
            try Task.checkCancellation()
            let markdown = path.hasSuffix(".md") || (!okf && path.hasSuffix(".markdown"))
            let text = markdown || (!okf && path.hasSuffix(".txt"))
            let original = try files.original(
                relativePath: path,
                mediaType: markdown ? "text/markdown" : text ? "text/plain" : "application/octet-stream")
            let sourceID = okf && path.hasSuffix(".md") ? String(path.dropLast(3)) : path
            var record = ImportRecord(
                sourceID: sourceID, original: original,
                projection: ["subject": .text(original.filename)],
                metadata: [
                    "sourcePath": .text(path), "sourceRole": .text(text ? "note" : "asset"),
                    "selectedOrigin": .text(origin), "claimsAuthenticated": .boolean(false),
                    "instructionsActive": .boolean(false),
                ])
            guard text else {
                record.diagnostics.append(
                    .init(
                        "assetOriginalOnly",
                        "Binary or unsupported-format asset is retained as an original; native text semantics are unavailable.",
                        severity: .unsupported, sourceID: sourceID))
                records.append(record)
                continue
            }
            let data = try files.read(relativePath: path, maximumBytes: limits.maximumProjectionBytes)
            guard ImportHash.bytes(data) == original.sha256, Int64(data.count) == original.byteCount else {
                throw TractandaError("importSourceChanged", "Selected source changed during preview: \(path)")
            }
            guard let content = String(data: data, encoding: .utf8) else {
                throw TractandaError("importUTF8", "Selected text source is not UTF-8: \(path)")
            }
            let auxiliary = okf && ["index.md", "log.md"].contains(original.filename)
            var body = content
            var bodyLineOffset = 0
            var sourceIDs: Set<String> = []
            if okf && markdown {
                record.metadata["okfSpecification"] = .text(OKFMemoryAdapter.specification)
                if auxiliary {
                    record.metadata["sourceRole"] = .text(original.filename == "index.md" ? "index" : "log")
                }
                let frontmatter = try splitFrontmatter(content, required: !auxiliary)
                body = frontmatter.body
                bodyLineOffset = frontmatter.lineOffset
                if let yaml = frontmatter.yaml {
                    let root = try BoundedYAML.parse(yaml)
                    guard case .mapping = root else {
                        throw TractandaError("importOKF", "OKF frontmatter must be a mapping: \(path)")
                    }
                    let value = BoundedYAML.value(root, diagnostics: &record.diagnostics)
                    record.metadata["yaml"] = value
                    record.metadata["rawFrontmatter"] = .text(yaml)
                    try projectOKF(root, record: &record, requiredType: !auxiliary)
                    let ids = root["sources"]?.array().compactMap { plainString($0["id"]) } ?? []
                    let counts = Dictionary(grouping: ids, by: { $0 }).mapValues(\.count)
                    sourceIDs = Set(ids.filter { counts[$0] == 1 })
                    if counts.values.contains(where: { $0 > 1 }) {
                        record.diagnostics.append(
                            .init(
                                "okfDuplicateSourceIDs",
                                "Duplicate provenance source IDs are retained but their claim joins remain unresolved."
                            ))
                    }
                }
            }
            record.projection["body"] = .text(body)
            if markdown {
                let parsed = try MemoryMarkdown(
                    body: body, relativePath: path, okf: okf, knownPaths: knownPaths, sourceIDs: sourceIDs,
                    maximumLinks: limits.maximumLinksPerRecord, lineOffset: bodyLineOffset)
                if record.projection["subject"] == .text(original.filename), let title = parsed.title {
                    record.projection["subject"] = .text(title)
                }
                record.links = parsed.links
                record.metadata["markdownLinks"] = .list(parsed.linkEvidence)
                record.metadata["sourceMentions"] = .list(parsed.sourceMentions)
                if !parsed.sourceMentions.isEmpty {
                    record.diagnostics.append(
                        .init(
                            "footnoteDialectPartial",
                            "Source-ID markers in Markdown text are joined to declared sources. General footnote rendering and dialect-specific placement semantics are unsupported.",
                            severity: .unsupported, sourceID: sourceID))
                }
                for link in record.links where link.kind != .local {
                    record.diagnostics.append(
                        .init(
                            "link" + link.kind.rawValue.capitalized,
                            "Outgoing target retained with \(link.kind.rawValue) resolution: \(link.originalTarget)",
                            severity: link.kind == .external ? .information : .warning, sourceID: sourceID))
                }
            }
            record.diagnostics = record.diagnostics.map { diagnostic in
                var diagnostic = diagnostic
                diagnostic.sourceID = sourceID
                return diagnostic
            }
            records.append(record)
        }
        let plan = ImportPlan(
            namespace: namespace, adapter: okf ? "okf-v0.2-mapping-v1" : "selected-\(origin)-notes-v1",
            sourceRoot: source.path, records: records, limits: limits)
        try plan.validate()
        return plan
    }

    private static func splitFrontmatter(_ content: String, required: Bool) throws -> (
        yaml: String?, body: String, lineOffset: Int
    ) {
        // Delimiters are whole lines, not a YAML parser replacement. Both LF and CRLF survive
        // in body/original bytes; only the frontmatter envelope is removed from body projection.
        // CRLF is one Swift Character, so splitting Character("\n") does not split CRLF.
        // Split the UTF-8 LF byte and retain each CR for the source-preserving body projection.
        let lines = content.utf8.split(separator: 10, omittingEmptySubsequences: false).map {
            String(decoding: $0, as: UTF8.self)
        }
        func delimiter(_ line: String) -> String { line.hasSuffix("\r") ? String(line.dropLast()) : line }
        let firstLine = lines.first.map(delimiter).map { line in
            line.hasPrefix("\u{FEFF}") ? String(line.dropFirst()) : line
        }
        guard firstLine == "---" else {
            if required { throw TractandaError("importOKF", "OKF concept is missing YAML frontmatter.") }
            return (nil, content, 0)
        }
        guard
            let end = lines.indices.dropFirst().first(where: {
                delimiter(lines[$0]) == "---" || delimiter(lines[$0]) == "..."
            })
        else {
            throw TractandaError("importOKF", "Unterminated OKF frontmatter.")
        }
        let yaml = lines[1..<end].joined(separator: "\n")
        let body = lines.dropFirst(end + 1).joined(separator: "\n")
        return (yaml, body, end + 1)
    }

    private static func projectOKF(_ root: Node, record: inout ImportRecord, requiredType: Bool) throws {
        let type = plainString(root["type"])
        if requiredType && (type?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            throw TractandaError(
                "importOKF", "OKF concept must declare a non-empty type: \(record.original.relativePath)")
        }
        if let type { record.projection["okfType"] = .text(type) }
        for (source, destination) in [
            ("title", "subject"), ("description", "okfDescription"), ("resource", "okfResource"),
        ] {
            if let node = root[source] {
                if let text = plainString(node) {
                    record.projection[destination] = .text(text)
                } else {
                    record.diagnostics.append(
                        .init(
                            "okfFieldCarried",
                            "\(source) has no native text projection; retained in YAML metadata.",
                            severity: .unsupported))
                }
            }
        }
        if let version = root["okf_version"] {
            if case .scalar(let scalar) = version,
                ["tag:yaml.org,2002:str", "tag:yaml.org,2002:int", "tag:yaml.org,2002:float"].contains(
                    version.tag.rawValue)
            {
                record.projection["okfVersion"] = .text(scalar.string)
                if scalar.string != "0.2" && scalar.string != "v0.2" {
                    record.diagnostics.append(
                        .init(
                            "okfVersionUnsupported",
                            "Declared version \(scalar.string) is preserved; this adapter implements the pinned v0.2 mapping only.",
                            severity: .unsupported))
                }
            } else {
                record.diagnostics.append(
                    .init(
                        "okfFieldCarried",
                        "okf_version has no supported scalar projection; retained in YAML metadata.",
                        severity: .unsupported))
            }
        }
        if root["status"] == nil {
            record.projection["okfStatus"] = .text("stable")
        } else if let status = plainString(root["status"]) {
            record.projection["okfStatus"] = .text(status)
        } else {
            record.diagnostics.append(
                .init(
                    "okfStatusCarried",
                    "Non-text status is retained without an effective lifecycle projection.",
                    severity: .unsupported))
        }
        record.metadata["statusDefaulted"] = .boolean(root["status"] == nil)
        if let tags = root["tags"] {
            record.projection["okfTags"] = BoundedYAML.value(tags, diagnostics: &record.diagnostics)
            record.metadata["categoryProposals"] = .list(
                tags.array().compactMap { plainString($0) }.map(ItemValue.text))
        }
        if let stale = root["stale_after"] {
            projectDate(stale, field: "stale_after", destination: "okfStaleAfter", record: &record)
        }
        if let generated = root["generated"] {
            record.projection["okfGeneratedClaim"] = BoundedYAML.value(
                generated, diagnostics: &record.diagnostics)
            if let at = generated["at"] {
                projectDate(at, field: "generated.at", destination: "originalModifiedAt", record: &record)
            }
        }
        if let verified = root["verified"] {
            let events: [Node]
            if case .mapping = verified { events = [verified] } else { events = verified.array() }
            record.projection["okfVerifiedClaims"] = .list(
                events.map { BoundedYAML.value($0, diagnostics: &record.diagnostics) })
            if events.isEmpty {
                record.diagnostics.append(
                    .init(
                        "okfVerificationShape",
                        "Verification claims are retained in YAML but have no supported event shape.",
                        severity: .unsupported))
            }
        }
        if let sources = root["sources"] {
            record.projection["okfSources"] = BoundedYAML.value(sources, diagnostics: &record.diagnostics)
        }
        if let window = root["usage_window"] {
            record.projection["okfUsageWindow"] = BoundedYAML.value(window, diagnostics: &record.diagnostics)
        }
        if root["citations"] != nil {
            record.diagnostics.append(
                .init(
                    "okfLegacyCitationsCarried",
                    "Legacy citations are retained in YAML metadata; v0.1 citation-list interpretation is unsupported.",
                    severity: .unsupported))
        }
        // Typed nested date claims live beside the lexical YAML projection. Invalid values
        // remain text, never native dates and never authenticated creation/modification times.
        var dates: [String: ItemValue] = [:]
        func date(_ value: Node?, _ path: String) {
            guard let value else { return }
            if let raw = value.string, validDate(raw) {
                dates[path] = .date(raw)
            } else {
                record.diagnostics.append(
                    .init(
                        "okfInvalidTimestamp",
                        "\(path) is retained without a typed date: an explicit valid UTC offset datetime is required."
                    ))
            }
        }
        func window(_ node: Node?, _ path: String) {
            date(node?["from"], path + ".from")
            date(node?["to"], path + ".to")
        }
        date(root["stale_after"], "stale_after")
        date(root["generated"]?["at"], "generated.at")
        window(root["usage_window"], "usage_window")
        let verification =
            root["verified"].map { node -> [Node] in
                if case .mapping = node { return [node] }
                return node.array()
            } ?? []
        for (index, event) in verification.enumerated() { date(event["at"], "verified[\(index)].at") }
        for (index, source) in (root["sources"]?.array() ?? []).enumerated() {
            date(source["last_modified"], "sources[\(index)].last_modified")
            window(source["usage_window"], "sources[\(index)].usage_window")
        }
        record.metadata["dateClaims"] = .object(dates)
        let computation = ["runtime", "parameters", "computation", "executor", "attester"].filter {
            root[$0] != nil
        }
        if !computation.isEmpty {
            record.projection["okfExecutionSupported"] = .boolean(false)
            record.projection["okfExecuted"] = .boolean(false)
            record.projection["okfAttestation"] = .text("absent")
            record.diagnostics.append(
                .init(
                    "okfExecutionUnsupported",
                    "Computation/runtime/executor/attester declarations are inert, unexecuted and unattested.",
                    severity: .unsupported))
        }
        let understood: Set<String> = [
            "type", "title", "description", "resource", "tags", "okf_version", "status", "stale_after",
            "generated", "verified", "sources", "usage_window", "runtime", "parameters", "computation",
            "executor", "attester", "citations",
        ]
        if case .mapping(let mapping) = root {
            for (key, _) in mapping where key.string.map({ !understood.contains($0) }) ?? true {
                record.diagnostics.append(
                    .init(
                        "okfExtensionCarried",
                        "Unknown OKF key \(key.string ?? "<complex key>") is retained in YAML metadata; no native behavior is assigned.",
                        severity: .unsupported))
            }
        }
    }

    private static func projectDate(
        _ node: Node, field: String, destination: String, record: inout ImportRecord
    ) {
        if let raw = node.string, validDate(raw) {
            record.projection[destination] = .date(raw)
        } else {
            record.diagnostics.append(
                .init(
                    "okfInvalidTimestamp",
                    "\(field) lacks a valid offset-qualified datetime and is retained without a native date projection."
                ))
        }
    }

    private static func plainString(_ node: Node?) -> String? {
        guard let node, node.tag.rawValue == "tag:yaml.org,2002:str", case .scalar(let scalar) = node else {
            return nil
        }
        return scalar.string
    }

    private static func validDate(_ text: String) -> Bool {
        guard
            text.range(
                of:
                    #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})$"#,
                options: .regularExpression) != nil,
            Timestamp.parse(text) != nil
        else { return false }
        let parts = text.prefix(19).split(whereSeparator: { "-T:".contains($0) }).compactMap { Int($0) }
        guard parts.count == 6, parts[0] > 0, (1...12).contains(parts[1]),
            (0...23).contains(parts[3]), (0...59).contains(parts[4]), (0...59).contains(parts[5])
        else { return false }
        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(secondsFromGMT: 0) else { return false }
        calendar.timeZone = utc
        guard let month = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: 1)),
            let days = calendar.range(of: .day, in: .month, for: month), days.contains(parts[2])
        else { return false }
        if !text.hasSuffix("Z") {
            let zone = text.suffix(5).split(separator: ":").compactMap { Int($0) }
            guard zone.count == 2, (0...23).contains(zone[0]), (0...59).contains(zone[1]) else {
                return false
            }
        }
        return true
    }
}
