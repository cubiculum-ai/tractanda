import CoreFoundation
import Foundation

public struct DocumentConverterIdentity: Codable, Equatable, Sendable {
    public let converter: String
    public let model: String
    public let modelRevision: String
    public let runtimeRevision: String
    public let preprocessing: String
    public let parser: String

    public init() {
        converter = "tractanda.docling-native.v2-idefics3-gelu-f32"
        model = "ibm-granite/granite-docling-258M-mlx"
        modelRevision = "a8b999991fe8c521a0cec749973414eaaf823731"
        runtimeRevision = "61a4b20d4ad01b10466e8fc94c50402a9f994430"
        preprocessing = "opaque-rgb-content-crop-hf4561-pillow123-grid-v2"
        parser = "doctags-strict-v1"
    }

    public func validate() throws {
        let current = Self()
        guard [current.converter, "tractanda.docling-native.v1"].contains(converter), model == current.model,
            modelRevision == current.modelRevision, runtimeRevision == current.runtimeRevision,
            parser == current.parser,
            (converter == current.converter && preprocessing == current.preprocessing)
                || (converter == "tractanda.docling-native.v1"
                    && [current.preprocessing, "opaque-rgb2048-17tiles-v1"].contains(preprocessing))
        else {
            throw TractandaError("unsupportedDocumentConverter", "Unsupported document converter identity.")
        }
    }

    /// Known historical metadata remains readable. New subprocess results must
    /// use the active profile; there is no legacy image-generation path.
    public func validateCurrent() throws {
        guard self == Self() else {
            throw TractandaError(
                "unsupportedDocumentConverter", "Unsupported active document converter identity.")
        }
    }
}

public struct AttachmentDocumentSource: Codable, Equatable, Sendable {
    public let itemID: String
    public let revisionID: String
    public let attachmentID: String
    public let sha256: String
    public let byteCount: Int64
    public let mediaType: String

    public init(
        itemID: String, revisionID: String, attachmentID: String, sha256: String,
        byteCount: Int64, mediaType: String
    ) throws {
        self.itemID = itemID
        self.revisionID = revisionID
        self.attachmentID = attachmentID
        self.sha256 = sha256
        self.byteCount = byteCount
        self.mediaType = mediaType
        try validate()
    }

    public func validate() throws {
        for id in [itemID, revisionID, attachmentID] { try DocumentValue.validateID(id) }
        guard DocumentValue.isSHA256(sha256), byteCount > 0,
            ["image/png", "image/jpeg", "application/pdf"].contains(mediaType)
        else { throw TractandaError("unsupportedDocumentInput", "Unsupported document source or limit.") }
    }
}

public struct AttachmentDocumentPage: Codable, Equatable, Sendable {
    public let pageNumber: Int
    public let geometry: DocumentPageGeometry
    public let rasterSHA256: String
    public let parsed: DoclingParsedPage
    public let generatedTokens: Int
    public let stopReason: String

    public init(
        pageNumber: Int, geometry: DocumentPageGeometry, rasterSHA256: String,
        parsed: DoclingParsedPage, generatedTokens: Int, stopReason: String
    ) throws {
        self.pageNumber = pageNumber
        self.geometry = geometry
        self.rasterSHA256 = rasterSHA256
        self.parsed = parsed
        self.generatedTokens = generatedTokens
        self.stopReason = stopReason
        try validate()
    }

    public func validate() throws {
        guard pageNumber > 0, DocumentValue.isSHA256(rasterSHA256) else {
            throw TractandaError("invalidDocumentOutput", "Invalid document page identity.")
        }
        guard stopReason == "stop", (0..<1024).contains(generatedTokens) else {
            throw TractandaError("truncatedDocumentOutput", "Document generation did not complete.")
        }
        try geometry.validate()
        try parsed.validate()
    }
}

/// Bounded subprocess output. The store independently parses rawDocTags; a child
/// cannot supply trusted parsed blocks or canonical attachment identities.
public struct DocumentGeneratedPage: Codable, Equatable, Sendable {
    public let pageNumber: Int
    public let geometry: DocumentPageGeometry
    public let rasterSHA256: String
    public let rawDocTags: String
    public let generatedTokens: Int
    public let stopReason: String

    public init(
        pageNumber: Int, geometry: DocumentPageGeometry, rasterSHA256: String,
        rawDocTags: String, generatedTokens: Int, stopReason: String
    ) {
        self.pageNumber = pageNumber
        self.geometry = geometry
        self.rasterSHA256 = rasterSHA256
        self.rawDocTags = rawDocTags
        self.generatedTokens = generatedTokens
        self.stopReason = stopReason
    }
}

public struct DocumentConversionResult: Codable, Equatable, Sendable {
    public let identity: DocumentConverterIdentity
    public let inputSHA256: String
    public let pages: [DocumentGeneratedPage]

