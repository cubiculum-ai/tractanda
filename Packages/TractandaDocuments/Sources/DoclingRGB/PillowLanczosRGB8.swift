import Foundation

/// The small RGB8 subset of Pillow 12.3.0's separable Lanczos resampler.
///
/// Attribution: behavior is derived from Pillow 12.3.0 `src/libImaging/Resample.c`
/// (MIT-CMU; see the retained experimental source-verification receipt).
/// PIL copyright 1997-2011 Secret Labs AB and1995-2011 Fredrik Lundh/contributors;
/// Pillow copyright2010 Jeffrey 'Alex' Clark/contributors. Full notices retained in
/// `ThirdPartyNotices/Pillow-LICENSE` in this package.
/// This is a Swift implementation, not copied C source. Pillow's 22-bit signed
/// coefficient quantization and round/clip to UInt8 after each axis are retained.
public enum PillowLanczosRGB8 {
    private static let precisionBits = 22
    private static let coefficientScale = 1 << precisionBits
    private static let halfCoefficientScale = 1 << (precisionBits - 1)
    private static let support = 3.0
    private static let maximumDimension = 2048

    private struct AxisCoefficients {
        let starts: [Int]
        let lengths: [Int]
        let values: [Int32]
        let taps: Int
    }

    /// Resampling entry point reserved for the tiny immutable Pillow fixtures.
    /// The model-facing Docling profile has its own strict 512-square admission.
    public static func resampleTinyFixture(
        _ image: PackedRGB8,
        toWidth: Int,
        toHeight: Int
    ) throws -> PackedRGB8 {
        guard image.width <= 64, image.height <= 64, toWidth > 0, toHeight > 0,
            toWidth <= 64, toHeight <= 64
        else {
            throw DoclingRGBError.unsupportedFixtureDimensions
        }
        return try resample(image, toWidth: toWidth, toHeight: toHeight)
    }

    static func resample(
        _ image: PackedRGB8,
        toWidth: Int,
        toHeight: Int
    ) throws -> PackedRGB8 {
        guard toWidth > 0, toHeight > 0,
            image.width <= maximumDimension, image.height <= maximumDimension,
            toWidth <= maximumDimension, toHeight <= maximumDimension
        else {
            throw DoclingRGBError.unsupportedPageDimensions(width: toWidth, height: toHeight)
        }
        _ = try PackedRGB8.byteCount(width: toWidth, height: toHeight)

        var currentBytes = image.bytes
        var currentWidth = image.width
        var currentHeight = image.height

        // Matches Pillow ImagingResampleInner: horizontal pass first.
        if currentWidth != toWidth {
            currentBytes = try resampleHorizontal(
                currentBytes, width: currentWidth, height: currentHeight, outputWidth: toWidth
            )
            currentWidth = toWidth
        }
        // The vertical pass consumes the rounded/clipped UInt8 horizontal result.
        if currentHeight != toHeight {
            currentBytes = try resampleVertical(
                currentBytes, width: currentWidth, height: currentHeight, outputHeight: toHeight
            )
            currentHeight = toHeight
        }
        return try PackedRGB8(width: currentWidth, height: currentHeight, bytes: currentBytes)
    }

