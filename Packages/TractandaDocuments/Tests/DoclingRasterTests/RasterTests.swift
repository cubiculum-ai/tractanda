import Foundation
import XCTest
import DoclingRaster

final class RasterTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    }
    func testOpaqueWhiteAlphaAndGeometry() throws {
        let pages = try DoclingRasterizer.rasterize(Data(contentsOf: fixture("alpha.png")), mediaType: "image/png")
        let page = try XCTUnwrap(pages.first)
        XCTAssertEqual(page.renderedCropBounds, [0, 0, 2048, 2048])
        XCTAssertEqual(page.geometry.sourceWidth, 1)
        XCTAssertTrue(page.rgb.bytes.allSatisfy { $0 == 255 })
    }
    func testPNGAndJPEGKeepTopDownRGB() throws {
        let png = try XCTUnwrap(DoclingRasterizer.rasterize(Data(contentsOf: fixture("rgb.png")), mediaType: "image/png").first)
        XCTAssertEqual(png.renderedCropBounds, [0, 512, 2048, 1536])
        XCTAssertEqual(png.rgb.width, 2048); XCTAssertEqual(png.rgb.height, 1024)
        let first = (png.rgb.height / 2 * png.rgb.width + png.rgb.width / 8) * 3
        let last = (png.rgb.height / 2 * png.rgb.width + png.rgb.width * 7 / 8) * 3
        XCTAssertGreaterThan(png.rgb.bytes[first], png.rgb.bytes[first + 2])
        XCTAssertGreaterThan(png.rgb.bytes[last + 2], png.rgb.bytes[last])
        let jpeg = try XCTUnwrap(DoclingRasterizer.rasterize(Data(contentsOf: fixture("gray.jpg")), mediaType: "image/jpeg").first)
        XCTAssertTrue(jpeg.rgb.bytes.allSatisfy { (127...129).contains($0) })
    }
    func testEmbeddedLinearICCIsConvertedToSRGB() throws {
        let page = try XCTUnwrap(DoclingRasterizer.rasterize(Data(contentsOf: fixture("linear-profile.png")), mediaType: "image/png").first)
        let center = (page.rgb.height / 2 * page.rgb.width + page.rgb.width / 2) * 3
        for channel in 0..<3 { XCTAssertTrue((185...190).contains(page.rgb.bytes[center + channel])) }
    }
    func testUnsupportedFramesOrientationAndMedia() throws {
        for (name, media) in [("orientation.png", "image/png"), ("orientation.jpg", "image/jpeg"), ("animated.png", "image/png")] {
            XCTAssertThrowsError(try DoclingRasterizer.rasterize(Data(contentsOf: fixture(name)), mediaType: media))
        }
        XCTAssertThrowsError(try DoclingRasterizer.rasterize(Data(contentsOf: fixture("gray.jpg")), mediaType: "image/png"))
        let truncated = try Data(contentsOf: fixture("rgb.png")).prefix(30)
        XCTAssertThrowsError(try DoclingRasterizer.rasterize(Data(truncated), mediaType: "image/png"))
    }
    func testLazyArbitraryPagesCropOriginRotationAndClose() throws {
        let session = try DoclingRasterizer.openPDF(at: fixture("three-pages.pdf"))
        defer { session.close() }
        XCTAssertEqual(session.pageCount, 3)
        let third = try session.render(pageNumber: 3)
        let second = try session.render(pageNumber: 2)
        let first = try session.render(pageNumber: 1)
        XCTAssertEqual(first.geometry.sourceOriginX, 10); XCTAssertEqual(first.geometry.sourceOriginY, 20)
        XCTAssertEqual(first.renderedCropBounds, [512, 0, 1536, 2048])
        XCTAssertEqual(second.geometry.sourceRotation, 90)
        XCTAssertEqual(second.geometry.displayWidth, 200); XCTAssertEqual(second.geometry.displayHeight, 100)
        XCTAssertEqual(second.renderedCropBounds, [0, 512, 2048, 1536])
        let center = (third.rgb.height / 2 * third.rgb.width + third.rgb.width / 2) * 3
        XCTAssertEqual(Array(third.rgb.bytes[center..<center + 3]), [0, 255, 0])
        XCTAssertThrowsError(try session.render(pageNumber: 0))
        XCTAssertThrowsError(try session.render(pageNumber: 4))
        session.close(); session.close()
        XCTAssertThrowsError(try session.render(pageNumber: 1))
        XCTAssertThrowsError(try DoclingRasterizer.rasterize(Data(contentsOf: fixture("three-pages.pdf")), mediaType: "application/pdf"))
    }
    func testNoFollowIdentityAndChangedDescriptor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("docling-raster-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.pdf"), link = root.appendingPathComponent("link.pdf")
        try FileManager.default.copyItem(at: fixture("three-pages.pdf"), to: original)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        XCTAssertThrowsError(try DoclingFileRasterSession.open(at: link, mediaType: "application/pdf", expected: nil))
        let session = try DoclingFileRasterSession.open(at: original, mediaType: "application/pdf", expected: nil)
        defer { session.close() }
        let identity = session.fileIdentity
        let foreign = NativeSourceFileIdentity(device: identity.device, inode: identity.inode ^ 1,
            byteCount: identity.byteCount, mode: identity.mode, uid: identity.uid, gid: identity.gid,
            modificationSeconds: identity.modificationSeconds, modificationNanoseconds: identity.modificationNanoseconds)
        XCTAssertThrowsError(try DoclingFileRasterSession.open(at: original, mediaType: "application/pdf", expected: foreign))
        let file = try FileHandle(forWritingTo: original); defer { try? file.close() }
        try file.truncate(atOffset: 1); try file.synchronize()
        XCTAssertThrowsError(try session.validateSource())
        XCTAssertThrowsError(try session.render(pageNumber: 1))
    }
}
