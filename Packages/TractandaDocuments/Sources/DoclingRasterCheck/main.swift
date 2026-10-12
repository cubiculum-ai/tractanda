import CoreGraphics
import CryptoKit
import Darwin
import DoclingRGB
import DoclingRaster
import Foundation
import TractandaClient

private enum CheckFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case .assertion(let message): message
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure.assertion(message) }
}

private func expectError(
    _ expected: DoclingRasterError,
    _ label: String,
    operation: () throws -> Void
) throws {
    do {
        try operation()
        throw CheckFailure.assertion("\(label): expected \(expected)")
    } catch let error as DoclingRasterError {
        guard error == expected else {
            throw CheckFailure.assertion("\(label): expected \(expected), received \(error)")
        }
    }
}

private func expectRejectionOtherThan(
    _ unexpected: DoclingRasterError,
    _ label: String,
    operation: () throws -> Void
) throws {
    do {
        try operation()
        throw CheckFailure.assertion("\(label): malformed fixture unexpectedly decoded")
    } catch let error as DoclingRasterError {
        guard error != unexpected else {
            throw CheckFailure.assertion("\(label): was rejected before metadata validation")
        }
    }
}

private func read(_ name: String, from directory: URL) throws -> Data {
    try Data(contentsOf: directory.appendingPathComponent(name))
}

private func pixel(_ image: PackedRGB8, x: Int, y: Int) -> [UInt8] {
    let offset = (y * image.width + x) * 3
    return Array(image.bytes[offset..<(offset + 3)])
}

private func isNear(_ actual: [UInt8], _ expected: [UInt8], tolerance: Int = 3) -> Bool {
    actual.count == expected.count
        && zip(actual, expected).allSatisfy {
            abs(Int($0) - Int($1)) <= tolerance
        }
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func colorBounds(_ image: PackedRGB8, target: [UInt8]?) -> [String: Int] {
    let bytes = Array(image.bytes)
    var left = image.width
    var top = image.height
    var right = -1
    var bottom = -1
    var count = 0
    for y in 0..<image.height {
        for x in 0..<image.width {
            let start = (y * image.width + x) * 3
            let hit: Bool
            if let target {
                hit = (0..<3).allSatisfy { abs(Int(bytes[start + $0]) - Int(target[$0])) <= 4 }
            } else {
                hit = (0..<3).contains { bytes[start + $0] < 245 }
            }
            if hit {
                left = min(left, x)
                top = min(top, y)
                right = max(right, x)
                bottom = max(bottom, y)
                count += 1
            }
        }
    }
    return ["left": left, "top": top, "right": right, "bottom": bottom, "pixels": count]
}

private func byteRangePNG(width: UInt32, height: UInt32) -> Data {
    var data = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    ])
    for value in [width, height] {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
    return data
}

/// Tiny deterministic PDF builder for hostile geometry/page-count cases. The
/// content marks asymmetric crop corners so 90-degree rotation is observable.
private func tinyPDF(
    mediaBox: [String] = ["0", "0", "400", "500"],
    cropBox: [String] = ["0", "0", "400", "500"],
    rotation: Int? = nil,
    pageCount: Int = 1,
    pageColors: [Int: String] = [:]
) -> Data {
    var objects: [Int: String] = [:]
    let pageIDs = (0..<pageCount).map { 3 + $0 * 2 }
    objects[1] = "<< /Type /Catalog /Pages 2 0 R >>"
    objects[2] =
        "<< /Type /Pages /Count \(pageCount) /Kids [\(pageIDs.map { "\($0) 0 R" }.joined(separator: " "))] >>"
    for pageID in pageIDs {
        let contentID = pageID + 1
        let rotationPart = rotation.map { " /Rotate \($0)" } ?? ""
        let pageNumber = ((pageID - 3) / 2) + 1
        let firstColor = pageColors[pageNumber] ?? "1 0 0 rg"
        let content = "\(firstColor) 10 20 20 20 re f\n0 0 1 rg 150 250 20 20 re f\n"
        objects[pageID] =
            "<< /Type /Page /Parent 2 0 R /MediaBox [\(mediaBox.joined(separator: " "))] /CropBox [\(cropBox.joined(separator: " "))]\(rotationPart) /Resources << >> /Contents \(contentID) 0 R >>"
        objects[contentID] = "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream"
    }

    var document = "%PDF-1.4\n"
    var offsets = [0]
    for objectID in 1...objects.count {
        offsets.append(document.utf8.count)
        document += "\(objectID) 0 obj\n\(objects[objectID] ?? "null")\nendobj\n"
    }
    let xrefOffset = document.utf8.count
    document += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
    for offset in offsets.dropFirst() {
        document += String(format: "%010d 00000 n \n", offset)
    }
    document += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
    return Data(document.utf8)
}

