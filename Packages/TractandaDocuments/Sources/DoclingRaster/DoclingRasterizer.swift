import CoreGraphics
import CryptoKit
import DoclingRGB
import Foundation
import ImageIO
import TractandaClient

public enum DoclingRasterError: Error, Equatable, CustomStringConvertible {
    case inputTooLarge
    case unsupportedMediaType
    case mediaTypeMismatch
    case malformedInput
    case unsupportedFrameCount
    case unsupportedOrientation
    case dimensionsExceeded
    case encryptedPDF
    case unsupportedPDFPageCount
    case emptyPDF
    case unsupportedPDFGeometry
    case fileAccessFailed
    case closedDocument
    case pageNumberOutOfRange
    case decodingFailed
    case renderingFailed
    case sourceIdentityMismatch
    case sourceChanged
    case sourceReadFailed

    public var description: String {
        switch self {
        case .inputTooLarge: "Document input exceeds 8 MiB."
        case .unsupportedMediaType: "Document media type is not supported."
        case .mediaTypeMismatch: "Document bytes do not match the declared media type."
        case .malformedInput: "Document input is malformed."
        case .unsupportedFrameCount: "Only single-frame images are supported."
        case .unsupportedOrientation: "Only identity image orientation is supported."
        case .dimensionsExceeded: "Document raster dimensions exceed the supported limit."
        case .encryptedPDF: "Encrypted PDF input is not supported."
        case .unsupportedPDFPageCount: "PDF input must contain one or two pages."
        case .emptyPDF: "PDF input contains no pages."
        case .unsupportedPDFGeometry: "PDF page geometry is unsupported."
        case .fileAccessFailed: "PDF file could not be opened."
        case .closedDocument: "PDF raster session is closed."
        case .pageNumberOutOfRange: "Requested PDF page is outside the document."
        case .decodingFailed: "Document image decoding failed."
        case .renderingFailed: "Document page rendering failed."
        case .sourceIdentityMismatch: "Original descriptor does not match its verified token."
        case .sourceChanged: "Original descriptor changed during this session."
        case .sourceReadFailed: "Original positional read failed."
        }
    }
}

public struct DocumentRasterPage: Sendable, Equatable {
    public let pageNumber: Int
    public let geometry: DocumentPageGeometry
    public let rgb: PackedRGB8
    public let renderedCanvasSHA256: String
    public let renderedCropBounds: [Int]

    public init(
        pageNumber: Int, geometry: DocumentPageGeometry, rgb: PackedRGB8,
        renderedCanvasSHA256: String, renderedCropBounds: [Int]
    ) {
        self.pageNumber = pageNumber
        self.geometry = geometry
        self.rgb = rgb
        self.renderedCanvasSHA256 = renderedCanvasSHA256
        self.renderedCropBounds = renderedCropBounds
    }
}

/// A file-backed PDF handle. Page count is checked into a signed 64-bit
/// value, while rendering remains lazy and bounded to one selected page.
/// Calls are serialized because Core Graphics document/page objects are not
/// exposed as concurrently mutable values.
public final class DoclingPDFRasterSession: @unchecked Sendable {
    public let pageCount: Int64
    private let session: DoclingFileRasterSession

    fileprivate static func open(at url: URL) throws -> DoclingPDFRasterSession {
        let session = try DoclingFileRasterSession.open(at: url, mediaType: "application/pdf", expected: nil)
        return DoclingPDFRasterSession(session)
    }
    private init(_ session: DoclingFileRasterSession) {
        self.session = session
        pageCount = session.pageCount
    }
    public func render(pageNumber: Int64) throws -> DocumentRasterPage {
        try session.render(pageNumber: pageNumber)
    }
    public func close() { session.close() }
    deinit { session.close() }
}

/// Bounded macOS decoding and rasterization. The legacy `Data` wrapper remains
/// limited to tiny one/two-page fixtures; `openPDF(at:)` provides lazy access to
/// file-backed PDFs of arbitrary page count. No model, OCR, text extraction, or
/// persistent storage is used.
public enum DoclingRasterizer {
    public static let maximumInputBytes = 8 * 1024 * 1024
    public static let maximumDimension = 2048
    public static let maximumPixels = 4_194_304
    public static let canvasDimension = 2048
    private static let bytesPerPixel = 4