    private static func resampleHorizontal(
        _ input: Data,
        width: Int,
        height: Int,
        outputWidth: Int
    ) throws -> Data {
        let table = try coefficients(inputSize: width, outputSize: outputWidth)
        let outputCount = try PackedRGB8.byteCount(width: outputWidth, height: height)
        var output = Data(count: outputCount)
        var accumulatorOverflowed = false

        input.withUnsafeBytes { sourceRaw in
            output.withUnsafeMutableBytes { destinationRaw in
                let source = sourceRaw.bindMemory(to: UInt8.self)
                let destination = destinationRaw.bindMemory(to: UInt8.self)
                for y in 0..<height {
                    for x in 0..<outputWidth {
                        let start = table.starts[x]
                        let count = table.lengths[x]
                        let coefficientBase = x * table.taps
                        for channel in 0..<3 {
                            var accumulator = Int64(halfCoefficientScale)
                            for tap in 0..<count {
                                let sourcePixel = (y * width + start + tap) * 3 + channel
                                let coefficientIndex = coefficientBase + tap
                                let product = Int64(source[sourcePixel]).multipliedReportingOverflow(
                                    by: Int64(table.values[coefficientIndex])
                                )
                                if product.overflow {
                                    accumulatorOverflowed = true
                                    return
                                }
                                let sum = accumulator.addingReportingOverflow(product.partialValue)
                                if sum.overflow {
                                    accumulatorOverflowed = true
                                    return
                                }
                                accumulator = sum.partialValue
                            }
                            let outputIndex = (y * outputWidth + x) * 3 + channel
                            destination[outputIndex] = clippedByte(accumulator)
                        }
                    }
                }
            }
        }
        if accumulatorOverflowed { throw DoclingRGBError.accumulatorOverflow }
        return output
    }

    private static func resampleVertical(
        _ input: Data,
        width: Int,
        height: Int,
        outputHeight: Int
    ) throws -> Data {
        let table = try coefficients(inputSize: height, outputSize: outputHeight)
        let outputCount = try PackedRGB8.byteCount(width: width, height: outputHeight)
        var output = Data(count: outputCount)
        var accumulatorOverflowed = false

        input.withUnsafeBytes { sourceRaw in
            output.withUnsafeMutableBytes { destinationRaw in
                let source = sourceRaw.bindMemory(to: UInt8.self)
                let destination = destinationRaw.bindMemory(to: UInt8.self)
                for y in 0..<outputHeight {
                    let start = table.starts[y]
                    let count = table.lengths[y]
                    let coefficientBase = y * table.taps
                    for x in 0..<width {
                        for channel in 0..<3 {
                            var accumulator = Int64(halfCoefficientScale)
                            for tap in 0..<count {
                                let sourcePixel = ((start + tap) * width + x) * 3 + channel
                                let coefficientIndex = coefficientBase + tap
                                let product = Int64(source[sourcePixel]).multipliedReportingOverflow(
                                    by: Int64(table.values[coefficientIndex])
                                )
                                if product.overflow {
                                    accumulatorOverflowed = true
                                    return
                                }
                                let sum = accumulator.addingReportingOverflow(product.partialValue)
                                if sum.overflow {
                                    accumulatorOverflowed = true
                                    return
                                }
                                accumulator = sum.partialValue
                            }
                            let outputIndex = (y * width + x) * 3 + channel
                            destination[outputIndex] = clippedByte(accumulator)
                        }
                    }
                }
            }
        }
        if accumulatorOverflowed { throw DoclingRGBError.accumulatorOverflow }
        return output
    }