private func requireFixtureCapacity(at directory: URL, estimatedBytes: Int) throws {
    let fixtureCap = 4 * 1024 * 1024
    let reserve: UInt64 = 10 * 1024 * 1024 * 1024
    let existing = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    var logicalBytes = 0
    var physicalBytes = 0
    var seen: Set<String> = []
    for file in existing {
        var metadata = stat()
        guard lstat(file.path, &metadata) == 0,
            metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            let logical = Int(exactly: metadata.st_size), logical >= 0,
            let blocks = Int(exactly: metadata.st_blocks), blocks >= 0
        else {
            throw CheckFailure.assertion("synthetic fixture accounting requires regular nonsymlink files")
        }
        let logicalSum = logicalBytes.addingReportingOverflow(logical)
        try require(!logicalSum.overflow, "fixture logical count is representable")
        logicalBytes = logicalSum.partialValue
        if seen.insert("\(metadata.st_dev):\(metadata.st_ino)").inserted {
            let allocated = blocks.multipliedReportingOverflow(by: 512)
            let physicalSum = physicalBytes.addingReportingOverflow(allocated.partialValue)
            try require(
                !allocated.overflow && !physicalSum.overflow,
                "fixture physical count is representable")
            physicalBytes = physicalSum.partialValue
        }
    }
    try require(
        estimatedBytes >= 0 && estimatedBytes <= fixtureCap - logicalBytes,
        "synthetic PDF estimate keeps logical fixtures within the 4 MiB cap")
    let estimatedPhysicalBytes = ((estimatedBytes + 16_383) / 16_384) * 16_384
    try require(
        estimatedPhysicalBytes <= fixtureCap - physicalBytes,
        "synthetic PDF estimate keeps physical fixtures within the 4 MiB cap")
    var filesystem = statvfs()
    guard statvfs(directory.path, &filesystem) == 0,
        let blocks = UInt64(exactly: filesystem.f_bavail),
        let blockSize = UInt64(exactly: filesystem.f_frsize), blockSize > 0
    else {
        throw CheckFailure.assertion("could not determine genuine free capacity for synthetic PDF")
    }
    let available = blocks.multipliedReportingOverflow(by: blockSize)
    try require(
        !available.overflow && available.partialValue >= reserve + UInt64(estimatedPhysicalBytes),
        "synthetic PDF requires 10 GiB genuine-free reserve")
}

private func displayToSourcePDF(_ u: Double, _ v: Double, geometry: DocumentPageGeometry) -> (Double, Double)
{
    let width = geometry.sourceWidth
    let height = geometry.sourceHeight
    switch geometry.sourceRotation {
    case 0:
        return (geometry.sourceOriginX + u, geometry.sourceOriginY + height - v)
    case 90:
        return (geometry.sourceOriginX + v, geometry.sourceOriginY + u)
    case 180:
        return (geometry.sourceOriginX + width - u, geometry.sourceOriginY + v)
    default:
        return (geometry.sourceOriginX + width - v, geometry.sourceOriginY + height - u)
    }
}

