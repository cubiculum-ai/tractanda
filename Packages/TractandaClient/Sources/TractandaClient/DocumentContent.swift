import Foundation

/// Processing coverage is separate from OCR accuracy. Converted pages passed structural validation.
public struct DocumentCoverage: Codable, Equatable, Sendable {
    public let converted: Int64
    public let unsupported: Int64
    public let truncated: Int64
    public let timedOut: Int64
    public let failed: Int64
    public init(
        converted: Int64, unsupported: Int64 = 0, truncated: Int64 = 0, timedOut: Int64 = 0, failed: Int64 = 0
    ) throws {
        self.converted = converted
        self.unsupported = unsupported
        self.truncated = truncated
        self.timedOut = timedOut
        self.failed = failed
        _ = try processedPageCount()
    }
    public func processedPageCount() throws -> Int64 {
        var count: Int64 = 0
        for value in [converted, unsupported, truncated, timedOut, failed] {
            let sum = count.addingReportingOverflow(value)
            guard value >= 0, !sum.overflow else {
                throw TractandaError("invalidDocumentContent", "Document coverage is not addressable.")
            }
            count = sum.partialValue
        }
        return count
    }
    public var state: String {
        unsupported == 0 && truncated == 0 && timedOut == 0 && failed == 0 ? "complete" : "partial"
    }
}

/// Immutable identity independent of whether a future replica has materialized every page locally.
public struct DocumentContentReference: Codable, Equatable, Sendable {
    public static let schemaName = "tractanda.document-content.v2"
    public let schema: String
    public let contentID: String
    public let manifestSHA256: String
    public let rootSHA256: String
    public let pageCount: Int64
    public let totalEncodedBytes: Int64
    public let coverage: DocumentCoverage
    public init(
        contentID: String, manifestSHA256: String, rootSHA256: String, pageCount: Int64,
        totalEncodedBytes: Int64, coverage: DocumentCoverage
    ) throws {
        schema = Self.schemaName
        self.contentID = contentID
        self.manifestSHA256 = manifestSHA256
        self.rootSHA256 = rootSHA256
        self.pageCount = pageCount
        self.totalEncodedBytes = totalEncodedBytes
        self.coverage = coverage
        try validate()
    }
    public func validate() throws {
        try DocumentValue.validateID(contentID)
        guard schema == Self.schemaName, DocumentValue.isSHA256(manifestSHA256),
            DocumentValue.isSHA256(rootSHA256), pageCount > 0, totalEncodedBytes > 0,
            try coverage.processedPageCount() == pageCount
        else {
            throw TractandaError("invalidDocumentContent", "Invalid immutable document reference.")
        }
    }
}

/// One independently bounded canonical page outcome. Local locator IDs never enter these bytes.
public struct DocumentStoredPage: Codable, Equatable, Sendable {
    public static let schemaName = "tractanda.document-page.v2"
    public let schema: String
    public let pageNumber: Int64
    public let sourceSHA256: String
    public let status: String
    public let page: AttachmentDocumentPage?
    public let failureCode: String?
    public init(pageNumber: Int64, sourceSHA256: String, page: AttachmentDocumentPage) throws {
        schema = Self.schemaName
        self.pageNumber = pageNumber
        self.sourceSHA256 = sourceSHA256
        status = "converted"
        self.page = page
        failureCode = nil
        try validate()
    }
    public init(pageNumber: Int64, sourceSHA256: String, status: String, failureCode: String) throws {
        schema = Self.schemaName
        self.pageNumber = pageNumber
        self.sourceSHA256 = sourceSHA256
        self.status = status
        page = nil
        self.failureCode = failureCode
        try validate()
    }
    public func validate() throws {
        guard schema == Self.schemaName, pageNumber > 0, DocumentValue.isSHA256(sourceSHA256) else {
            throw TractandaError("invalidDocumentContent", "Invalid saved page identity.")
        }
        if status == "converted" {
            guard let page, Int64(page.pageNumber) == pageNumber, failureCode == nil else {
                throw TractandaError("invalidDocumentContent", "Converted page identity changed.")
            }
            try page.validate()
        } else {
            guard ["unsupported", "truncated", "timeout", "failed"].contains(status), page == nil,
                let failureCode, !failureCode.isEmpty, failureCode.utf8.count <= 200,
                !failureCode.contains("\0")
            else {
                throw TractandaError("invalidDocumentContent", "Invalid explicit page failure.")
            }
        }
    }
}

/// Exact canonical dependency bytes in one bounded window; paths are relative to this content tree.
public struct DocumentContentPart: Codable, Sendable {
    public let contentID: String
    public let relativePath: String
    public let byteCount: Int64
    public let sha256: String
    public let offset: Int64
    public let nextOffset: Int64
    public let data: Data
    public let isComplete: Bool
    public init(
        contentID: String, relativePath: String, byteCount: Int64, sha256: String, offset: Int64,
        nextOffset: Int64, data: Data
    ) {
        self.contentID = contentID
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256 = sha256
        self.offset = offset
        self.nextOffset = nextOffset
        self.data = data
        isComplete = nextOffset == byteCount
    }
}