    private static func coefficients(inputSize: Int, outputSize: Int) throws -> AxisCoefficients {
        guard inputSize > 0, outputSize > 0, inputSize <= maximumDimension, outputSize <= maximumDimension
        else {
            throw DoclingRGBError.invalidFilterCoefficients
        }
        let scale = Double(inputSize) / Double(outputSize)
        let filterScale = max(scale, 1.0)
        let scaledSupport = support * filterScale
        guard scaledSupport.isFinite, scaledSupport < Double(Int.max / 4) else {
            throw DoclingRGBError.arithmeticOverflow
        }
        let ceilSupport = Int(ceil(scaledSupport))
        let tapsProduct = ceilSupport.multipliedReportingOverflow(by: 2)
        guard !tapsProduct.overflow else { throw DoclingRGBError.arithmeticOverflow }
        let tapsResult = tapsProduct.partialValue.addingReportingOverflow(1)
        guard !tapsResult.overflow else { throw DoclingRGBError.arithmeticOverflow }
        let taps = tapsResult.partialValue
        let coefficientCount = outputSize.multipliedReportingOverflow(by: taps)
        guard !coefficientCount.overflow else { throw DoclingRGBError.arithmeticOverflow }
        let coefficientBytes = coefficientCount.partialValue.multipliedReportingOverflow(
            by: MemoryLayout<Int32>.stride)
        guard !coefficientBytes.overflow else { throw DoclingRGBError.arithmeticOverflow }
        guard coefficientBytes.partialValue <= 1024 * 1024 else {
            throw DoclingRGBError.invalidFilterCoefficients
        }
        let boundCount = outputSize.multipliedReportingOverflow(by: 2)
        guard !boundCount.overflow, boundCount.partialValue <= 2 * maximumDimension else {
            throw DoclingRGBError.arithmeticOverflow
        }

        var starts = [Int](repeating: 0, count: outputSize)
        var lengths = [Int](repeating: 0, count: outputSize)
        var values = [Int32](repeating: 0, count: coefficientCount.partialValue)
        let inverseFilterScale = 1.0 / filterScale

        for outputIndex in 0..<outputSize {
            let center = (Double(outputIndex) + 0.5) * scale
            let lower = center - scaledSupport + 0.5
            let upper = center + scaledSupport + 0.5
            guard lower.isFinite, upper.isFinite,
                lower > -Double(Int.max / 2), upper < Double(Int.max / 2)
            else {
                throw DoclingRGBError.arithmeticOverflow
            }
            // C's cast to int truncates toward zero; Swift's Int(Double) does likewise.
            var first = Int(lower)
            var last = Int(upper)
            first = max(first, 0)
            last = min(last, inputSize)
            guard last >= first else { throw DoclingRGBError.invalidFilterCoefficients }
            let count = last - first
            starts[outputIndex] = first
            lengths[outputIndex] = count

            var weights = [Double](repeating: 0.0, count: count)
            var weightSum = 0.0
            for tap in 0..<count {
                let coordinate = (Double(tap + first) - center + 0.5) * inverseFilterScale
                let weight = lanczos(coordinate)
                guard weight.isFinite else { throw DoclingRGBError.invalidFilterCoefficients }
                weights[tap] = weight
                weightSum += weight
            }
            guard weightSum.isFinite, weightSum != 0.0 else {
                throw DoclingRGBError.invalidFilterCoefficients
            }
            let coefficientBase = outputIndex * taps
            for tap in 0..<count {
                let normalized = weights[tap] / weightSum
                let scaled = normalized * Double(coefficientScale)
                guard scaled.isFinite, scaled >= Double(Int32.min) + 1, scaled <= Double(Int32.max) - 1 else {
                    throw DoclingRGBError.invalidFilterCoefficients
                }
                // Pillow rounds normalized signed coefficients to nearest, halves away from zero.
                let rounded = scaled < 0.0 ? scaled - 0.5 : scaled + 0.5
                let integer = Int64(rounded.rounded(.towardZero))
                guard integer >= Int64(Int32.min), integer <= Int64(Int32.max) else {
                    throw DoclingRGBError.invalidFilterCoefficients
                }
                values[coefficientBase + tap] = Int32(integer)
            }
            // Coefficient storage was zero-initialized, matching Pillow's empty tail taps.
        }
        return AxisCoefficients(starts: starts, lengths: lengths, values: values, taps: taps)
    }

    private static func lanczos(_ x: Double) -> Double {
        guard -3.0 <= x, x < 3.0 else { return 0.0 }
        return sinc(x) * sinc(x / 3.0)
    }

    private static func sinc(_ x: Double) -> Double {
        if x == 0.0 { return 1.0 }
        let angle = x * Double.pi
        return sin(angle) / angle
    }

    private static func clippedByte(_ accumulator: Int64) -> UInt8 {
        // Match Pillow's signed arithmetic shift and saturating 8-bit lookup.
        let shifted = accumulator >> precisionBits
        if shifted <= 0 { return 0 }
        if shifted >= 255 { return 255 }
        return UInt8(shifted)
    }
}