private func run(_ directory: URL, scratch: URL) throws {
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let generated = scratch.appendingPathComponent("fixtures", isDirectory: true)
    try require(
        !FileManager.default.fileExists(atPath: generated.path),
        "refusing to overwrite generated synthetic fixtures")
    try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)

    let retainedData = try read("retained-sample.png", from: directory)
    let retained = try DoclingRasterizer.rasterize(retainedData, mediaType: "image/png")
    try require(retained.count == 1, "retained RGB512 sample page count")
    try require(
        retained[0].geometry.sourceWidth == 512 && retained[0].geometry.sourceHeight == 512,
        "retained sample source geometry")
    try require(
        retained[0].rgb.width == 2048 && retained[0].rgb.height == 2048,
        "retained sample fixed canvas")
    try require(
        retained[0].geometry.contentLeft == 0 && retained[0].geometry.contentTop == 0,
        "square source fills canvas")

    let alphaData = try read("paragraph-alpha.png", from: directory)
    let alphaPage = try DoclingRasterizer.rasterize(alphaData, mediaType: "image/png")[0]
    let alphaGeometry = alphaPage.geometry
    try require(
        alphaGeometry.sourceWidth == 640 && alphaGeometry.sourceHeight == 320,
        "rectangular input dimensions")
    try require(
        alphaGeometry.canvasWidth == 2048 && alphaGeometry.canvasHeight == 1024
            && alphaGeometry.contentLeft == 0 && alphaGeometry.contentTop == 0
            && alphaGeometry.contentWidth == 2048 && alphaGeometry.contentHeight == 1024,
        "content crop retains aspect-preserving rectangular geometry")
    try require(pixel(alphaPage.rgb, x: 20, y: 20) == [255, 255, 255], "opaque white page background")
    let diagnostics: [String: Any] = [
        "sourceSHA256": digest(alphaData),
        "expectedAnchor": pixel(alphaPage.rgb, x: 189, y: 202),
        "verticallyMirroredAnchor": pixel(alphaPage.rgb, x: 189, y: 821),
        "expectedRed": pixel(alphaPage.rgb, x: 110, y: 288),
        "verticallyMirroredRed": pixel(alphaPage.rgb, x: 110, y: 735),
    ]
    try JSONSerialization.data(withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys])
        .write(to: scratch.appendingPathComponent("alpha-pixel-diagnostic.json"), options: .atomic)
    try require(
        isNear(pixel(alphaPage.rgb, x: 189, y: 202), [142, 227, 162], tolerance: 10),
        "half-alpha source anchor is composited on white")
    try require(isNear(pixel(alphaPage.rgb, x: 110, y: 288), [210, 30, 30]), "left red anchor orientation")
    try require(
        isNear(pixel(alphaPage.rgb, x: 1930, y: 288), [30, 30, 210]), "right blue anchor orientation")

    let pdfData = try read("portrait-landscape.pdf", from: directory)
    let pdfPages = try DoclingRasterizer.rasterize(pdfData, mediaType: "application/pdf")
    try require(pdfPages.count == 2, "two-page PDF output count")
    // Frozen C controls: changing the fit render or dropping fractional edge
    // samples would invalidate the controlled preprocessing comparison.
    let controls: [(DocumentRasterPage, String, String)] = [
        (
            alphaPage,
            "0e78b47dceeb9971f72dfdc26ee0bceaecc5b3417a176ca1883df34d9c6225f5",
            "9564fec8db4ccfbace4d00c75b911346093652aa7cab97124abef45c379653ca"
        ),
        (
            pdfPages[0],
            "e9fdb24fd1e8fded3f837ce366f7dfe4a7dc84fbf0f57f286f9e50f5a3edfbe9",
            "25810512a2c8258573501353c91a069e397d875a92ecddd29c42137bf691650c"
        ),
        (
            pdfPages[1],
            "7658d6e2c819938dc7ff5a63448f31c229a7eeab536d5c324080e4df27b040ef",
            "30b349b705ccc0f7e65ef45d85208e799de5129a2ffd4bd532c25412b5cb77be"
        ),
    ]
    for (page, renderedHash, croppedHash) in controls {
        try require(page.renderedCanvasSHA256 == renderedHash, "fixed render matches frozen control")
        try require(digest(page.rgb.bytes) == croppedHash, "content crop matches frozen C control")
        try page.geometry.validateContentCrop()
    }

    // Exercise the new file-backed session on the same frozen PDF bytes. This
    // proves its selected-page rendering retains the established C controls.
    let baselinePDFURL = generated.appendingPathComponent("portrait-landscape-file-backed.pdf")
    try requireFixtureCapacity(at: generated, estimatedBytes: pdfData.count)
    try pdfData.write(to: baselinePDFURL, options: .atomic)
    let baselineSession = try DoclingRasterizer.openPDF(at: baselinePDFURL)
    try require(baselineSession.pageCount == 2, "file-backed page count uses checked Int64")
    let filePage1 = try baselineSession.render(pageNumber: 1)
    try require(
        filePage1.renderedCanvasSHA256 == controls[1].1, "file-backed first page keeps frozen render hash")
    try require(digest(filePage1.rgb.bytes) == controls[1].2, "file-backed first page keeps frozen crop hash")
    let filePage2 = try baselineSession.render(pageNumber: 2)
    try require(
        filePage2.renderedCanvasSHA256 == controls[2].1, "file-backed second page keeps frozen render hash")
    try require(
        digest(filePage2.rgb.bytes) == controls[2].2, "file-backed second page keeps frozen crop hash")
    try expectError(.pageNumberOutOfRange, "file-backed zero page") {
        _ = try baselineSession.render(pageNumber: 0)
    }
    try expectError(.pageNumberOutOfRange, "file-backed page beyond document") {
        _ = try baselineSession.render(pageNumber: 3)
    }
    try expectError(.pageNumberOutOfRange, "file-backed maximum Int64 page") {
        _ = try baselineSession.render(pageNumber: .max)
    }
    try expectError(.pageNumberOutOfRange, "file-backed negative page") {
        _ = try baselineSession.render(pageNumber: -1)
    }
    baselineSession.close()
    baselineSession.close()
    try expectError(.closedDocument, "closed file-backed session") {
        _ = try baselineSession.render(pageNumber: 1)
    }

    // A deliberately small 128-page synthetic PDF proves inspection and lazy
    // random page access without creating a raster array or running inference.
    let pageTotal = 128
    let estimate = 512 + pageTotal * 512
    try requireFixtureCapacity(at: generated, estimatedBytes: estimate)
    let multiPageBytes = tinyPDF(
        pageCount: pageTotal,
        pageColors: [1: "1 0 0 rg", 64: "0 1 0 rg", 128: "0 0 1 rg"])
    try require(
        multiPageBytes.count <= estimate && multiPageBytes.count <= 4 * 1024 * 1024,
        "128-page generated fixture remains within estimated 4 MiB cap")
    let multiPageURL = generated.appendingPathComponent("synthetic-128-page.pdf")
    try multiPageBytes.write(to: multiPageURL, options: .atomic)
    let multiPageSession = try DoclingRasterizer.openPDF(at: multiPageURL)
    try require(multiPageSession.pageCount == 128, "128-page PDF inspection has no small-document cap")

    func pageAnchor(_ number: Int64, color: [UInt8]) throws -> String {
        let raster = try multiPageSession.render(pageNumber: number)
        let bounds = colorBounds(raster.rgb, target: color)
        try require(bounds["pixels"] ?? 0 > 0, "selected page contains its distinct color anchor")
        return digest(raster.rgb.bytes)
    }
    let firstDigest = try pageAnchor(1, color: [255, 0, 0])
    let middleDigest = try pageAnchor(64, color: [0, 255, 0])
    let lastDigest = try pageAnchor(128, color: [0, 0, 255])
    try require(
        Set([firstDigest, middleDigest, lastDigest]).count == 3,
        "first, middle, and last pages render distinct selected content")
    multiPageSession.close()

    let emptyPDF = generated.appendingPathComponent("empty.pdf")
    let emptyBytes = tinyPDF(pageCount: 0)
    try requireFixtureCapacity(at: generated, estimatedBytes: emptyBytes.count)
    try emptyBytes.write(to: emptyPDF, options: .atomic)
    let emptyPDFRejection: DoclingRasterError
    do {
        _ = try DoclingRasterizer.openPDF(at: emptyPDF)
        throw CheckFailure.assertion("zero-page file-backed PDF unexpectedly opened")
    } catch let error as DoclingRasterError {
        // Core Graphics may reject the empty page tree before exposing a document
        // with zero pages. Both paths must reject it without a render or inference.
        try require(
            error == .emptyPDF || error == .malformedInput,
            "zero-page file-backed PDF must fail at decode or page-count admission")
        emptyPDFRejection = error
    }
    try expectError(.encryptedPDF, "encrypted file-backed PDF") {
        _ = try DoclingRasterizer.openPDF(at: directory.appendingPathComponent("encrypted-negative.pdf"))
    }
    try expectError(.fileAccessFailed, "missing file-backed PDF") {
        _ = try DoclingRasterizer.openPDF(at: generated.appendingPathComponent("missing.pdf"))
    }
    let portrait = pdfPages[0].geometry
    try require(
        portrait.sourceWidth == 612 && portrait.sourceHeight == 792
            && portrait.displayWidth == 612 && portrait.displayHeight == 792
            && portrait.sourceUnit == "pdfPoint" && portrait.sourceRotation == 0,
        "portrait PDF source and display geometry")
    try require(
        portrait.canvasWidth == 1584 && portrait.canvasHeight == 2048
            && abs(portrait.contentLeft - 0.7272727273) < 0.000001 && portrait.contentTop == 0
            && abs(portrait.contentWidth - 1582.5454545455) < 0.000001
            && abs(portrait.contentHeight - 2048) < 0.000001,
        "portrait PDF outward crop without source distortion")
    let landscapePage = pdfPages[1].geometry
    try require(
        landscapePage.sourceWidth == 792 && landscapePage.sourceHeight == 612
            && landscapePage.displayWidth == 792 && landscapePage.displayHeight == 612,
        "landscape PDF source orientation")
    try require(
        landscapePage.canvasWidth == 2048 && landscapePage.canvasHeight == 1584
            && landscapePage.contentLeft == 0 && abs(landscapePage.contentTop - 0.7272727273) < 0.00001
            && abs(landscapePage.contentWidth - 2048) < 0.000001
            && abs(landscapePage.contentHeight - 1582.5454545455) < 0.00001,
        "landscape PDF outward crop without source distortion")
    let pdfDiagnostic: [String: Any] = [
        "inputSHA256": digest(pdfData),
        "portraitExpectedRed": pixel(pdfPages[0].rgb, x: 134, y: 190),
        "portraitMirroredRed": pixel(pdfPages[0].rgb, x: 134, y: 1857),
        "portraitExpectedBlue": pixel(pdfPages[0].rgb, x: 1412, y: 250),
        "portraitMirroredBlue": pixel(pdfPages[0].rgb, x: 1412, y: 1797),
        "landscapeExpectedRed": pixel(pdfPages[1].rgb, x: 122, y: 168),
        "landscapeMirroredRed": pixel(pdfPages[1].rgb, x: 122, y: 1415),
        "landscapeExpectedBlue": pixel(pdfPages[1].rgb, x: 1270, y: 418),
        "landscapeMirroredBlue": pixel(pdfPages[1].rgb, x: 1270, y: 1165),
        "portraitNonwhiteBounds": colorBounds(pdfPages[0].rgb, target: nil),
        "portraitRedBounds": colorBounds(pdfPages[0].rgb, target: [184, 32, 32]),
        "portraitBlueBounds": colorBounds(pdfPages[0].rgb, target: [30, 48, 184]),
        "landscapeNonwhiteBounds": colorBounds(pdfPages[1].rgb, target: nil),
        "landscapeRedBounds": colorBounds(pdfPages[1].rgb, target: [184, 32, 32]),
        "landscapeBlueBounds": colorBounds(pdfPages[1].rgb, target: [30, 48, 184]),
        "drawingTransforms": (1...2).map { number -> [Double] in
            let provider = CGDataProvider(data: pdfData as CFData)!
            let document = CGPDFDocument(provider)!
            let geometry = pdfPages[number - 1].geometry
            let rect = CGRect(
                x: geometry.contentLeft,
                y: Double(geometry.canvasHeight) - geometry.contentTop - geometry.contentHeight,
                width: geometry.contentWidth, height: geometry.contentHeight)
            let t = document.page(at: number)!.getDrawingTransform(
                .cropBox, rect: rect, rotate: 0, preserveAspectRatio: true)
            return [Double(t.a), Double(t.b), Double(t.c), Double(t.d), Double(t.tx), Double(t.ty)]
        },
    ]
    let checkerHash = digest(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0])))
    let diagnosticURL = scratch.appendingPathComponent(
        "pdf-pixel-diagnostic-" + checkerHash.prefix(12) + ".json")
    try require(
        !FileManager.default.fileExists(atPath: diagnosticURL.path), "refusing PDF diagnostic overwrite")
    try JSONSerialization.data(withJSONObject: pdfDiagnostic, options: [.prettyPrinted, .sortedKeys])
        .write(to: diagnosticURL, options: .atomic)
    try require(
        isNear(pixel(pdfPages[0].rgb, x: 134, y: 190), [184, 32, 32], tolerance: 6),
        "portrait PDF remains upright")
    try require(
        isNear(pixel(pdfPages[0].rgb, x: 1412, y: 250), [30, 48, 184], tolerance: 6),
        "portrait PDF right-side anchor")
    // Anchor coordinates subtract only the integer synthetic margin crop;
    // fractional edge samples remain in the source raster.
    try require(
        isNear(pixel(pdfPages[1].rgb, x: 122, y: 168), [184, 32, 32], tolerance: 6),
        "landscape PDF remains upright")
    try require(
        isNear(pixel(pdfPages[1].rgb, x: 1270, y: 418), [30, 48, 184], tolerance: 6),
        "landscape PDF right-side anchor")

    let rotatedData = tinyPDF(cropBox: ["10", "20", "210", "320"], rotation: 90)
    let fractionalData = tinyPDF(
        mediaBox: ["0", "0", "400", "500"], cropBox: ["10.25", "20.5", "210.75", "320.25"])
    let fractional = try DoclingRasterizer.rasterize(fractionalData, mediaType: "application/pdf")[0].geometry
    try require(
        fractional.sourceWidth == 200.5 && fractional.sourceHeight == 299.75
            && fractional.sourceOriginX == 10.25 && fractional.sourceOriginY == 20.5,
        "fractional PDF crop geometry remains exact")
    let rotatedPage = try DoclingRasterizer.rasterize(rotatedData, mediaType: "application/pdf")[0]
    let rotated = rotatedPage.geometry
    try require(
        rotated.sourceWidth == 200 && rotated.sourceHeight == 300
            && rotated.sourceOriginX == 10 && rotated.sourceOriginY == 20
            && rotated.sourceRotation == 90 && rotated.displayWidth == 300 && rotated.displayHeight == 200,
        "rotated non-zero crop-box geometry")
    try require(
        isNear(pixel(rotatedPage.rgb, x: 68, y: 68), [255, 0, 0], tolerance: 8),
        "rotated crop lower-left mark maps near upright top-left")
    try require(
        isNear(pixel(rotatedPage.rgb, x: 1638, y: 1024), [0, 0, 255], tolerance: 8),
        "rotated crop upper-right mark maps near upright lower-right")
    let pdfSource = displayToSourcePDF(42, 71, geometry: rotated)
    let inverseScale = rotated.scale
    let canvasX = rotated.contentLeft + 42 * inverseScale
    let canvasY = rotated.contentTop + 71 * inverseScale
    let recoveredU = (canvasX - rotated.contentLeft) / inverseScale
    let recoveredV = (canvasY - rotated.contentTop) / inverseScale
    let recovered = displayToSourcePDF(recoveredU, recoveredV, geometry: rotated)
    try require(
        abs(recovered.0 - pdfSource.0) < 0.000001 && abs(recovered.1 - pdfSource.1) < 0.000001,
        "upright canvas to original crop inverse mapping")

    try expectError(.inputTooLarge, "byte admission") {
        _ = try DoclingRasterizer.rasterize(
            Data(repeating: 0, count: DoclingRasterizer.maximumInputBytes + 1),
            mediaType: "image/png")
    }
    try expectError(.unsupportedMediaType, "unsupported MIME") {
        _ = try DoclingRasterizer.rasterize(Data([1]), mediaType: "image/gif")
    }
    try expectError(.mediaTypeMismatch, "magic/MIME mismatch") {
        _ = try DoclingRasterizer.rasterize(alphaData, mediaType: "image/jpeg")
    }
    try expectError(.dimensionsExceeded, "hostile PNG width metadata") {
        _ = try DoclingRasterizer.rasterize(byteRangePNG(width: 2049, height: 1), mediaType: "image/png")
    }
    try expectError(.dimensionsExceeded, "hostile PNG height metadata") {
        _ = try DoclingRasterizer.rasterize(byteRangePNG(width: 1, height: 2049), mediaType: "image/png")
    }
    try expectRejectionOtherThan(.dimensionsExceeded, "maximum-pixel PNG metadata reaches decode boundary") {
        _ = try DoclingRasterizer.rasterize(byteRangePNG(width: 2048, height: 2048), mediaType: "image/png")
    }
    try expectError(.unsupportedOrientation, "EXIF orientation 6") {
        _ = try DoclingRasterizer.rasterize(
            try read("orientation-6-negative.jpg", from: directory), mediaType: "image/jpeg")
    }
    try expectError(.unsupportedFrameCount, "animated PNG") {
        _ = try DoclingRasterizer.rasterize(
            try read("animated-negative.png", from: directory), mediaType: "image/png")
    }
    try expectError(.decodingFailed, "truncated JPEG") {
        _ = try DoclingRasterizer.rasterize(Data([0xFF, 0xD8, 0xFF]), mediaType: "image/jpeg")
    }
    try expectError(.encryptedPDF, "encrypted PDF") {
        _ = try DoclingRasterizer.rasterize(
            try read("encrypted-negative.pdf", from: directory), mediaType: "application/pdf")
    }
    try expectError(.unsupportedPDFPageCount, "three-page PDF") {
        _ = try DoclingRasterizer.rasterize(tinyPDF(pageCount: 3), mediaType: "application/pdf")
    }
    try expectError(.unsupportedPDFGeometry, "unsupported PDF rotation") {
        _ = try DoclingRasterizer.rasterize(tinyPDF(rotation: 45), mediaType: "application/pdf")
    }
    try expectError(.unsupportedPDFGeometry, "zero-size PDF crop box") {
        _ = try DoclingRasterizer.rasterize(
            tinyPDF(cropBox: ["0", "0", "0", "50"]), mediaType: "application/pdf")
    }
    try expectError(.unsupportedPDFGeometry, "oversized PDF crop box") {
        _ = try DoclingRasterizer.rasterize(
            tinyPDF(
                mediaBox: ["0", "0", "200000", "100000"],
                cropBox: ["0", "0", "100001", "50"]),
            mediaType: "application/pdf"
        )
    }
    try expectError(.unsupportedPDFGeometry, "out-of-range PDF crop origin") {
        _ = try DoclingRasterizer.rasterize(
            tinyPDF(
                mediaBox: ["0", "0", "200000", "100000"],
                cropBox: ["100001", "0", "100201", "50"]),
            mediaType: "application/pdf"
        )
    }
    try expectError(.malformedInput, "malformed PDF") {
        _ = try DoclingRasterizer.rasterize(Data("%PDF-not-a-document".utf8), mediaType: "application/pdf")
    }

    let retainedHash = digest(retainedData)
    let alphaHash = digest(alphaData)
    let pdfHash = digest(pdfData)
    let receipt: [String: Any] = [
        "fixtureManifestSHA256": digest(try read("fixture-manifest.json", from: directory)),
        "sourceSHA256": ["retainedSample": retainedHash, "paragraphAlpha": alphaHash, "twoPagePDF": pdfHash],
        "rasterSHA256": [
            "retainedSample": digest(retained[0].rgb.bytes),
            "paragraphAlpha": digest(alphaPage.rgb.bytes),
            "pdfPage1": digest(pdfPages[0].rgb.bytes),
            "pdfPage2": digest(pdfPages[1].rgb.bytes),
            "rotatedCroppedPage": digest(rotatedPage.rgb.bytes),
        ],
        "checks": [
            "opaque-content-crop", "fixed-render-before-outward-crop", "alpha-white-composition",
            "image-orientation-and-anchor-pixels", "single-frame-and-metadata-admission",
            "pdf-page-count-encryption-box-rotation", "upright-top-left-geometry-inverse",
            "crop-origin-preservation", "malformed-input-rejection",
        ],
        "inferenceRun": false,
    ]
    let receiptData = try JSONSerialization.data(
        withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
    let largeDocumentReceipt: [String: Any] = [
        "baselinePDFSHA256": digest(pdfData),
        "synthetic128PagePDFSHA256": digest(multiPageBytes),
        "synthetic128PageBytes": multiPageBytes.count,
        "inspectedPages": 128,
        "renderedPages": [1, 64, 128],
        "renderedPageHashes": [firstDigest, middleDigest, lastDigest],
        "zeroPagePDFRejection": emptyPDFRejection.description,
        "closedAndOutOfRangeRejected": true,
        "encryptedPDFRejected": true,
        "fixtureLogicalAndPhysicalCapBytes": 4 * 1024 * 1024,
        "inferenceRun": false,
    ]
    try JSONSerialization.data(withJSONObject: largeDocumentReceipt, options: [.prettyPrinted, .sortedKeys])
        .write(to: scratch.appendingPathComponent("lazy-pdf-check.json"), options: .atomic)
    try receiptData.write(to: scratch.appendingPathComponent("raster-check-receipt.json"), options: .atomic)
    print("DoclingRasterCheck passed; no inference was run.")
    print("receipt: \(scratch.appendingPathComponent("raster-check-receipt.json").path)")
}

do {
    let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
        .standardizedFileURL
    let scratch = URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ".")
        .standardizedFileURL
    try run(root, scratch: scratch)
    if CommandLine.arguments.count > 3 {
        let protocolDirectory = URL(fileURLWithPath: CommandLine.arguments[3])
        try checkNativeProtocol(protocolDirectory, scratch: scratch)
        let largePDF = CommandLine.arguments.count > 4 ? URL(fileURLWithPath: CommandLine.arguments[4]) : nil
        try checkDescriptorSource(root, scratch: scratch, largePDF: largePDF)
        print("Native protocol and retained-descriptor checks passed; no model was loaded.")
    }
} catch {
    fputs("DoclingRasterCheck failed: \(error)\n", stderr)
    exit(EXIT_FAILURE)
}