    public static func rasterize(_ data: Data, mediaType: String) throws -> [DocumentRasterPage] {
        guard data.count <= maximumInputBytes else { throw DoclingRasterError.inputTooLarge }
        guard !data.isEmpty else { throw DoclingRasterError.malformedInput }

        switch mediaType {
        case "image/png":
            guard hasPNGSignature(data) else { throw DoclingRasterError.mediaTypeMismatch }
            return [try rasterizeImage(data, mediaType: mediaType)]
        case "image/jpeg":
            guard hasJPEGSignature(data) else { throw DoclingRasterError.mediaTypeMismatch }
            return [try rasterizeImage(data, mediaType: mediaType)]
        case "application/pdf":
            guard hasPDFSignature(data) else { throw DoclingRasterError.mediaTypeMismatch }
            return try rasterizePDF(data)
        default:
            throw DoclingRasterError.unsupportedMediaType
        }
    }

    /// Opens a local PDF without loading its original bytes into memory. The
    /// returned session retains the file-backed Core Graphics document until
    /// `close()` or deinitialization. Each render returns only the requested page.
    public static func openPDF(at url: URL) throws -> DoclingPDFRasterSession {
        try DoclingPDFRasterSession.open(at: url)
    }

    private static func rasterizeImage(_ data: Data, mediaType: String) throws -> DocumentRasterPage {
        if mediaType == "image/png" {
            let dimensions = try pngDimensions(data)
            try validateDimensions(width: dimensions.width, height: dimensions.height)
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw DoclingRasterError.malformedInput
        }
        return try rasterizeImageSource(
            source, mediaType: mediaType,
            pngHeader: mediaType == "image/png" ? try pngDimensions(data) : nil)
    }

