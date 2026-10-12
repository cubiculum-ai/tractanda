import Foundation

/// Pure RGB implementation of the pinned Transformers 4.56.1 Idefics3 image
/// profile. Raster decoding, alpha compositing, and source geometry are handled
/// by the caller; this type starts with the already prepared content crop.
public enum DoclingRGBProfile {
    public static let pageSize = 512
    public static let enlargedSize = 2048
    public static let tileSize = 512
    public static let maximumPixels = 4_194_304

    /// Applies the official two-stage resize, splits into full row-major
    /// 512-square crops, appends the 512-square global view, and normalizes.
    /// Transformers first scales the longest edge to 2048, rounds the other
    /// edge up to even, then independently rounds both edges to 512 multiples.
    public static func prepareSinglePage(_ page: PackedRGB8) throws -> PreparedDoclingPage {
        guard page.width <= enlargedSize, page.height <= enlargedSize,
            page.width <= maximumPixels / page.height
        else {
            throw DoclingRGBError.unsupportedPageDimensions(width: page.width, height: page.height)
        }

        let firstSize = longestEdgeSize(width: page.width, height: page.height)
        let longestResized = try PillowLanczosRGB8.resample(
            page, toWidth: firstSize.width, toHeight: firstSize.height)
        let gridSize = visionEncoderSize(width: longestResized.width, height: longestResized.height)
        let enlarged = try PillowLanczosRGB8.resample(
            longestResized, toWidth: gridSize.width, toHeight: gridSize.height)

        let columns = enlarged.width / tileSize
        let rows = enlarged.height / tileSize
        guard columns > 0, rows > 0,
            enlarged.width.isMultiple(of: tileSize), enlarged.height.isMultiple(of: tileSize)
        else {
            throw DoclingRGBError.unsupportedPageDimensions(width: enlarged.width, height: enlarged.height)
        }

        let localCount = rows.multipliedReportingOverflow(by: columns)
        guard !localCount.overflow else { throw DoclingRGBError.arithmeticOverflow }
        let totalCount = localCount.partialValue.addingReportingOverflow(1)
        guard !totalCount.overflow else { throw DoclingRGBError.arithmeticOverflow }
        var tiles: [PackedRGB8] = []
        tiles.reserveCapacity(totalCount.partialValue)
        for row in 0..<rows {
            for column in 0..<columns {
                tiles.append(
                    try crop(
                        enlarged,
                        x: column * tileSize,
                        y: row * tileSize,
                        width: tileSize,
                        height: tileSize))
            }
        }
        tiles.append(try PillowLanczosRGB8.resample(enlarged, toWidth: tileSize, toHeight: tileSize))

        let normalized = try tiles.map(normalizedFloat32LE)
        return PreparedDoclingPage(
            enlargedImage: enlarged,
            roundedWidth: longestResized.width,
            roundedHeight: longestResized.height,
            tiles: tiles,
            normalizedTilesHWCFloat32LE: normalized,
            rows: rows,
            columns: columns,
            pixelAttentionMask: PixelAttentionMaskContract(imageCount: tiles.count, tileSize: tileSize))
    }

    /// Pixel-format-only normalization helper retained for the frozen byte
    /// golden. The model-facing path uses the same operation for each tile.
    public static func normalizeRGB8Float32LE(_ interleavedRGB8: Data) throws -> Data {
        guard interleavedRGB8.count <= tileSize * tileSize * 3 else {
            throw DoclingRGBError.normalizationInputTooLarge
        }
        guard interleavedRGB8.count.isMultiple(of: 3) else {
            throw DoclingRGBError.dataLengthMismatch(
                expected: (interleavedRGB8.count / 3) * 3, actual: interleavedRGB8.count)
        }
        return try normalizedFloat32LE(interleavedRGB8)
    }