    public init(identity: DocumentConverterIdentity, inputSHA256: String, pages: [DocumentGeneratedPage]) {
        self.identity = identity
        self.inputSHA256 = inputSHA256
        self.pages = pages
    }
}

/// A page selection from a complete saved extraction, not a canonical representation.
/// Selected pages may start at page two; totalPageCount describes the saved whole.
public struct AttachmentDocumentReadResult: Codable, Equatable, Sendable {
    public let itemID: String
    public let revisionID: String
    public let attachmentID: String
    public let representationID: String
    public let source: AttachmentDocumentSource
    public let extractedAt: String
    public let identity: DocumentConverterIdentity
    public let totalPageCount: Int64
    public let content: DocumentContentReference?
    public let outcomes: [DocumentStoredPage]?
    public let selectedPageNumber: Int?
    public let pages: [AttachmentDocumentPage]

    public init(
        revision: Revision, document: AttachmentDocumentRepresentation, pageNumber: Int?,
        savedPage: DocumentStoredPage? = nil
    ) throws {
        if let pageNumber,
            !(1...(document.content?.pageCount ?? Int64(document.pages.count))).contains(Int64(pageNumber))
        {
            throw TractandaError("notFound", "The saved document page is unavailable.")
        }
        itemID = revision.itemID
        revisionID = revision.revisionID
        attachmentID = document.attachmentID
        representationID = document.representationID
        source = document.source
        extractedAt = document.extractedAt
        identity = document.identity
        totalPageCount = document.content?.pageCount ?? Int64(document.pages.count)
        content = document.content
        outcomes = savedPage.map { [$0] }
        selectedPageNumber = pageNumber
        pages =
            savedPage.map { $0.page.map { [$0] } ?? [] }
            ?? (pageNumber.map { wanted in document.pages.filter { $0.pageNumber == wanted } }
                ?? document.pages)
    }
}

/// Original extraction provenance stays immutable; attachmentID is the current
/// local locator and is remapped independently when an item is copied.
public struct AttachmentDocumentRepresentation: Codable, Equatable, Sendable {
    public static let fieldName = "attachmentDocument"
    public static let maximumInputBytes: Int64 = 8 * 1024 * 1024
    public static let maximumAggregateEncodedBytes = 2 * 1024 * 1024
    public static let schemaName = "tractanda.attachment-document.v1"
    public static let storedSchemaName = "tractanda.attachment-document.v2"
    public let schema: String
    public let state: String
    public let representationID: String
    public let attachmentID: String
    public let source: AttachmentDocumentSource
    public let extractedAt: String
    public let identity: DocumentConverterIdentity
    public let pages: [AttachmentDocumentPage]
    public let content: DocumentContentReference?

    public init(
        representationID: String, attachmentID: String, source: AttachmentDocumentSource,
        extractedAt: String, identity: DocumentConverterIdentity, pages: [AttachmentDocumentPage]
    ) throws {
        schema = Self.schemaName
        state = "complete"
        self.representationID = representationID
        self.attachmentID = attachmentID
        self.source = source
        self.extractedAt = extractedAt
        self.identity = identity
        self.pages = pages
        content = nil
        try validate()
    }

    public init(
        representationID: String, attachmentID: String, source: AttachmentDocumentSource,
        extractedAt: String, identity: DocumentConverterIdentity, content: DocumentContentReference
    ) throws {
        schema = Self.storedSchemaName
        state = content.coverage.state
        self.representationID = representationID
        self.attachmentID = attachmentID
        self.source = source
        self.extractedAt = extractedAt
        self.identity = identity
        pages = []
        self.content = content
        try validate()
    }

    public func validate() throws {
        guard Timestamp.parse(extractedAt) != nil else {
            throw TractandaError("invalidDocumentOutput", "Invalid extraction date.")
        }
        if let content {
            try content.validate()
            guard schema == Self.storedSchemaName, state == content.coverage.state, pages.isEmpty,
                source.mediaType == "application/pdf" || content.pageCount == 1
            else {
                throw TractandaError("invalidDocumentOutput", "Invalid stored document representation.")
            }
        } else {
            guard schema == Self.schemaName, state == "complete", (1...2).contains(pages.count),
                pages.map(\.pageNumber) == Array(1...pages.count),
                source.mediaType == "application/pdf" || pages.count == 1
            else {
                throw TractandaError("invalidDocumentOutput", "Invalid historical document representation.")
            }
        }
        try DocumentValue.validateID(representationID)
        try DocumentValue.validateID(attachmentID)
        try source.validate()
        try identity.validate()
        for page in pages {
            try page.validate()
            if identity.preprocessing == DocumentConverterIdentity().preprocessing {
                try page.geometry.validateContentCrop()
            } else {
                guard page.geometry.canvasWidth == 2048, page.geometry.canvasHeight == 2048 else {
                    throw TractandaError("invalidDocumentOutput", "Historical document canvas changed.")
                }
            }
        }
    }

