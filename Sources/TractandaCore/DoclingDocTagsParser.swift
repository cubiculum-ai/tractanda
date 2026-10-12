import Foundation

/// Parses the deliberately small, non-executable DocTags subset used by document output.
public enum DoclingDocTagsParser {
    private static let maximumRawBytes = DoclingParsedPage.maximumRawBytes
    private static let maximumTextBytes = DoclingParsedPage.maximumTextBytes
    private static let maximumBlocks = DoclingParsedPage.maximumBlocks
    private static let maximumGridDimension = 32

    private struct Marker {
        let name: String
        let closing: Bool
    }

    private struct Cursor {
        let source: String
        var index: String.Index

        init(_ source: String) {
            self.source = source
            self.index = source.startIndex
        }

        var isAtEnd: Bool { index == source.endIndex }

        mutating func readMarker() throws -> Marker? {
            guard index < source.endIndex, source[index] == "<" else { return nil }
            let start = source.index(after: index)
            guard let end = source[start...].firstIndex(of: ">") else {
                throw failure("Truncated DocTags marker.")
            }
            let body = source[start..<end]
            guard !body.isEmpty, body.utf8.count <= 64 else {
                throw failure("Empty or overlong DocTags marker.")
            }
            let isClosing = body.first == "/"
            let name = isClosing ? String(body.dropFirst()) : String(body)
            guard !name.isEmpty,
                name.utf8.allSatisfy({
                    (48...57).contains($0) || (65...90).contains($0)
                        || (97...122).contains($0) || $0 == 95
                })
            else {
                throw failure("Unsupported DocTags marker syntax.")
            }
            index = source.index(after: end)
            return Marker(name: name, closing: isClosing)
        }

        mutating func takeText(untilMarker predicate: (Marker) -> Bool) throws -> String {
            let start = index
            while index < source.endIndex {
                guard source[index] == "<" else {
                    index = source.index(after: index)
                    continue
                }
                let saved = index
                guard let marker = try readMarker() else { break }
                index = saved
                if predicate(marker) { break }
                throw failure("Nested or unsupported structure inside a DocTags block.")
            }
            return String(source[start..<index])
        }

        func failure(_ message: String) -> TractandaError {
            TractandaError("unsupportedDocumentOutput", message)
        }
    }

    /// Parses one page that has already been decoded as UTF-8 text.
    public static func parse(_ raw: String) throws -> DoclingParsedPage {
        let rawBytes = raw.utf8.count
        guard rawBytes <= maximumRawBytes else {
            throw TractandaError("resourceLimit", "DocTags page exceeds its raw byte limit.")
        }

        var cursor = Cursor(raw)
        while cursor.index < raw.endIndex, raw[cursor.index].isWhitespace {
            cursor.index = raw.index(after: cursor.index)
        }
        // A BOM is valid Unicode but not part of the declared DocTags wire grammar.
        guard cursor.index < raw.endIndex, raw[cursor.index] == "<",
            try cursor.readMarker().map({ $0.name == "doctag" && !$0.closing }) == true
        else { throw cursor.failure("Expected exactly one complete doctag root.") }

        var blocks: [DoclingBlock] = []
        var pageText = ""
        while true {
            if cursor.isAtEnd { throw cursor.failure("Truncated doctag root.") }
            if raw[cursor.index] == "<" {
                guard let marker = try cursor.readMarker() else {
                    throw cursor.failure("Invalid DocTags marker.")
                }
                if marker.name == "doctag", marker.closing {
                    break
                }
                guard !marker.closing else { throw cursor.failure("Unexpected closing marker.") }
                guard blocks.count < maximumBlocks else {
                    throw TractandaError("resourceLimit", "DocTags page exceeds its block limit.")
                }
                let block = try parseBlock(marker.name, cursor: &cursor)
                let addition = block.text.utf8.count + (blocks.isEmpty ? 0 : 1)
                guard pageText.utf8.count <= maximumTextBytes - addition else {
                    throw TractandaError("resourceLimit", "DocTags page exceeds its plain-text limit.")
                }
                let start = pageText.utf8.count + (blocks.isEmpty ? 0 : 1)
                if !blocks.isEmpty { pageText.append("\n") }
                pageText.append(block.text)
                let finalized = try DoclingBlock(
                    kind: block.kind, headingLevel: block.headingLevel, location: block.location,
                    text: block.text, table: block.table, textByteStart: start,
                    textByteEnd: start + block.text.utf8.count)
                blocks.append(finalized)
            } else {
                let start = cursor.index
                while cursor.index < raw.endIndex, raw[cursor.index] != "<" {
                    cursor.index = raw.index(after: cursor.index)
                }
                guard raw[start..<cursor.index].allSatisfy({ $0.isWhitespace }) else {
                    throw cursor.failure("Unexpected text between DocTags blocks.")
                }
            }
        }

        while cursor.index < raw.endIndex {
            guard raw[cursor.index].isWhitespace else {
                throw cursor.failure("Unexpected content after doctag root.")
            }
            cursor.index = raw.index(after: cursor.index)
        }
        return try DoclingParsedPage(rawDocTags: raw, blocks: blocks, text: pageText)
    }