    private static func longestEdgeSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let aspectRatio = Double(width) / Double(height)
        if width >= height {
            let resizedHeight = Int(Double(enlargedSize) / aspectRatio)
            return (enlargedSize, evenCeiling(resizedHeight))
        }
        let resizedWidth = Int(Double(enlargedSize) * aspectRatio)
        return (evenCeiling(resizedWidth), enlargedSize)
    }

    private static func visionEncoderSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let aspectRatio = Double(width) / Double(height)
        if width >= height {
            let resizedWidth = roundUpToTile(width)
            let resizedHeight = Int(Double(resizedWidth) / aspectRatio)
            return (resizedWidth, roundUpToTile(resizedHeight))
        }
        let resizedHeight = roundUpToTile(height)
        let resizedWidth = Int(Double(resizedHeight) * aspectRatio)
        return (roundUpToTile(resizedWidth), resizedHeight)
    }

    private static func evenCeiling(_ value: Int) -> Int {
        value.isMultiple(of: 2) ? value : value + 1
    }

    private static func roundUpToTile(_ value: Int) -> Int {
        ((value + tileSize - 1) / tileSize) * tileSize
    }

    private static func normalizedFloat32LE(_ image: PackedRGB8) throws -> Data {
        try normalizedFloat32LE(image.bytes)
    }

    private static func normalizedFloat32LE(_ rgb: Data) throws -> Data {
        let floatByteCount = rgb.count.multipliedReportingOverflow(by: MemoryLayout<Float>.stride)
        guard !floatByteCount.overflow else { throw DoclingRGBError.arithmeticOverflow }
        var output = Data(count: floatByteCount.partialValue)
        let scale = 0.00392156862745098
        rgb.withUnsafeBytes { sourceRaw in
            output.withUnsafeMutableBytes { destinationRaw in
                let source = sourceRaw.bindMemory(to: UInt8.self)
                let destination = destinationRaw.bindMemory(to: UInt8.self)
                for index in 0..<rgb.count {
                    // HF rescales in Float64, casts to Float32, then applies
                    // Float32 mean and standard deviation in channel order.
                    let rescaled = Float(Double(source[index]) * scale)
                    let centered = rescaled - Float(0.5)
                    let normalized = centered / Float(0.5)
                    let bits = normalized.bitPattern
                    let offset = index * 4
                    destination[offset] = UInt8(truncatingIfNeeded: bits)
                    destination[offset + 1] = UInt8(truncatingIfNeeded: bits >> 8)
                    destination[offset + 2] = UInt8(truncatingIfNeeded: bits >> 16)
                    destination[offset + 3] = UInt8(truncatingIfNeeded: bits >> 24)
                }
            }
        }
        return output
    }

    private static func crop(
        _ image: PackedRGB8,
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) throws -> PackedRGB8 {
        guard x >= 0, y >= 0, width > 0, height > 0,
            x <= image.width, y <= image.height,
            width <= image.width - x, height <= image.height - y
        else {
            throw DoclingRGBError.unsupportedPageDimensions(width: image.width, height: image.height)
        }
        let resultCount = try PackedRGB8.byteCount(width: width, height: height)
        let sourceStride = try PackedRGB8.byteCount(width: image.width, height: 1)
        let rowBytes = try PackedRGB8.byteCount(width: width, height: 1)
        var result = Data(count: resultCount)
        image.bytes.withUnsafeBytes { sourceRaw in
            result.withUnsafeMutableBytes { destinationRaw in
                let source = sourceRaw.bindMemory(to: UInt8.self)
                let destination = destinationRaw.bindMemory(to: UInt8.self)
                for row in 0..<height {
                    let sourceStart = (y + row) * sourceStride + x * 3
                    let destinationStart = row * rowBytes
                    for byte in 0..<rowBytes {
                        destination[destinationStart + byte] = source[sourceStart + byte]
                    }
                }
            }
        }
        return try PackedRGB8(width: width, height: height, bytes: result)
    }
}
