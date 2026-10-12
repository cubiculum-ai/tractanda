import Foundation

/// Errors from the deliberately narrow, pure-RGB preprocessing core.
public enum DoclingRGBError: Error, Equatable, CustomStringConvertible {
    case nonPositiveDimensions
    case arithmeticOverflow
    case dataLengthMismatch(expected: Int, actual: Int)
    case unsupportedPageDimensions(width: Int, height: Int)
    case unsupportedFixtureDimensions
    case normalizationInputTooLarge
    case invalidFilterCoefficients
    case accumulatorOverflow

    public var description: String {
        switch self {
        case .nonPositiveDimensions:
            return "RGB dimensions must be positive"
        case .arithmeticOverflow:
            return "RGB buffer length overflow"
        case .dataLengthMismatch(let expected, let actual):
            return "RGB8 byte count mismatch: expected \(expected), got \(actual)"
        case .unsupportedPageDimensions(let width, let height):
            return "Docling RGB profile admits positive images up to 2048x2048; got \(width)x\(height)"
        case .unsupportedFixtureDimensions:
            return "Tiny Pillow fixture resampling is capped at 64x64"
        case .normalizationInputTooLarge:
            return "RGB normalization buffer is larger than one 512x512 tile"
        case .invalidFilterCoefficients:
            return "Pillow-compatible resampling coefficients are invalid"
        case .accumulatorOverflow:
            return "RGB resampling accumulator overflow"
        }
    }
}

/// An immutable, tightly packed, interleaved RGB8 image. Alpha and color-profile
/// conversion are intentionally absent from this value type.
public struct PackedRGB8: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let bytes: Data

    public init(width: Int, height: Int, bytes: Data) throws {
        guard width > 0, height > 0 else {
            throw DoclingRGBError.nonPositiveDimensions
        }
        let pixels = width.multipliedReportingOverflow(by: height)
        guard !pixels.overflow else { throw DoclingRGBError.arithmeticOverflow }
        let byteCount = pixels.partialValue.multipliedReportingOverflow(by: 3)
        guard !byteCount.overflow else { throw DoclingRGBError.arithmeticOverflow }
        guard bytes.count == byteCount.partialValue else {
            throw DoclingRGBError.dataLengthMismatch(expected: byteCount.partialValue, actual: bytes.count)
        }
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    public static func byteCount(width: Int, height: Int) throws -> Int {
        guard width > 0, height > 0 else { throw DoclingRGBError.nonPositiveDimensions }
        let pixels = width.multipliedReportingOverflow(by: height)
        guard !pixels.overflow else { throw DoclingRGBError.arithmeticOverflow }
        let bytes = pixels.partialValue.multipliedReportingOverflow(by: 3)
        guard !bytes.overflow else { throw DoclingRGBError.arithmeticOverflow }
        return bytes.partialValue
    }
}

/// Compact metadata for the official full-one image masks. Pixel payloads are
/// RGB-only; the native bridge may materialize the mask from this contract.
public struct PixelAttentionMaskContract: Sendable, Equatable {
    public let shape: [Int]
    public let value: UInt8
    public let allValuesEqualOne: Bool

    init(imageCount: Int, tileSize: Int) {
        self.shape = [1, imageCount, tileSize, tileSize]
        self.value = 1
        self.allValuesEqualOne = true
    }
}

/// Prepared values for one official Granite-Docling image and its variable grid.
public struct PreparedDoclingPage: Sendable {
    public let enlargedImage: PackedRGB8
    /// Dimensions after longest-edge resize and even short-side rounding,
    /// before the separate 512-pixel vision-grid rounding stage.
    public let roundedWidth: Int
    public let roundedHeight: Int
    /// Row-major 512-square local crops followed by the global view.
    public let tiles: [PackedRGB8]
    /// Exact official HF normalization, serialized Float32 little-endian HWC.
    public let normalizedTilesHWCFloat32LE: [Data]
    public let rows: Int
    public let columns: Int
    public let pixelAttentionMask: PixelAttentionMaskContract

}
