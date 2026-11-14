import Foundation
import Markdown
import TractandaCore

struct MemoryMarkdown {
    var title: String?
    var links: [ImportLink] = []
    var linkEvidence: [ItemValue] = []
    var sourceMentions: [ItemValue] = []

    init(
        body: String, relativePath: String, okf: Bool, knownPaths: Set<String>, sourceIDs: Set<String>,
        maximumLinks: Int, lineOffset: Int = 0
    ) throws {
        let document = Document(parsing: body)
        let sourceLines = Array(body.utf8).split(separator: 10, omittingEmptySubsequences: false)
        let markerExpression = try NSRegularExpression(pattern: #"\[\^([^\]\s]+)\]"#)
        var pending: [any Markup] = [document]
        var visited = 0
        while let node = pending.popLast() {
            visited += 1
            guard visited <= 100_000 else {
                throw TractandaError("importMarkdownLimit", "Markdown exceeds the syntax-node bound.")
            }
            if title == nil, let heading = node as? Heading, heading.level == 1 {
                title = heading.plainText
            }
            let destination: String?
            if let link = node as? Link {
                destination = link.destination
            } else if let image = node as? Image {
                destination = image.source
            } else {
                destination = nil
            }
            if let destination {
                guard links.count < maximumLinks else {
                    throw TractandaError("importMarkdownLimit", "Markdown exceeds the outgoing-link bound.")
                }
                var link = Self.resolve(destination, from: relativePath, okf: okf, knownPaths: knownPaths)
                link.sourceLine = node.range.map { $0.lowerBound.line + lineOffset }
                link.sourceColumn = node.range?.lowerBound.column
                links.append(link)
                var evidence: [String: ItemValue] = ["destination": .text(destination)]
                if let range = node.range {
                    evidence["sourceLine"] = .integer(Int64(range.lowerBound.line + lineOffset))
                    evidence["sourceColumn"] = .integer(Int64(range.lowerBound.column))
                    if let raw = Self.slice(sourceLines, range: range) {
                        evidence["rawMarkdown"] = .text(raw)
                    }
                }
                linkEvidence.append(.object(evidence))
            }
            // CommonMark does not promise a complete footnote dialect. Detect OKF source-ID
            // markers only in actual text nodes, excluding inline code and fenced code.
            if node is Text, let range = node.range, let rawText = Self.slice(sourceLines, range: range) {
                // Scan source syntax, not Text.string: the latter has already decoded escaped
                // brackets and entities which may deliberately express literal marker text.
                let string = rawText as NSString
                for match in markerExpression.matches(
                    in: rawText, range: NSRange(location: 0, length: string.length))
                {
                    var preceding = match.range.location - 1
                    var backslashes = 0
                    while preceding >= 0, string.character(at: preceding) == 92 {
                        backslashes += 1
                        preceding -= 1
                    }
                    if backslashes % 2 == 1 { continue }
                    let id = string.substring(with: match.range(at: 1))
                    sourceMentions.append(
                        .object([
                            "sourceID": .text(id), "marker": .text("[^\(id)]"),
                            "resolution": .text(sourceIDs.contains(id) ? "source" : "unresolved"),
                            "sourceLine": .integer(Int64((node.range?.lowerBound.line ?? 0) + lineOffset)),
                            "sourceColumn": .integer(Int64(node.range?.lowerBound.column ?? 0)),
                            "sourceSpanKind": .text("enclosingMarkdownTextNode"),
                            "textOffsetUTF16": .integer(Int64(match.range.location)),
                            "textOffsetEncoding": .text("rawMarkdownUTF16"),
                        ]))
                    guard sourceMentions.count <= maximumLinks else {
                        throw TractandaError(
                            "importMarkdownLimit", "Markdown exceeds the source-marker bound.")
                    }
                }
            }
            pending.append(contentsOf: Array(node.children).reversed())
        }
    }

    static func resolve(_ target: String, from path: String, okf: Bool, knownPaths: Set<String>) -> ImportLink
    {
        let parts = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = String(parts[0])
        let fragment = parts.count == 2 ? String(parts[1]) : nil
        if rawPath.hasPrefix("//")
            || rawPath.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil
        {
            return .init(originalTarget: target, fragment: fragment, kind: .external)
        }
        guard !rawPath.contains("?"), let decoded = rawPath.removingPercentEncoding else {
            return .init(originalTarget: target, fragment: fragment, kind: .unsupported)
        }
        guard !decoded.contains("\\"), !decoded.contains("\0"),
            !decoded.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
        else {
            return .init(originalTarget: target, fragment: fragment, kind: .unsafe)
        }
        var components = decoded.hasPrefix("/") ? [] : path.split(separator: "/").dropLast().map(String.init)
        if decoded.isEmpty {
            components = path.split(separator: "/").map(String.init)
        } else {
            for component in decoded.split(separator: "/") {
                if component == "." { continue }
                if component == ".." {
                    guard !components.isEmpty else {
                        return .init(originalTarget: target, fragment: fragment, kind: .unsafe)
                    }
                    components.removeLast()
                } else {
                    components.append(String(component))
                }
            }
        }
        let normalized = components.joined(separator: "/")
        let candidate: String
        if knownPaths.contains(normalized) {
            candidate = normalized
        } else if okf, knownPaths.contains(normalized + ".md") {
            candidate = normalized + ".md"
        } else {
            candidate = normalized
        }
        guard !candidate.isEmpty else {
            return .init(originalTarget: target, fragment: fragment, kind: .unsupported)
        }
        let sourceID = okf && candidate.hasSuffix(".md") ? String(candidate.dropLast(3)) : candidate
        return .init(
            originalTarget: target, targetSourceID: sourceID, fragment: fragment,
            kind: knownPaths.contains(candidate) ? .local : .missing)
    }

    private static func slice(_ lines: [ArraySlice<UInt8>], range: SourceRange) -> String? {
        let lower = range.lowerBound
        let upper = range.upperBound
        guard lower.line > 0, upper.line >= lower.line, upper.line <= lines.count else { return nil }
        var bytes: [UInt8] = []
        for line in lower.line...upper.line {
            let content = lines[line - 1]
            let start = line == lower.line ? lower.column - 1 : 0
            let end = line == upper.line ? upper.column - 1 : content.count
            guard start >= 0, end >= start, end <= content.count else { return nil }
            let startIndex = content.index(content.startIndex, offsetBy: start)
            let endIndex = content.index(content.startIndex, offsetBy: end)
            bytes.append(contentsOf: content[startIndex..<endIndex])
            if line < upper.line { bytes.append(10) }
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}