    static func rasterizeImageSource(
        _ source: CGImageSource, mediaType: String, pngHeader: (width: Int, height: Int)?
    ) throws -> DocumentRasterPage {
        guard let decodedType = CGImageSourceGetType(source) as String? else {
            throw DoclingRasterError.decodingFailed
        }
        guard decodedType == (mediaType == "image/png" ? "public.png" : "public.jpeg") else {
            throw DoclingRasterError.mediaTypeMismatch
        }
        guard CGImageSourceGetCount(source) == 1 else { throw DoclingRasterError.unsupportedFrameCount }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let widthNumber = properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let heightNumber = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else { throw DoclingRasterError.malformedInput }
        let width = widthNumber.intValue
        let height = heightNumber.intValue
        try validateDimensions(width: width, height: height)

        if mediaType == "image/png" {
            guard let header = pngHeader, header.width == width, header.height == height else {
                throw DoclingRasterError.malformedInput
            }
        }

        if let orientation = properties[kCGImagePropertyOrientation] {
            guard let orientationNumber = orientation as? NSNumber,
                orientationNumber.intValue == 1, orientationNumber.doubleValue == 1
            else { throw DoclingRasterError.unsupportedOrientation }
        }
        guard
            let image = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCache: false] as CFDictionary
            ), image.width == width, image.height == height
        else {
            throw DoclingRasterError.decodingFailed
        }

        let placement = try imagePlacement(width: width, height: height)
        let rgb = try render { context in
            context.interpolationQuality = .high
            context.draw(image, in: placement.canvasRect)
        }
        let geometry = try DocumentPageGeometry(
            sourceWidth: Double(width), sourceHeight: Double(height), sourceUnit: "pixel",
            displayWidth: Double(width), displayHeight: Double(height),
            contentLeft: placement.left, contentTop: placement.top,
            contentWidth: placement.width, contentHeight: placement.height
        )
        return try contentRaster(pageNumber: 1, geometry: geometry, rgb: rgb)
    }

    private static func rasterizePDF(_ data: Data) throws -> [DocumentRasterPage] {
        guard let provider = CGDataProvider(data: data as CFData),
            let document = CGPDFDocument(provider)
        else { throw DoclingRasterError.malformedInput }
        guard !document.isEncrypted else { throw DoclingRasterError.encryptedPDF }
        let pageCount = document.numberOfPages
        guard (1...2).contains(pageCount) else { throw DoclingRasterError.unsupportedPDFPageCount }

        var output: [DocumentRasterPage] = []
        output.reserveCapacity(pageCount)
        for pageNumber in 1...pageCount {
            guard let page = document.page(at: pageNumber) else { throw DoclingRasterError.malformedInput }
            output.append(try rasterizePDFPage(page, pageNumber: pageNumber))
        }
        return output
    }

    static func rasterizePDFPage(_ page: CGPDFPage, pageNumber: Int) throws -> DocumentRasterPage {
        let cropBox = page.getBoxRect(.cropBox)
        let rotation = Int(page.rotationAngle)
        guard cropBox.origin.x.isFinite, cropBox.origin.y.isFinite,
            cropBox.width.isFinite, cropBox.height.isFinite,
            abs(cropBox.origin.x) <= 100_000, abs(cropBox.origin.y) <= 100_000,
            cropBox.width > 0, cropBox.height > 0,
            cropBox.width <= 100_000, cropBox.height <= 100_000,
            [0, 90, 180, 270].contains(rotation)
        else { throw DoclingRasterError.unsupportedPDFGeometry }

        let displayWidth = Double(rotation == 90 || rotation == 270 ? cropBox.height : cropBox.width)
        let displayHeight = Double(rotation == 90 || rotation == 270 ? cropBox.width : cropBox.height)
        let placement = try pagePlacement(width: displayWidth, height: displayHeight)
        let geometry = try DocumentPageGeometry(
            sourceWidth: Double(cropBox.width), sourceHeight: Double(cropBox.height),
            sourceOriginX: Double(cropBox.origin.x), sourceOriginY: Double(cropBox.origin.y),
            sourceRotation: rotation, sourceUnit: "pdfPoint",
            displayWidth: displayWidth, displayHeight: displayHeight,
            contentLeft: placement.left, contentTop: placement.top,
            contentWidth: placement.width, contentHeight: placement.height
        )
        let target = CGRect(
            x: placement.left,
            y: Double(canvasDimension) - placement.top - placement.height,
            width: placement.width,
            height: placement.height
        )
        let rgb = try render { context in
            context.interpolationQuality = .high
            context.clip(to: target)
            // CGPDFPageGetDrawingTransform only scales down (documented by
            // the SDK), so requesting a 2048 canvas leaves small PDF pages
            // unscaled. Apply our declared fit explicitly, then let CG map
            // crop origin/rotation into an unscaled displayed-page rectangle.
            context.translateBy(x: target.minX, y: target.minY)
            context.scaleBy(x: placement.width / displayWidth, y: placement.height / displayHeight)
            let pageRect = CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight)
            let transform = page.getDrawingTransform(
                .cropBox, rect: pageRect, rotate: 0, preserveAspectRatio: true)
            context.concatenate(transform)
            context.drawPDFPage(page)
        }
        return try contentRaster(pageNumber: pageNumber, geometry: geometry, rgb: rgb)
    }

    /// Preserve the fixed CoreGraphics render byte-for-byte, then remove only
    /// synthetic fit margins. Outward rounding retains fractional PDF edge samples.
    /// This raster, before the independent HF grid resize, is the citation canvas.
    private static func contentRaster(
        pageNumber: Int, geometry: DocumentPageGeometry, rgb: PackedRGB8
    ) throws -> DocumentRasterPage {
        let left = Int(floor(geometry.contentLeft))
        let top = Int(floor(geometry.contentTop))
        let right = Int(ceil(geometry.contentLeft + geometry.contentWidth))
        let bottom = Int(ceil(geometry.contentTop + geometry.contentHeight))
        guard left >= 0, top >= 0, right <= rgb.width, bottom <= rgb.height,
            right > left, bottom > top
        else { throw DoclingRasterError.renderingFailed }
        let width = right - left
        let height = bottom - top
        var bytes = Data(count: width * height * 3)
        rgb.bytes.withUnsafeBytes { source in
            bytes.withUnsafeMutableBytes { destination in
                for row in 0..<height {
                    let sourceOffset = ((top + row) * rgb.width + left) * 3
                    let destinationOffset = row * width * 3
                    destination.baseAddress!.advanced(by: destinationOffset).copyMemory(
                        from: source.baseAddress!.advanced(by: sourceOffset), byteCount: width * 3)
                }
            }
        }
        let croppedGeometry = try DocumentPageGeometry(
            sourceWidth: geometry.sourceWidth, sourceHeight: geometry.sourceHeight,
            sourceOriginX: geometry.sourceOriginX, sourceOriginY: geometry.sourceOriginY,
            sourceRotation: geometry.sourceRotation, sourceUnit: geometry.sourceUnit,
            displayWidth: geometry.displayWidth, displayHeight: geometry.displayHeight,
            canvasWidth: width, canvasHeight: height,
            contentLeft: geometry.contentLeft - Double(left),
            contentTop: geometry.contentTop - Double(top),
            contentWidth: geometry.contentWidth, contentHeight: geometry.contentHeight)
        return DocumentRasterPage(
            pageNumber: pageNumber, geometry: croppedGeometry,
            rgb: try PackedRGB8(width: width, height: height, bytes: bytes),
            renderedCanvasSHA256: SHA256.hash(data: rgb.bytes).map { String(format: "%02x", $0) }.joined(),
            renderedCropBounds: [left, top, right, bottom])
    }

    private struct Placement {
        let left: Double
        let top: Double
        let width: Double
        let height: Double

        var canvasRect: CGRect {
            CGRect(
                x: left, y: Double(DoclingRasterizer.canvasDimension) - top - height,
                width: width, height: height)
        }
    }

    private static func imagePlacement(width: Int, height: Int) throws -> Placement {
        try validateDimensions(width: width, height: height)
        return try pagePlacement(width: Double(width), height: Double(height))
    }

    private static func pagePlacement(width: Double, height: Double) throws -> Placement {
        guard width.isFinite, height.isFinite, width > 0, height > 0,
            width <= 100_000, height <= 100_000
        else { throw DoclingRasterError.unsupportedPDFGeometry }
        let scale = min(Double(canvasDimension) / width, Double(canvasDimension) / height)
        let drawnWidth = width * scale
        let drawnHeight = height * scale
        return Placement(
            left: (Double(canvasDimension) - drawnWidth) / 2,
            top: (Double(canvasDimension) - drawnHeight) / 2,
            width: drawnWidth,
            height: drawnHeight
        )
    }

    static func validateDimensions(width: Int, height: Int) throws {
        guard width > 0, height > 0,
            width <= maximumDimension, height <= maximumDimension,
            width <= maximumPixels / height
        else { throw DoclingRasterError.dimensionsExceeded }
    }

    private static func render(_ draw: (CGContext) -> Void) throws -> PackedRGB8 {
        let width = canvasDimension
        let height = canvasDimension
        let rowBytes = width * bytesPerPixel
        var rgba = Data(count: rowBytes * height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw DoclingRasterError.renderingFailed
        }
        let rendered = rgba.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let address = rawBuffer.baseAddress,
                let context = CGContext(
                    data: address, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: rowBytes,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                )
            else { return false }
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            draw(context)
            context.flush()
            return true
        }
        guard rendered else { throw DoclingRasterError.renderingFailed }

        var packed = Data(count: width * height * 3)
        rgba.withUnsafeBytes { input in
            packed.withUnsafeMutableBytes { output in
                guard let inputBytes = input.bindMemory(to: UInt8.self).baseAddress,
                    let outputBytes = output.bindMemory(to: UInt8.self).baseAddress
                else { return }
                for outputRow in 0..<height {
                    // Bitmap storage is already top-to-bottom. Reversing rows here
                    // mirrors both ImageIO images and CoreGraphics PDF pages.
                    let inputRow = outputRow
                    for column in 0..<width {
                        let source = (inputRow * width + column) * bytesPerPixel
                        let destination = (outputRow * width + column) * 3
                        outputBytes[destination] = inputBytes[source]
                        outputBytes[destination + 1] = inputBytes[source + 1]
                        outputBytes[destination + 2] = inputBytes[source + 2]
                    }
                }
            }
        }
        return try PackedRGB8(width: width, height: height, bytes: packed)
    }

    static func hasPNGSignature(_ data: Data) -> Bool {
        data.count >= 8 && data.prefix(8).elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    static func hasJPEGSignature(_ data: Data) -> Bool {
        data.count >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF
    }

    static func hasPDFSignature(_ data: Data) -> Bool {
        data.count >= 5 && data.prefix(5).elementsEqual([0x25, 0x50, 0x44, 0x46, 0x2D])
    }

    static func pngDimensions(_ data: Data) throws -> (width: Int, height: Int) {
        guard data.count >= 24,
            data[12..<16].elementsEqual([0x49, 0x48, 0x44, 0x52]),
            data[8..<12].elementsEqual([0x00, 0x00, 0x00, 0x0D])
        else { throw DoclingRasterError.malformedInput }
        func uint32(_ range: Range<Int>) -> UInt32 {
            range.reduce(UInt32(0)) { ($0 << 8) | UInt32(data[$1]) }
        }
        let width = uint32(16..<20)
        let height = uint32(20..<24)
        return (Int(width), Int(height))
    }
}
