#if !os(Linux)
    import CoreGraphics
    import Darwin
    import Foundation
    import ImageIO

    /// The provider retains this owner until all Core Graphics references have gone away.
    private final class DescriptorSource: @unchecked Sendable {
        let fd: Int32
        let identity: NativeSourceFileIdentity
        private let lock = NSLock()
        private var readFailed = false
        private var changed = false
        private let url: URL
        private let scoped: Bool

        static func metadata(_ fd: Int32) throws -> NativeSourceFileIdentity {
            var value = stat()
            guard fstat(fd, &value) == 0, value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                value.st_size > 0
            else { throw DoclingRasterError.fileAccessFailed }
            return NativeSourceFileIdentity(
                device: UInt64(truncatingIfNeeded: value.st_dev), inode: value.st_ino,
                byteCount: value.st_size, mode: UInt32(value.st_mode), uid: value.st_uid, gid: value.st_gid,
                modificationSeconds: Int64(value.st_mtimespec.tv_sec),
                modificationNanoseconds: Int32(value.st_mtimespec.tv_nsec))
        }
        init(at url: URL, expected: NativeSourceFileIdentity?) throws {
            guard url.isFileURL, !url.path.contains("\0") else { throw DoclingRasterError.fileAccessFailed }
            let scoped = url.startAccessingSecurityScopedResource()
            let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else {
                if scoped { url.stopAccessingSecurityScopedResource() }
                throw DoclingRasterError.fileAccessFailed
            }
            let identity: NativeSourceFileIdentity
            do {
                identity = try Self.metadata(fd)
                if let expected, expected != identity { throw DoclingRasterError.sourceIdentityMismatch }
            } catch {
                Darwin.close(fd)
                if scoped { url.stopAccessingSecurityScopedResource() }
                throw error
            }
            self.fd = fd
            self.identity = identity
            self.url = url
            self.scoped = scoped
        }
        deinit {
            Darwin.close(fd)
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        func validate() throws {
            lock.lock()
            let failed = readFailed
            let invalidated = changed
            lock.unlock()
            guard !failed else { throw DoclingRasterError.sourceReadFailed }
            guard !invalidated else { throw DoclingRasterError.sourceChanged }
            guard try Self.metadata(fd) == identity else {
                lock.lock()
                changed = true
                lock.unlock()
                throw DoclingRasterError.sourceChanged
            }
        }
        private func fail() {
            lock.lock()
            readFailed = true
            lock.unlock()
        }
        func read(into buffer: UnsafeMutableRawPointer, position: Int64, count: Int) -> Int {
            guard position >= 0, count >= 0 else {
                fail()
                return 0
            }
            if position >= identity.byteCount || count == 0 { return 0 }
            let amount = Int(min(Int64(count), identity.byteCount - position))
            var completed = 0
            while completed < amount {
                let part = min(262_144, amount - completed)
                let next = position.addingReportingOverflow(Int64(completed))
                guard !next.overflow else {
                    fail()
                    return completed
                }
                let value = pread(fd, buffer.advanced(by: completed), part, off_t(next.partialValue))
                if value < 0 && errno == EINTR { continue }
                guard value > 0 else {
                    fail()
                    return completed
                }
                completed += value
            }
            return completed
        }
        func prefix() throws -> Data {
            var bytes = [UInt8](repeating: 0, count: Int(min(32, identity.byteCount)))
            let count = bytes.withUnsafeMutableBytes {
                read(into: $0.baseAddress!, position: 0, count: $0.count)
            }
            try validate()
            return Data(bytes.prefix(count))
        }
        func provider() throws -> CGDataProvider {
            let info = Unmanaged.passRetained(self).toOpaque()
            var callbacks = CGDataProviderDirectCallbacks(
                version: 0, getBytePointer: nil, releaseBytePointer: nil,
                getBytesAtPosition: { info, buffer, position, count in
                    guard let info else { return 0 }
                    return Unmanaged<DescriptorSource>.fromOpaque(info).takeUnretainedValue()
                        .read(into: buffer, position: Int64(position), count: count)
                },
                releaseInfo: { info in
                    if let info { Unmanaged<DescriptorSource>.fromOpaque(info).release() }
                })
            guard
                let provider = CGDataProvider(
                    directInfo: info, size: off_t(identity.byteCount), callbacks: &callbacks)
            else {
                Unmanaged<DescriptorSource>.fromOpaque(info).release()
                throw DoclingRasterError.decodingFailed
            }
            return provider
        }
    }

    /// One retained descriptor, one parser, one selected raster; no original Data or page array.
    public final class DoclingFileRasterSession: @unchecked Sendable {
        private enum Contents {
            case pdf(CGPDFDocument)
            case image(CGImageSource, (width: Int, height: Int)?)
        }
        public let pageCount: Int64
        public let fileIdentity: NativeSourceFileIdentity
        private let lock = NSLock()
        private var source: DescriptorSource?
        private var contents: Contents?
        private let mediaType: String

        public static func open(
            at url: URL, mediaType: String, expected: NativeSourceFileIdentity?
        ) throws -> DoclingFileRasterSession {
            let source = try DescriptorSource(at: url, expected: expected)
            let prefix = try source.prefix()
            let provider = try source.provider()
            let contents: Contents
            let count: Int64
            switch mediaType {
            case "application/pdf":
                guard DoclingRasterizer.hasPDFSignature(prefix) else {
                    throw DoclingRasterError.mediaTypeMismatch
                }
                guard let document = CGPDFDocument(provider) else {
                    try source.validate()
                    throw DoclingRasterError.malformedInput
                }
                guard !document.isEncrypted else { throw DoclingRasterError.encryptedPDF }
                guard document.numberOfPages > 0 else { throw DoclingRasterError.emptyPDF }
                guard let checked = Int64(exactly: document.numberOfPages) else {
                    throw DoclingRasterError.unsupportedPDFPageCount
                }
                count = checked
                contents = .pdf(document)
            case "image/png", "image/jpeg":
                let header: (width: Int, height: Int)?
                if mediaType == "image/png" {
                    guard DoclingRasterizer.hasPNGSignature(prefix) else {
                        throw DoclingRasterError.mediaTypeMismatch
                    }
                    header = try DoclingRasterizer.pngDimensions(prefix)
                    try DoclingRasterizer.validateDimensions(width: header!.width, height: header!.height)
                } else {
                    guard DoclingRasterizer.hasJPEGSignature(prefix) else {
                        throw DoclingRasterError.mediaTypeMismatch
                    }
                    header = nil
                }
                guard let image = CGImageSourceCreateWithDataProvider(provider, nil) else {
                    try source.validate()
                    throw DoclingRasterError.malformedInput
                }
                guard CGImageSourceGetCount(image) == 1 else {
                    throw DoclingRasterError.unsupportedFrameCount
                }
                count = 1
                contents = .image(image, header)
            default: throw DoclingRasterError.unsupportedMediaType
            }
            try source.validate()
            return DoclingFileRasterSession(
                source: source, mediaType: mediaType, contents: contents, pageCount: count)
        }
        private init(source: DescriptorSource, mediaType: String, contents: Contents, pageCount: Int64) {
            self.source = source
            self.mediaType = mediaType
            self.contents = contents
            self.pageCount = pageCount
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
            guard let source, let contents else { throw DoclingRasterError.closedDocument }
            guard pageNumber > 0, pageNumber <= pageCount, let number = Int(exactly: pageNumber) else {
                throw DoclingRasterError.pageNumberOutOfRange
            }
            try source.validate()
            let page: DocumentRasterPage
            switch contents {
            case .pdf(let document):
                guard let pdfPage = document.page(at: number) else { throw DoclingRasterError.malformedInput }
                page = try DoclingRasterizer.rasterizePDFPage(pdfPage, pageNumber: number)
            case .image(let image, let header):
                page = try DoclingRasterizer.rasterizeImageSource(
                    image, mediaType: mediaType, pngHeader: header)
            }
            try source.validate()
            return page
        }
        public func close() {
            lock.lock()
            defer { lock.unlock() }
            contents = nil
            source = nil
        }
        deinit { close() }
    }

#endif
