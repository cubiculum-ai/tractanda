#if os(Linux)
    import CDoclingRaster
    #if canImport(CryptoKit)
        import CryptoKit
    #else
        import Crypto
    #endif
    import DoclingRGB
    import Foundation
    import Glibc
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

    public enum DoclingRasterizer {
        public static let maximumInputBytes = 8 * 1024 * 1024
        public static let maximumDimension = 2048
        public static let maximumPixels = 4_194_304
        public static let canvasDimension = 2048

        static func media(_ prefix: Data, _ type: String) throws -> Int32 {
            switch type {
            case "application/pdf":
                guard hasPDFSignature(prefix) else { throw DoclingRasterError.mediaTypeMismatch }
                return 1
            case "image/png":
                guard hasPNGSignature(prefix) else { throw DoclingRasterError.mediaTypeMismatch }
                let size = try pngDimensions(prefix)
                try validateDimensions(width: size.width, height: size.height)
                return 2
            case "image/jpeg":
                guard hasJPEGSignature(prefix) else { throw DoclingRasterError.mediaTypeMismatch }
                return 3
            default: throw DoclingRasterError.unsupportedMediaType
            }
        }
        public static func rasterize(_ data: Data, mediaType: String) throws -> [DocumentRasterPage] {
            guard data.count <= maximumInputBytes else { throw DoclingRasterError.inputTooLarge }
            guard !data.isEmpty else { throw DoclingRasterError.malformedInput }
            let media = try media(Data(data.prefix(32)), mediaType)
            let memory = MemoryRasterSource(data)
            var handle: OpaquePointer?
            var count: Int64 = 0
            try nativeStatus(
                tdr_open(
                    Unmanaged.passUnretained(memory).toOpaque(), memoryRead, UInt64(data.count), media,
                    &handle, &count))
            guard let handle else { throw DoclingRasterError.decodingFailed }
            defer {
                tdr_close(handle)
                withExtendedLifetime(memory) {}
            }
            guard (1...2).contains(count) else { throw DoclingRasterError.unsupportedPDFPageCount }
            return try (1...count).map { try renderNative(handle, number: $0) }
        }
        public static func openPDF(at url: URL) throws -> DoclingPDFRasterSession {
            try DoclingPDFRasterSession(
                DoclingFileRasterSession.open(at: url, mediaType: "application/pdf", expected: nil))
        }
        static func validateDimensions(width: Int, height: Int) throws {
            guard width > 0, height > 0, width <= maximumDimension, height <= maximumDimension,
                width <= maximumPixels / height
            else { throw DoclingRasterError.dimensionsExceeded }
        }
        static func contentRaster(
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
                renderedCanvasSHA256: SHA256.hash(data: rgb.bytes).map { String(format: "%02x", $0) }
                    .joined(),
                renderedCropBounds: [left, top, right, bottom])
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

    private func nativeStatus(_ status: Int32) throws {
        switch status {
        case 0: return
        case 1: throw DoclingRasterError.malformedInput
        case 2: throw DoclingRasterError.decodingFailed
        case 3, 12: throw DoclingRasterError.renderingFailed
        case 4: throw DoclingRasterError.dimensionsExceeded
        case 5: throw DoclingRasterError.unsupportedFrameCount
        case 6: throw DoclingRasterError.unsupportedOrientation
        case 7: throw DoclingRasterError.encryptedPDF
        case 8: throw DoclingRasterError.emptyPDF
        case 9: throw DoclingRasterError.unsupportedPDFGeometry
        case 10: throw DoclingRasterError.pageNumberOutOfRange
        default: throw DoclingRasterError.sourceReadFailed
        }
    }
    private func renderNative(_ handle: OpaquePointer, number: Int64) throws -> DocumentRasterPage {
        try Task<Never, Never>.checkCancellation()
        var bytes = Data(count: 2048 * 2048 * 3)
        var value = tdr_geometry()
        let status = bytes.withUnsafeMutableBytes { buffer in
            tdr_render(handle, number, buffer.bindMemory(to: UInt8.self).baseAddress!, buffer.count, &value)
        }
        try Task<Never, Never>.checkCancellation()
        try nativeStatus(status)
        guard let page = Int(exactly: number) else { throw DoclingRasterError.pageNumberOutOfRange }
        let geometry = try DocumentPageGeometry(
            sourceWidth: value.source_width, sourceHeight: value.source_height,
            sourceOriginX: value.source_x, sourceOriginY: value.source_y,
            sourceRotation: Int(value.rotation), sourceUnit: value.pdf == 1 ? "pdfPoint" : "pixel",
            displayWidth: value.display_width, displayHeight: value.display_height,
            contentLeft: value.left, contentTop: value.top, contentWidth: value.width,
            contentHeight: value.height)
        return try DoclingRasterizer.contentRaster(
            pageNumber: page, geometry: geometry,
            rgb: PackedRGB8(width: 2048, height: 2048, bytes: bytes))
    }
    private final class MemoryRasterSource {
        let data: Data
        init(_ data: Data) { self.data = data }
    }
    private let memoryRead:
        @convention(c) (UnsafeMutableRawPointer?, UInt64, UnsafeMutablePointer<UInt8>?, Int) -> Int32 = {
            context, offset, output, count in
            guard let context, let output, count >= 0 else { return 0 }
            let data = Unmanaged<MemoryRasterSource>.fromOpaque(context).takeUnretainedValue().data
            guard offset <= UInt64(data.count), UInt64(count) <= UInt64(data.count) - offset else { return 0 }
            data.withUnsafeBytes { buffer in
                output.update(
                    from: buffer.bindMemory(to: UInt8.self).baseAddress!.advanced(by: Int(offset)),
                    count: count)
            }
            return 1
        }
    /// Retains only a no-follow descriptor and its immutable identity. PDFium's
    /// positional callback never seeks or reads the full original into Data.
    private final class DescriptorSource {
        let fd: Int32
        let identity: NativeSourceFileIdentity
        private let lock = NSLock()
        private var readFailed = false
        private var changed = false
        static func metadata(_ fd: Int32) throws -> NativeSourceFileIdentity {
            var value = stat()
            guard fstat(fd, &value) == 0, value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), value.st_size > 0
            else { throw DoclingRasterError.fileAccessFailed }
            return NativeSourceFileIdentity(
                device: UInt64(truncatingIfNeeded: value.st_dev), inode: UInt64(value.st_ino),
                byteCount: Int64(value.st_size), mode: UInt32(value.st_mode), uid: value.st_uid,
                gid: value.st_gid,
                modificationSeconds: Int64(value.st_mtim.tv_sec),
                modificationNanoseconds: Int32(value.st_mtim.tv_nsec))
        }
        init(at url: URL, expected: NativeSourceFileIdentity?) throws {
            guard url.isFileURL, !url.path.contains("\0") else { throw DoclingRasterError.fileAccessFailed }
            let descriptor = Glibc.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard descriptor >= 0 else { throw DoclingRasterError.fileAccessFailed }
            do {
                let identity = try Self.metadata(descriptor)
                if let expected, identity != expected { throw DoclingRasterError.sourceIdentityMismatch }
                self.fd = descriptor
                self.identity = identity
            } catch {
                Glibc.close(descriptor)
                throw error
            }
        }
        deinit { Glibc.close(fd) }
        func validate() throws {
            lock.lock()
            let failed = readFailed
            let invalidated = changed
            lock.unlock()
            guard !failed else { throw DoclingRasterError.sourceReadFailed }
            guard !invalidated else { throw DoclingRasterError.sourceChanged }
            guard try Self.metadata(fd) == identity else {
                lock.lock()
                self.changed = true
                lock.unlock()
                throw DoclingRasterError.sourceChanged
            }
        }
        func read(offset: UInt64, output: UnsafeMutablePointer<UInt8>, count: Int) -> Int32 {
            guard count >= 0, offset <= UInt64(identity.byteCount),
                UInt64(count) <= UInt64(identity.byteCount) - offset
            else { return failed() }
            var done = 0
            while done < count {
                let n = min(262_144, count - done)
                let got = pread(fd, output.advanced(by: done), n, off_t(offset + UInt64(done)))
                if got < 0 && errno == EINTR { continue }
                guard got > 0 else { return failed() }
                done += got
            }
            return 1
        }
        private func failed() -> Int32 {
            lock.lock()
            readFailed = true
            lock.unlock()
            return 0
        }
        func prefix() throws -> Data {
            var bytes = Data(count: Int(min(32, identity.byteCount)))
            let success = bytes.withUnsafeMutableBytes {
                read(offset: 0, output: $0.bindMemory(to: UInt8.self).baseAddress!, count: $0.count)
            }
            try validate()
            guard success == 1 else { throw DoclingRasterError.sourceReadFailed }
            return bytes
        }
    }
    private let descriptorRead:
        @convention(c) (UnsafeMutableRawPointer?, UInt64, UnsafeMutablePointer<UInt8>?, Int) -> Int32 = {
            context, offset, output, count in
            guard let context, let output else { return 0 }
            return Unmanaged<DescriptorSource>.fromOpaque(context).takeUnretainedValue().read(
                offset: offset, output: output, count: count)
        }
    public final class DoclingPDFRasterSession: @unchecked Sendable {
        public let pageCount: Int64
        private let session: DoclingFileRasterSession
        fileprivate init(_ session: DoclingFileRasterSession) {
            self.session = session
            pageCount = session.pageCount
        }
        public func render(pageNumber: Int64) throws -> DocumentRasterPage {
            try session.render(pageNumber: pageNumber)
        }
        public func close() { session.close() }
    }
    /// Sessions serialize render/validate/close; close never frees an active C read
    /// callback. Worker cancellation retains Core's bounded terminate/reap path.
    public final class DoclingFileRasterSession: @unchecked Sendable {
        public let pageCount: Int64
        public let fileIdentity: NativeSourceFileIdentity
        private let lock = NSLock()
        private var source: DescriptorSource?
        private var handle: OpaquePointer?
        public static func open(at url: URL, mediaType: String, expected: NativeSourceFileIdentity?) throws
            -> DoclingFileRasterSession
        {
            let source = try DescriptorSource(at: url, expected: expected)
            let media = try DoclingRasterizer.media(source.prefix(), mediaType)
            var handle: OpaquePointer?
            var count: Int64 = 0
            let result = tdr_open(
                Unmanaged.passUnretained(source).toOpaque(), descriptorRead,
                UInt64(source.identity.byteCount), media, &handle, &count)
            do {
                try source.validate()
                try nativeStatus(result)
                guard let handle else { throw DoclingRasterError.decodingFailed }
                return DoclingFileRasterSession(source: source, handle: handle, count: count)
            } catch {
                if let handle { tdr_close(handle) }
                throw error
            }
        }
        private init(source: DescriptorSource, handle: OpaquePointer, count: Int64) {
            self.source = source
            self.handle = handle
            pageCount = count
            fileIdentity = source.identity
        }
        public func validateSource() throws {
            lock.lock()
            defer { lock.unlock() }
            guard let source else { throw DoclingRasterError.closedDocument }
            try source.validate()
        }
        public func render(pageNumber: Int64) throws -> DocumentRasterPage {
            lock.lock()
            defer { lock.unlock() }
            guard let source, let handle else { throw DoclingRasterError.closedDocument }
            guard pageNumber > 0, pageNumber <= pageCount else {
                throw DoclingRasterError.pageNumberOutOfRange
            }
            try source.validate()
            do {
                let page = try renderNative(handle, number: pageNumber)
                try source.validate()
                return page
            } catch {
                try source.validate()
                throw error
            }
        }
        public func close() {
            lock.lock()
            defer { lock.unlock() }
            if let handle { tdr_close(handle) }
            handle = nil
            source = nil
        }
        deinit { close() }
    }
#endif
