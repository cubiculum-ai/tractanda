import Foundation

/// Model-estimated top-left coordinates on the pinned DocTags 500-unit grid.
/// These are quantized raster regions, never offsets into an original binary.
public struct DoclingBoundingBox: Codable, Equatable, Sendable {
    public static let denominator = 500
    public let left: Int
    public let top: Int
    public let right: Int
    public let bottom: Int

    public init(left: Int, top: Int, right: Int, bottom: Int) throws {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
        try validate()
    }

    public func validate() throws {
        guard [left, top, right, bottom].allSatisfy({ (0..<Self.denominator).contains($0) }),
            left <= right, top <= bottom
        else { throw TractandaError("invalidDocumentOutput", "Invalid DocTags location box.") }
    }
}

public enum DoclingBlockKind: String, Codable, Sendable {
    case title, text, caption, footnote
    case listItem = "list_item"
    case pageHeader = "page_header"
    case pageFooter = "page_footer"
    case sectionHeader = "section_header"
    case table = "otsl"
}

/// Only a rectangular grid without OTSL span tokens is supported by this prototype.
public enum DoclingTableCellKind: String, Codable, Sendable {
    case data = "fcel"
    case columnHeader = "ched"
    case rowHeader = "rhed"
    case sectionRow = "srow"
    case empty = "ecel"
}

public struct DoclingTableCell: Codable, Equatable, Sendable {
    public let kind: DoclingTableCellKind
    public let text: String

    public init(kind: DoclingTableCellKind, text: String) throws {
        self.kind = kind
        self.text = text
        try validate()
    }

    public func validate() throws {
        guard text.utf8.count <= DoclingParsedPage.maximumTextBytes,
            kind != .empty || text.isEmpty
        else { throw TractandaError("invalidDocumentOutput", "Invalid document table cell.") }
    }
}

/// UTF8 ranges refer to the derived page text. A table has only its outer model box;
/// individual cells have no fabricated boxes. Newline separators are outside block ranges.
public struct DoclingBlock: Codable, Equatable, Sendable {
    public let kind: DoclingBlockKind
    public let headingLevel: Int?
    public let location: DoclingBoundingBox?
    public let text: String
    public let table: [[DoclingTableCell]]?
    public let textByteStart: Int
    public let textByteEnd: Int

    public init(
        kind: DoclingBlockKind, headingLevel: Int? = nil, location: DoclingBoundingBox? = nil,
        text: String, table: [[DoclingTableCell]]? = nil, textByteStart: Int, textByteEnd: Int
    ) throws {
        self.kind = kind
        self.headingLevel = headingLevel
        self.location = location
        self.text = text
        self.table = table
        self.textByteStart = textByteStart
        self.textByteEnd = textByteEnd
        try validate()
    }

    public func validate() throws {
        try location?.validate()
        guard textByteStart >= 0, textByteEnd >= textByteStart,
            textByteEnd <= DoclingParsedPage.maximumTextBytes,
            textByteEnd - textByteStart == text.utf8.count,
            (kind == .sectionHeader && headingLevel.map { (0...5).contains($0) } == true)
                || (kind != .sectionHeader && headingLevel == nil)
        else { throw TractandaError("invalidDocumentOutput", "Invalid document block or text range.") }
        if let table {
            guard kind == .table, !table.isEmpty, table.count <= 32,
                let columns = table.first?.count, (1...32).contains(columns),
                table.allSatisfy({ $0.count == columns })
            else { throw TractandaError("unsupportedDocumentOutput", "Unsupported document table grid.") }
            for row in table { for cell in row { try cell.validate() } }
            let rendered = table.map { $0.map(\.text).joined(separator: "\t") }.joined(separator: "\n")
            guard text == rendered else {
                throw TractandaError("invalidDocumentOutput", "Document table text does not match cells.")
            }
        } else if kind == .table {
            throw TractandaError("invalidDocumentOutput", "A document table requires cells.")
        }
    }
}

/// Complete strict-subset parsing of one generated page. Limits are validated again
/// at the canonical boundary because Codable alone is not an admission check.
public struct DoclingParsedPage: Codable, Equatable, Sendable {
    public static let maximumRawBytes = 256 * 1024
    public static let maximumTextBytes = 64 * 1024
    public static let maximumBlocks = 512
    public let rawDocTags: String
    public let blocks: [DoclingBlock]
    public let text: String

    public init(rawDocTags: String, blocks: [DoclingBlock], text: String) throws {
        self.rawDocTags = rawDocTags
        self.blocks = blocks
        self.text = text
        try validate()
    }

