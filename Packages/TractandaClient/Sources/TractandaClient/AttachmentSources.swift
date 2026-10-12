import Foundation

/// Immutable correspondence between shared corpus bytes and a typed original location.
public struct AttachmentSourceSegment: Codable, Equatable, Sendable {
    public let itemID: String
    public let revisionID: String
    public let attachmentID: String
    public let representationID: String
    public let sourceSHA256: String
    public let corpusByteStart: Int
    public let corpusByteEnd: Int
    public let location: AttachmentSourceLocation
    public init(
        itemID: String, revisionID: String, attachmentID: String, representationID: String,
        sourceSHA256: String, corpusByteStart: Int, corpusByteEnd: Int,
        sourceByteStart: Int, sourceByteEnd: Int
    ) {
        self.itemID = itemID
        self.revisionID = revisionID
        self.attachmentID = attachmentID
        self.representationID = representationID
        self.sourceSHA256 = sourceSHA256
        self.corpusByteStart = corpusByteStart
        self.corpusByteEnd = corpusByteEnd
        self.location = .originalBytes(byteStart: sourceByteStart, byteEnd: sourceByteEnd)
    }
    public init(
        itemID: String, revisionID: String, attachmentID: String, representationID: String,
        sourceSHA256: String, corpusByteStart: Int, corpusByteEnd: Int,
        location: AttachmentSourceLocation
    ) {
        self.itemID = itemID
        self.revisionID = revisionID
        self.attachmentID = attachmentID
        self.representationID = representationID
        self.sourceSHA256 = sourceSHA256
        self.corpusByteStart = corpusByteStart
        self.corpusByteEnd = corpusByteEnd
        self.location = location
    }
    public var sourceByteStart: Int? {
        if case .originalBytes(let start, _) = location { return start }
        return nil
    }
    public var sourceByteEnd: Int? {
        if case .originalBytes(_, let end) = location { return end }
        return nil
    }
    public func shifted(by bytes: Int) -> Self {
        Self(
            itemID: itemID, revisionID: revisionID, attachmentID: attachmentID,
            representationID: representationID, sourceSHA256: sourceSHA256,
            corpusByteStart: corpusByteStart + bytes, corpusByteEnd: corpusByteEnd + bytes,
            location: location)
    }
    public func overlap(with range: Range<Int>) -> AttachmentPassageSource? {
        let start = max(corpusByteStart, range.lowerBound)
        let end = min(corpusByteEnd, range.upperBound)
        guard start < end else { return nil }
        return AttachmentPassageSource(
            itemID: itemID, revisionID: revisionID,
            attachmentID: attachmentID, representationID: representationID,
            sourceSHA256: sourceSHA256,
            location: location.overlap(offset: start - corpusByteStart, length: end - start),
            corpusByteStart: start, corpusByteEnd: end)
    }
}
/// Typed original location for the portion of a semantic passage belonging to an attachment.
public struct AttachmentPassageSource: Codable, Equatable, Sendable {
    public let itemID: String
    public let revisionID: String
    public let attachmentID: String
    public let representationID: String
    public let sourceSHA256: String
    public let location: AttachmentSourceLocation
    public let corpusByteStart: Int
    public let corpusByteEnd: Int
    public var byteStart: Int? {
        if case .originalBytes(let start, _) = location { return start }
        return nil
    }
    public var byteEnd: Int? {
        if case .originalBytes(_, let end) = location { return end }
        return nil
    }
}