    public func remapping(attachmentID: String, representationID: String) throws -> Self {
        if let content {
            return try Self(
                representationID: representationID, attachmentID: attachmentID, source: source,
                extractedAt: extractedAt, identity: identity, content: content)
        }
        return try Self(
            representationID: representationID, attachmentID: attachmentID, source: source,
            extractedAt: extractedAt, identity: identity, pages: pages)
    }

    public var itemValue: ItemValue {
        get throws {
            let object = try JSONSerialization.jsonObject(with: JSON.encode(self))
            guard case .object(var map) = try DocumentValue.tag(object) else {
                throw TractandaError("invalidDocumentOutput", "Invalid document representation encoding.")
            }
            map["extractedAt"] = .date(extractedAt)
            return .object(map)
        }
    }

    public init(_ value: ItemValue) throws {
        let object = try DocumentValue.untag(value)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        self = try DocumentValue.strictDecode(Self.self, data: data)
        try validate()
    }

    public static func representations(in fields: [String: ItemValue]) throws -> [Self] {
        guard let value = fields[fieldName] else { return [] }
        guard let values = value.array, values.count <= 128 else {
            throw TractandaError("resourceLimit", "Too many document representations.")
        }
        // Charge actual canonical tagged JSON, including indentation and raw output.
        guard try JSON.encode(value).count <= maximumAggregateEncodedBytes else {
            throw TractandaError("resourceLimit", "Document representations exceed their 2 MiB budget.")
        }
        let results = try values.map(Self.init)
        guard Set(results.map(\.representationID)).count == results.count,
            Set(results.map(\.attachmentID)).count == results.count
        else { throw TractandaError("invalidDocumentOutput", "Document representation IDs are duplicated.") }
        return results
    }
}

/// Strict JSON shape validation and the existing tagged canonical value encoding.
/// No serialized document structures are included as arbitrary prose in the corpus.
public enum DocumentValue {
    public static func strictDecode<T: Codable>(_ type: T.Type, data: Data) throws -> T {
        guard data.count <= AttachmentDocumentRepresentation.maximumAggregateEncodedBytes else {
            throw TractandaError("resourceLimit", "Document JSON exceeds its budget.")
        }
        let value = try JSON.decode(type, data)
        let original = try JSONSerialization.jsonObject(with: data)
        let canonical = try JSONSerialization.jsonObject(with: JSON.encode(value))
        guard let lhs = original as? NSDictionary, let rhs = canonical as? NSDictionary,
            lhs.isEqual(rhs)
        else { throw TractandaError("invalidDocumentOutput", "Document JSON has unknown or missing fields.") }
        return value
    }

    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func validateID(_ value: String) throws {
        try Identifier.validate(value)
        guard let uuid = UUID(uuidString: value) else {
            throw TractandaError("invalidDocumentOutput", "Document identities must be UUIDv1.")
        }
        var raw = uuid.uuid
        let bytes = withUnsafeBytes(of: &raw) { Array($0) }
        guard bytes[6] >> 4 == 1, bytes[8] & 0xC0 == 0x80 else {
            throw TractandaError("invalidDocumentOutput", "Document identities must be UUIDv1.")
        }
    }

    fileprivate static func tag(_ value: Any, depth: Int = 0) throws -> ItemValue {
        guard depth < 16 else { throw TractandaError("resourceLimit", "Document structure is too deep.") }
        if let text = value as? String { return .text(text) }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .boolean(number.boolValue) }
            let double = number.doubleValue
            guard double.isFinite else { throw TractandaError("invalidDocumentOutput", "Nonfinite number.") }
            if String(cString: number.objCType) != "d" { return .integer(number.int64Value) }
            return .real(double)
        }
        if let array = value as? [Any] { return .list(try array.map { try tag($0, depth: depth + 1) }) }
        if let map = value as? [String: Any] {
            return .object(try map.mapValues { try tag($0, depth: depth + 1) })
        }
        throw TractandaError("invalidDocumentOutput", "Unsupported document value.")
    }

    fileprivate static func untag(_ value: ItemValue, depth: Int = 0) throws -> Any {
        guard depth < 16 else { throw TractandaError("resourceLimit", "Document structure is too deep.") }
        switch value {
        case .text(let text), .date(let text): return text
        case .integer(let number): return number
        case .real(let number): return number
        case .boolean(let flag): return flag
        case .list(let values): return try values.map { try untag($0, depth: depth + 1) }
        case .object(let map): return try map.mapValues { try untag($0, depth: depth + 1) }
        case .bytes, .reference:
            throw TractandaError("invalidDocumentOutput", "Unsupported tagged document value.")
        }
    }
}