    public func validate() throws {
        guard rawDocTags.utf8.count <= Self.maximumRawBytes,
            text.utf8.count <= Self.maximumTextBytes, blocks.count <= Self.maximumBlocks
        else { throw TractandaError("resourceLimit", "Document page exceeds its output budget.") }
        var expectedOffset = 0
        for (index, block) in blocks.enumerated() {
            try block.validate()
            if index > 0 { expectedOffset += 1 }
            guard block.textByteStart == expectedOffset else {
                throw TractandaError("invalidDocumentOutput", "Document block ranges are not canonical.")
            }
            expectedOffset = block.textByteEnd
        }
        guard text == blocks.map(\.text).joined(separator: "\n"), text.utf8.count == expectedOffset else {
            throw TractandaError("invalidDocumentOutput", "Document text does not match blocks.")
        }
    }
}

/// Page coordinates are displayed upright, top-left units. The canvas describes
/// the packed source raster before the model's independent grid resize; normalized
/// DocTags coordinates map to it with separate canvas width/height factors. Original
/// PDF crop box and rotation remain explicit for mapping to original geometry.
public struct DocumentPageGeometry: Codable, Equatable, Sendable {
    public let sourceWidth: Double
    public let sourceHeight: Double
    public let sourceOriginX: Double
    public let sourceOriginY: Double
    public let sourceRotation: Int
    public let sourceUnit: String
    public let displayWidth: Double
    public let displayHeight: Double
    public let canvasWidth: Int
    public let canvasHeight: Int
    public let contentLeft: Double
    public let contentTop: Double
    public let contentWidth: Double
    public let contentHeight: Double

    public init(
        sourceWidth: Double, sourceHeight: Double, sourceOriginX: Double = 0, sourceOriginY: Double = 0,
        sourceRotation: Int = 0, sourceUnit: String, displayWidth: Double, displayHeight: Double,
        canvasWidth: Int = 2048, canvasHeight: Int = 2048,
        contentLeft: Double, contentTop: Double, contentWidth: Double, contentHeight: Double
    ) throws {
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.sourceOriginX = sourceOriginX
        self.sourceOriginY = sourceOriginY
        self.sourceRotation = sourceRotation
        self.sourceUnit = sourceUnit
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.contentLeft = contentLeft
        self.contentTop = contentTop
        self.contentWidth = contentWidth
        self.contentHeight = contentHeight
        try validate()
    }

    public var scale: Double { contentWidth / displayWidth }

    /// Current extraction removes synthetic fit margins with outward rounding.
    /// At most one fractional edge sample remains on each side of the content.
    public func validateContentCrop() throws {
        try validate()
        guard max(canvasWidth, canvasHeight) == 2048, contentLeft < 1, contentTop < 1,
            Double(canvasWidth) - contentLeft - contentWidth < 1,
            Double(canvasHeight) - contentTop - contentHeight < 1
        else { throw TractandaError("invalidDocumentOutput", "Document canvas is not the content crop.") }
    }

    public func validate() throws {
        let values = [
            sourceWidth, sourceHeight, sourceOriginX, sourceOriginY, displayWidth, displayHeight,
            contentLeft, contentTop, contentWidth, contentHeight,
        ]
        guard values.allSatisfy(\.isFinite), sourceWidth > 0, sourceHeight > 0,
            sourceWidth <= 100_000, sourceHeight <= 100_000,
            [0, 90, 180, 270].contains(sourceRotation), ["pixel", "pdfPoint"].contains(sourceUnit),
            displayWidth > 0, displayHeight > 0,
            (1...2048).contains(canvasWidth), (1...2048).contains(canvasHeight),
            contentLeft >= 0, contentTop >= 0, contentWidth > 0, contentHeight > 0,
            contentLeft + contentWidth <= Double(canvasWidth) + 0.000001,
            contentTop + contentHeight <= Double(canvasHeight) + 0.000001,
            abs(contentWidth / displayWidth - contentHeight / displayHeight) <= 0.000001
        else { throw TractandaError("invalidDocumentOutput", "Invalid document raster geometry.") }
        let rotated = sourceRotation == 90 || sourceRotation == 270
        guard displayWidth == (rotated ? sourceHeight : sourceWidth),
            displayHeight == (rotated ? sourceWidth : sourceHeight),
            sourceUnit != "pixel" || (sourceRotation == 0 && sourceOriginX == 0 && sourceOriginY == 0)
        else { throw TractandaError("invalidDocumentOutput", "Document display geometry changed.") }
    }
}