    /// Strict UTF-8 admission; invalid byte sequences are rejected without replacement decoding.
    public static func parse(_ data: Data) throws -> DoclingParsedPage {
        guard data.count <= maximumRawBytes else {
            throw TractandaError("resourceLimit", "DocTags page exceeds its raw byte limit.")
        }
        let raw = String(decoding: data, as: UTF8.self)
        guard Data(raw.utf8) == data else {
            throw TractandaError("invalidDocumentOutput", "DocTags page is not valid UTF-8.")
        }
        return try parse(raw)
    }

    private struct ParsedBlock {
        let kind: DoclingBlockKind
        let headingLevel: Int?
        let location: DoclingBoundingBox?
        let text: String
        let table: [[DoclingTableCell]]?
    }

    private static func parseBlock(_ name: String, cursor: inout Cursor) throws -> ParsedBlock {
        let kind: DoclingBlockKind
        let headingLevel: Int?
        if name.hasPrefix("section_header_level_") {
            let suffix = name.dropFirst("section_header_level_".count)
            guard let level = Int(suffix), (0...5).contains(level), String(level) == suffix else {
                throw cursor.failure("Unsupported section header level.")
            }
            kind = .sectionHeader
            headingLevel = level
        } else if let supported = DoclingBlockKind(rawValue: name), supported != .table {
            kind = supported
            headingLevel = nil
        } else if name == "otsl" {
            kind = .table
            headingLevel = nil
        } else {
            throw cursor.failure("Unsupported DocTags block tag <\(name)>.")
        }

        var locationValues: [Int] = []
        while true {
            let saved = cursor.index
            guard let next = try cursor.readMarker() else { break }
            if !next.closing, next.name.hasPrefix("loc_") {
                guard locationValues.count < 4,
                    let value = Int(next.name.dropFirst(4)),
                    String(value) == next.name.dropFirst(4),
                    (0..<DoclingBoundingBox.denominator).contains(value)
                else { throw cursor.failure("Malformed or out-of-range location token.") }
                locationValues.append(value)
            } else {
                cursor.index = saved
                break
            }
        }
        guard locationValues.isEmpty || locationValues.count == 4 else {
            throw cursor.failure("A location must contain exactly four leading loc tokens.")
        }
        let location: DoclingBoundingBox?
        if locationValues.isEmpty {
            location = nil
        } else {
            location = try DoclingBoundingBox(
                left: locationValues[0], top: locationValues[1],
                right: locationValues[2], bottom: locationValues[3])
        }

        if kind == .table {
            let parsed = try parseTable(cursor: &cursor)
            return ParsedBlock(
                kind: kind, headingLevel: nil, location: location,
                text: parsed.text, table: parsed.cells)
        }

        let content = try cursor.takeText { $0.closing }
        guard let close = try cursor.readMarker(), close.closing, close.name == name else {
            throw cursor.failure("Mismatched or missing DocTags closing marker for <\(name)>.")
        }
        return ParsedBlock(
            kind: kind, headingLevel: headingLevel, location: location,
            text: content, table: nil)
    }

    private static func parseTable(cursor: inout Cursor) throws -> (cells: [[DoclingTableCell]], text: String)
    {
        var rows: [[DoclingTableCell]] = []
        var row: [DoclingTableCell] = []
        while true {
            guard let marker = try cursor.readMarker() else {
                throw cursor.failure("Truncated OTSL table.")
            }
            if marker.closing {
                guard marker.name == "otsl" else {
                    throw cursor.failure("Mismatched OTSL closing marker.")
                }
                if !row.isEmpty {
                    if let columns = rows.first?.count, row.count != columns {
                        throw cursor.failure("Ragged OTSL table grid.")
                    }
                    rows.append(row)
                }
                break
            }
            if marker.name == "nl" {
                guard !row.isEmpty else { throw cursor.failure("Empty OTSL row.") }
                if let columns = rows.first?.count, row.count != columns {
                    throw cursor.failure("Ragged OTSL table grid.")
                }
                rows.append(row)
                guard rows.count <= maximumGridDimension else {
                    throw TractandaError("resourceLimit", "OTSL table exceeds its row limit.")
                }
                row = []
                continue
            }
            guard let cellKind = DoclingTableCellKind(rawValue: marker.name) else {
                if ["lcel", "ucel", "xcel"].contains(marker.name) {
                    throw cursor.failure("Merged OTSL spans are unsupported.")
                }
                throw cursor.failure("Unsupported OTSL marker <\(marker.name)>.")
            }
            guard row.count < maximumGridDimension else {
                throw TractandaError("resourceLimit", "OTSL table exceeds its column limit.")
            }
            let value: String
            if cellKind == .empty {
                value = ""
            } else {
                value = try cursor.takeText { marker in
                    marker.closing || marker.name == "nl"
                        || DoclingTableCellKind(rawValue: marker.name) != nil
                        || ["lcel", "ucel", "xcel"].contains(marker.name)
                }
            }
            row.append(try DoclingTableCell(kind: cellKind, text: value))
        }

        guard !rows.isEmpty, rows.count <= maximumGridDimension,
            let columns = rows.first?.count, (1...maximumGridDimension).contains(columns),
            rows.allSatisfy({ $0.count == columns })
        else { throw cursor.failure("OTSL table must be a nonempty rectangular grid.") }
        let text = rows.map { $0.map(\.text).joined(separator: "\t") }.joined(separator: "\n")
        return (rows, text)
    }
}
