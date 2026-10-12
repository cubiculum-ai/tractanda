import DoclingRGB
import Foundation

private enum CheckFailure: Error, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case .invalid(let message): return message
        }
    }
}

private struct GoldenCase: Decodable {
    let name: String
    let sourceShapeHwc: [Int]
    let sourceRgb8Hex: String
    let sourceSha256: String
    let targetShapeHwc: [Int]
    let goldenRgb8Hex: String
    let goldenSha256: String

    enum CodingKeys: String, CodingKey {
        case name
        case sourceShapeHwc = "source_shape_hwc"
        case sourceRgb8Hex = "source_rgb8_hex"
        case sourceSha256 = "source_sha256"
        case targetShapeHwc = "target_shape_hwc"
        case goldenRgb8Hex = "golden_rgb8_hex"
        case goldenSha256 = "golden_sha256"
    }
}

private struct PillowGoldens: Decodable {
    let caseCount: Int
    let cases: [GoldenCase]

    enum CodingKeys: String, CodingKey {
        case caseCount = "case_count"
        case cases
    }
}

private struct NormalizationGoldens: Decodable {
    let inputShape: [Int]
    let inputRgb8Hex: String
    let inputSha256: String
    let outputShape: [Int]
    let outputF32leHex: String
    let outputSha256: String
    let all256ByteValuesEachChannel: [[String: String]]

    enum CodingKeys: String, CodingKey {
        case inputShape = "input_shape"
        case inputRgb8Hex = "input_rgb8_hex"
        case inputSha256 = "input_sha256"
        case outputShape = "output_shape"
        case outputF32leHex = "output_f32le_hex"
        case outputSha256 = "output_sha256"
        case all256ByteValuesEachChannel = "all256_byte_values_each_channel"
    }
}

private struct FixtureDescriptor: Decodable {
    let sha256: String
    let dimensions: [Int]
}

private struct TileDescriptor: Decodable {
    let path: String
    let bytes: Int
    let sha256: String
    let shape: [Int]
    let dtype: String
}

private struct PixelValuesManifest: Decodable {
    let shape: [Int]
    let dtype: String
    let tiles: [TileDescriptor]
}

private struct MaskDescriptor: Decodable {
    let path: String
    let bytes: Int
    let sha256: String
    let shape: [Int]
    let dtype: String
}

private struct PixelMaskManifest: Decodable {
    let shape: [Int]
    let allOnes: Bool
    let uniqueOfficialValues: [Int]
    let tiles: [MaskDescriptor]
}

private struct CropDescriptor: Decodable {
    let index: Int
    let role: String
    let row: Int?
    let column: Int?
}

private struct CropsManifest: Decodable {
    let rows: Int
    let columns: Int
    let actualProcessorImageCount: Int
    let order: [CropDescriptor]
}

private struct CountsManifest: Decodable {
    let imageToken: Int
    let fakeImageToken: Int
    let globalImageToken: Int
    let totalPromptTokens: Int
}

private struct TokenContract: Decodable {
    let modelVocabSize: Int
    let allIdsBelowModelVocab: Bool
}

private struct AttentionMaskManifest: Decodable {
    let path: String
    let bytes: Int
    let sha256: String
    let shape: [Int]
}

private struct OracleManifest: Decodable {
    let fixture: FixtureDescriptor
    let pixelValues: PixelValuesManifest
    let pixelAttentionMask: PixelMaskManifest
    let crops: CropsManifest
    let observedTokenCounts: CountsManifest
    let tokenContract: TokenContract
    let attentionMask: AttentionMaskManifest
}

private struct AttentionMask: Decodable {
    let shape: [Int]
    let dtype: String
    let data: [Int]
}

/// Small portable SHA-256 for verifying frozen reference files without platform crypto APIs.
private enum SHA256 {
    private static let constants: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4,
        0xab1c_5ed5,
        0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7,
        0xc19b_f174,
        0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc,
        0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351,
        0x1429_2967,
        0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e,
        0x9272_2c85,
        0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585,
        0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f,
        0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7,
        0xc671_78f2,
    ]

    static func hex(_ data: Data) -> String {
        var bytes = Array(data)
        let bitLength = UInt64(bytes.count) &* 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }

        var state: [UInt32] = [
            0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
            0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
        ]
        var schedule = Array(repeating: UInt32(0), count: 64)
        for base in stride(from: 0, to: bytes.count, by: 64) {
            for index in 0..<16 {
                let offset = base + index * 4
                schedule[index] =
                    UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
                    | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
            }
            for index in 16..<64 {
                let x = schedule[index - 15]
                let y = schedule[index - 2]
                let s0 = rotateRight(x, 7) ^ rotateRight(x, 18) ^ (x >> 3)
                let s1 = rotateRight(y, 17) ^ rotateRight(y, 19) ^ (y >> 10)
                schedule[index] = schedule[index - 16] &+ s0 &+ schedule[index - 7] &+ s1
            }

            var a = state[0]
            var b = state[1]
            var c = state[2]
            var d = state[3]
            var e = state[4]
            var f = state[5]
            var g = state[6]
            var h = state[7]
            for index in 0..<64 {
                let upper = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
                let choose = (e & f) ^ (~e & g)
                let first = h &+ upper &+ choose &+ constants[index] &+ schedule[index]
                let lower = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let second = lower &+ majority
                h = g
                g = f
                f = e
                e = d &+ first
                d = c
                c = b
                b = a
                a = first &+ second
            }
            state[0] &+= a
            state[1] &+= b
            state[2] &+= c
            state[3] &+= d
            state[4] &+= e
            state[5] &+= f
            state[6] &+= g
            state[7] &+= h
        }
        return state.map { String(format: "%08x", $0) }.joined()
    }

    private static func rotateRight(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }
}

private struct TileResult: Encodable, Equatable {
    let index: Int
    let role: String
    let rawRGBMatches: Bool
    let normalizedNCHWOracleMatches: Bool
}

private struct CheckReport: Encodable {
    let status: String
    let sourceRGBSha256: String
    let officialEnlargedRGBSha256: String
    let pillowGoldenCount: Int
    let imageCount: Int
    let localCropCount: Int
    let globalViewIndex: Int
    let allPixelMasksOne: Bool
    let tokenCounts: [String: Int]
    let checks: [String: Bool]
    let tiles: [TileResult]
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure.invalid(message) }
}

private func decodeHex(_ text: String) throws -> Data {
    guard text.utf8.count.isMultiple(of: 2) else { throw CheckFailure.invalid("Odd-length fixture hex") }
    var result = Data()
    result.reserveCapacity(text.utf8.count / 2)
    var index = text.startIndex
    while index < text.endIndex {
        let end = text.index(index, offsetBy: 2)
        guard let byte = UInt8(text[index..<end], radix: 16) else {
            throw CheckFailure.invalid("Invalid fixture hex")
        }
        result.append(byte)
        index = end
    }
    return result
}

private func readCapped(_ url: URL, maximumBytes: Int) throws -> Data {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
        let size = values.fileSize, size >= 0, size <= maximumBytes
    else { throw CheckFailure.invalid("Unsafe or oversized reference file: \(url.path)") }
    return try Data(contentsOf: url, options: .mappedIfSafe)
}

private func resolveUnder(_ root: URL, _ relativePath: String) throws -> URL {
    let components = relativePath.split(separator: "/")
    guard !relativePath.hasPrefix("/"), !components.contains("."), !components.contains("..") else {
        throw CheckFailure.invalid("Unsafe oracle path: \(relativePath)")
    }
    let url = root.appendingPathComponent(relativePath).standardizedFileURL
    guard url.path.hasPrefix(root.standardizedFileURL.path + "/") else {
        throw CheckFailure.invalid("Oracle path escaped its root")
    }
    return url
}

private func littleUInt32(_ data: Data, at offset: Int) -> UInt32 {
    UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16
        | UInt32(data[offset + 3]) << 24
}

private func transposeNCHWToHWC(_ input: Data) throws -> Data {
    let planeBytes = 512 * 512 * 4
    guard input.count == planeBytes * 3 else {
        throw CheckFailure.invalid("Oracle tile has an invalid byte length")
    }
    var output = Data(count: input.count)
    input.withUnsafeBytes { sourceRaw in
        output.withUnsafeMutableBytes { destinationRaw in
            let source = sourceRaw.bindMemory(to: UInt8.self)
            let destination = destinationRaw.bindMemory(to: UInt8.self)
            for pixel in 0..<(512 * 512) {
                for channel in 0..<3 {
                    let from = channel * planeBytes + pixel * 4
                    let to = pixel * 12 + channel * 4
                    destination[to] = source[from]
                    destination[to + 1] = source[from + 1]
                    destination[to + 2] = source[from + 2]
                    destination[to + 3] = source[from + 3]
                }
            }
        }
    }
    return output
}

private typealias RGBInverseMap = [[UInt32: UInt8]]

private func recoverRGB8(_ nchw: Data, inverseMap: RGBInverseMap) throws -> Data {
    guard nchw.count == 3 * 512 * 512 * 4 else { throw CheckFailure.invalid("Unexpected oracle F32 size") }
    var output = Data(count: 512 * 512 * 3)
    let planeBytes = 512 * 512 * 4
    nchw.withUnsafeBytes { sourceRaw in
        output.withUnsafeMutableBytes { destinationRaw in
            let source = sourceRaw.bindMemory(to: UInt8.self)
            let destination = destinationRaw.bindMemory(to: UInt8.self)
            for pixel in 0..<(512 * 512) {
                for channel in 0..<3 {
                    let from = channel * planeBytes + pixel * 4
                    let bits = littleUInt32(nchw, at: from)
                    guard let value = inverseMap[channel][bits] else { continue }
                    destination[pixel * 3 + channel] = value
                }
            }
        }
    }

    for pixel in 0..<(512 * 512) {
        for channel in 0..<3 {
            let offset = channel * planeBytes + pixel * 4
            let bits = littleUInt32(nchw, at: offset)
            guard inverseMap[channel][bits] != nil else {
                throw CheckFailure.invalid("Oracle contains a non-finite or unknown normalized RGB value")
            }
        }
    }
    return output
}

private func stitch(_ crop: Data, index: Int, into enlarged: inout Data) throws {
    guard (0..<16).contains(index), crop.count == 512 * 512 * 3,
        enlarged.count == 2048 * 2048 * 3
    else { throw CheckFailure.invalid("Invalid local crop to stitch") }
    let row = index / 4
    let column = index % 4
    let rowBytes = 512 * 3
    crop.withUnsafeBytes { cropRaw in
        enlarged.withUnsafeMutableBytes { destinationRaw in
            let source = cropRaw.bindMemory(to: UInt8.self)
            let destination = destinationRaw.bindMemory(to: UInt8.self)
            for y in 0..<512 {
                let sourceStart = y * rowBytes
                let destinationStart = ((row * 512 + y) * 2048 + column * 512) * 3
                for byte in 0..<rowBytes {
                    destination[destinationStart + byte] = source[sourceStart + byte]
                }
            }
        }
    }
}

private func testFrozenPillowGoldens(_ fixturesRoot: URL) throws -> Int {
    let data = try readCapped(
        fixturesRoot.appendingPathComponent("pillow-rgb-goldens.json"), maximumBytes: 64 * 1024)
    let decoder = JSONDecoder()
    let goldens = try decoder.decode(PillowGoldens.self, from: data)
    try require(
        goldens.caseCount == 9 && goldens.caseCount == goldens.cases.count, "Pillow golden inventory changed")
    var names = Set<String>()
    for fixture in goldens.cases {
        try require(names.insert(fixture.name).inserted, "Duplicate Pillow golden name")
        try require(
            fixture.sourceShapeHwc.count == 3 && fixture.targetShapeHwc.count == 3,
            "Malformed Pillow golden dimensions")
        let width = fixture.sourceShapeHwc[1]
        let height = fixture.sourceShapeHwc[0]
        let targetWidth = fixture.targetShapeHwc[1]
        let targetHeight = fixture.targetShapeHwc[0]
        try require(
            [width, height, targetWidth, targetHeight].allSatisfy { (1...64).contains($0) },
            "Pillow tiny golden exceeded its bounded dimensions")
        let source = try decodeHex(fixture.sourceRgb8Hex)
        let expected = try decodeHex(fixture.goldenRgb8Hex)
        try require(
            source.count == width * height * 3 && expected.count == targetWidth * targetHeight * 3,
            "Pillow golden byte shape mismatch")
        try require(
            SHA256.hex(source) == fixture.sourceSha256 && SHA256.hex(expected) == fixture.goldenSha256,
            "Pillow golden checksum mismatch")
        let image = try PackedRGB8(width: width, height: height, bytes: source)
        let actual = try PillowLanczosRGB8.resampleTinyFixture(
            image, toWidth: targetWidth, toHeight: targetHeight)
        try require(actual.bytes == expected, "Pillow RGB golden mismatch: \(fixture.name)")
    }
    return goldens.caseCount
}

private func testNormalizationGolden(_ fixturesRoot: URL) throws -> (NormalizationGoldens, RGBInverseMap) {
    let url = fixturesRoot.appendingPathComponent("hf-normalization-256-golden.json")
    let data = try readCapped(url, maximumBytes: 64 * 1024)
    let decoder = JSONDecoder()
    let golden = try decoder.decode(NormalizationGoldens.self, from: data)
    let source = try decodeHex(golden.inputRgb8Hex)
    let expected = try decodeHex(golden.outputF32leHex)
    try require(
        golden.inputShape == [1, 256, 3] && golden.outputShape == [1, 256, 3],
        "HF normalization golden shape mismatch")
    try require(source.count == 768 && expected.count == 256 * 3 * 4, "HF normalization golden size mismatch")
    let sourceBytes = Array(source)
    for channel in 0..<3 {
        let values = Set(stride(from: channel, to: sourceBytes.count, by: 3).map { sourceBytes[$0] })
        try require(
            values == Set(UInt8.min...UInt8.max),
            "HF input golden does not cover every byte in channel \(channel)")
    }
    try require(
        SHA256.hex(source) == golden.inputSha256 && SHA256.hex(expected) == golden.outputSha256,
        "HF normalization golden checksum mismatch")
    let normalized = try DoclingRGBProfile.normalizeRGB8Float32LE(source)
    try require(normalized == expected, "HF normalization operation-order golden mismatch")

    try require(golden.all256ByteValuesEachChannel.count == 3, "HF inverse map channel count mismatch")
    var inverse: RGBInverseMap = []
    for channel in 0..<3 {
        let mapping = golden.all256ByteValuesEachChannel[channel]
        try require(mapping.count == 256, "HF inverse map does not cover all component bytes")
        var channelMap: [UInt32: UInt8] = [:]
        for value in 0...255 {
            guard let hex = mapping[String(value)], let bits = UInt32(hex, radix: 16) else {
                throw CheckFailure.invalid("Missing HF normalized value in frozen inverse map")
            }
            try require(channelMap[bits] == nil, "HF normalization map is not injective")
            channelMap[bits] = UInt8(value)
        }
        inverse.append(channelMap)
    }
    return (golden, inverse)
}

private func verifyOracleManifest(_ manifest: OracleManifest) throws {
    try require(
        manifest.fixture.sha256 == "1956d09c22f6e5857d67dd14880e14f9b03802e9b40a236be0b6249587b82a0d"
            && manifest.fixture.dimensions == [512, 512], "Frozen RGB fixture identity changed")
    try require(
        manifest.pixelValues.shape == [1, 17, 3, 512, 512]
            && manifest.pixelValues.dtype == "float32-le" && manifest.pixelValues.tiles.count == 17,
        "Official pixel values count or shape changed")
    try require(
        manifest.crops.rows == 4 && manifest.crops.columns == 4
            && manifest.crops.actualProcessorImageCount == 17 && manifest.crops.order.count == 17,
        "Official crop grid or image count changed")
    for index in 0..<17 {
        let tile = manifest.pixelValues.tiles[index]
        try require(
            tile.path == String(format: "tiles/tile-%02d.f32le", index)
                && tile.shape == [3, 512, 512] && tile.bytes == 3 * 512 * 512 * 4
                && tile.dtype == "float32-le", "Official tile descriptor/order mismatch at \(index)")
        let order = manifest.crops.order[index]
        if index < 16 {
            try require(
                order.index == index && order.role == "local_crop"
                    && order.row == index / 4 + 1 && order.column == index % 4 + 1,
                "Official local crop order mismatch at \(index)")
        } else {
            try require(
                order.index == 16 && order.role == "global_view"
                    && order.row == nil && order.column == nil, "Global view is not the final tile")
        }
    }
    let mask = manifest.pixelAttentionMask
    try require(
        mask.shape == [1, 17, 512, 512] && mask.allOnes && mask.uniqueOfficialValues == [1]
            && mask.tiles.count == 17, "Official pixel attention mask contract changed")
    for (index, descriptor) in mask.tiles.enumerated() {
        try require(
            descriptor.path == String(format: "tiles/mask-%02d.u8", index)
                && descriptor.bytes == 512 * 512 && descriptor.shape == [512, 512]
                && descriptor.dtype == "uint8", "Official mask descriptor/order mismatch")
    }
    let counts = manifest.observedTokenCounts
    try require(
        counts.imageToken == 1088 && counts.fakeImageToken == 18
            && counts.globalImageToken == 1 && counts.totalPromptTokens == 1142,
        "Official image token counts changed")
    try require(
        manifest.tokenContract.modelVocabSize == 100352
            && manifest.tokenContract.allIdsBelowModelVocab, "Official token id bound changed")
}

private func verifyOracleMasks(root: URL, manifest: OracleManifest) throws -> Bool {
    var allMasksOne = true
    for descriptor in manifest.pixelAttentionMask.tiles {
        let url = try resolveUnder(root, descriptor.path)
        let data = try readCapped(url, maximumBytes: 512 * 512)
        try require(
            data.count == descriptor.bytes && SHA256.hex(data) == descriptor.sha256,
            "Frozen oracle pixel mask changed: \(descriptor.path)")
        allMasksOne = allMasksOne && data.allSatisfy { $0 == 1 }
    }
    let maskDescriptor = manifest.attentionMask
    let maskData = try readCapped(try resolveUnder(root, maskDescriptor.path), maximumBytes: 64 * 1024)
    try require(
        maskData.count == maskDescriptor.bytes && SHA256.hex(maskData) == maskDescriptor.sha256,
        "Frozen oracle attention mask changed")
    let attention = try JSONDecoder().decode(AttentionMask.self, from: maskData)
    try require(
        attention.dtype == "int64" && attention.shape == [1, 1142]
            && attention.data.count == 1142 && attention.data.allSatisfy { $0 == 1 },
        "Full official token attention mask is not all ones")
    return allMasksOne
}

private func comparePrepared(
    _ prepared: PreparedDoclingPage,
    oracleRoot: URL,
    manifest: OracleManifest,
    inverseMap: RGBInverseMap
) throws -> ([TileResult], Data) {
    try require(
        prepared.tiles.count == 17 && prepared.normalizedTilesHWCFloat32LE.count == 17,
        "Prepared image count does not equal 16 local crops plus the global view")
    try require(prepared.rows == 4 && prepared.columns == 4, "Prepared row-major grid dimensions changed")
    try require(
        prepared.pixelAttentionMask.shape == [1, 17, 512, 512]
            && prepared.pixelAttentionMask.value == 1 && prepared.pixelAttentionMask.allValuesEqualOne,
        "Prepared pixel attention mask metadata changed")
    try require(
        prepared.tiles.allSatisfy { $0.width == 512 && $0.height == 512 },
        "Prepared tile dimensions changed")

    var report: [TileResult] = []
    var expectedEnlarged = Data(count: 2048 * 2048 * 3)
    for index in 0..<17 {
        let descriptor = manifest.pixelValues.tiles[index]
        let oracle = try readCapped(
            try resolveUnder(oracleRoot, descriptor.path), maximumBytes: descriptor.bytes)
        try require(
            oracle.count == descriptor.bytes && SHA256.hex(oracle) == descriptor.sha256,
            "Frozen oracle F32 tile changed: \(descriptor.path)")
        let rawExpected = try recoverRGB8(oracle, inverseMap: inverseMap)
        let normalizedExpected = try transposeNCHWToHWC(oracle)
        let rawMatches = rawExpected == prepared.tiles[index].bytes
        let normalizedMatches = normalizedExpected == prepared.normalizedTilesHWCFloat32LE[index]
        try require(rawMatches && normalizedMatches, "Prepared RGB/F32 tile differs at index \(index)")
        if index < 16 { try stitch(rawExpected, index: index, into: &expectedEnlarged) }
        report.append(
            TileResult(
                index: index, role: manifest.crops.order[index].role,
                rawRGBMatches: rawMatches, normalizedNCHWOracleMatches: normalizedMatches))
    }
    return (report, expectedEnlarged)
}

private func verifyBoundaryRejections() throws -> [String: Bool] {
    var result: [String: Bool] = [:]
    do {
        _ = try PackedRGB8(width: 1, height: 1, bytes: Data([1, 2]))
        result["short_byte_length"] = false
    } catch DoclingRGBError.dataLengthMismatch { result["short_byte_length"] = true }
    do {
        _ = try PackedRGB8(width: Int.max, height: 2, bytes: Data())
        result["dimension_product_overflow"] = false
    } catch DoclingRGBError.arithmeticOverflow { result["dimension_product_overflow"] = true }
    do {
        let unsupported = try PackedRGB8(width: 2049, height: 1, bytes: Data(repeating: 0, count: 2049 * 3))
        _ = try DoclingRGBProfile.prepareSinglePage(unsupported)
        result["dimension_above_2048_rejected"] = false
    } catch DoclingRGBError.unsupportedPageDimensions { result["unsupported_profile_before_resize"] = true }
    do {
        _ = try DoclingRGBProfile.normalizeRGB8Float32LE(Data(repeating: 0, count: 512 * 512 * 3 + 3))
        result["normalization_over_limit"] = false
    } catch DoclingRGBError.normalizationInputTooLarge { result["normalization_over_limit"] = true }
    do {
        _ = try DoclingRGBProfile.normalizeRGB8Float32LE(Data([1, 2, 3, 4]))
        result["normalization_non_rgb_length"] = false
    } catch DoclingRGBError.dataLengthMismatch { result["normalization_non_rgb_length"] = true }
    try require(
        result.count == 5 && result.values.allSatisfy { $0 }, "One or more bounded admission guards failed")
    return result
}

/// A cheap API contract check for the official variable-grid path. Inputs are
/// tiny RGB samples; only the profile's bounded 2048-scale outputs are created.
private func verifyRectangularProfileSelfTest() throws -> [String: Bool] {
    let cases: [(width: Int, height: Int, expectedWidth: Int, expectedHeight: Int, expectedImages: Int)] = [
        // 2048 / (3 / 2) truncates to 1365, rounds to even 1366, then to 1536.
        (3, 2, 2048, 1536, 13),
        (2, 3, 1536, 2048, 13),
        (2, 1, 2048, 1024, 9),
    ]
    var checks: [String: Bool] = [:]
    for fixture in cases {
        let source = try PackedRGB8(
            width: fixture.width, height: fixture.height,
            bytes: Data(repeating: 127, count: fixture.width * fixture.height * 3))
        let prepared = try DoclingRGBProfile.prepareSinglePage(source)
        let key = "\(fixture.width)x\(fixture.height)_official_grid"
        checks[key] =
            prepared.enlargedImage.width == fixture.expectedWidth
            && prepared.enlargedImage.height == fixture.expectedHeight
            && prepared.columns == fixture.expectedWidth / 512
            && prepared.rows == fixture.expectedHeight / 512
            && prepared.tiles.count == fixture.expectedImages
            && prepared.normalizedTilesHWCFloat32LE.count == fixture.expectedImages
            && prepared.pixelAttentionMask.shape == [1, fixture.expectedImages, 512, 512]
            && prepared.pixelAttentionMask.value == 1
            && prepared.pixelAttentionMask.allValuesEqualOne
            && prepared.tiles.allSatisfy { $0.width == 512 && $0.height == 512 }
    }
    try require(
        checks.count == cases.count && checks.values.allSatisfy { $0 },
        "Official rectangular RGB profile contract self-test failed")
    return checks
}

private func runChecks(smokeRoot: URL) throws -> CheckReport {
    let nativeRoot = smokeRoot.appendingPathComponent("native-preprocessing-20261007", isDirectory: true)
    let fixtureRoot = nativeRoot.appendingPathComponent("fixtures", isDirectory: true)
    let referenceRoot = smokeRoot.deletingLastPathComponent()
        .appendingPathComponent("docling-reference-preprocessing-20261007/oracle", isDirectory: true)
    let pillowGoldenCount = try testFrozenPillowGoldens(fixtureRoot)
    let (_, inverseMap) = try testNormalizationGolden(fixtureRoot)
    let sourceURL = smokeRoot.appendingPathComponent("precision-20261007/preparation/raw-rgb-u8.bin")
    let source = try readCapped(sourceURL, maximumBytes: 4 * 1024 * 1024)
    try require(
        source.count == 512 * 512 * 3
            && SHA256.hex(source) == "c7b9e37f61a4e2359a5d9923c70804def8d66605c3a3cd2e14aef82176a139ff",
        "Frozen original 512 RGB source changed")
    let manifestData = try readCapped(
        referenceRoot.appendingPathComponent("manifest.json"), maximumBytes: 256 * 1024)
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let manifest = try decoder.decode(OracleManifest.self, from: manifestData)
    try verifyOracleManifest(manifest)
    let allMasksOne = try verifyOracleMasks(root: referenceRoot, manifest: manifest)
    try require(allMasksOne, "Frozen pixel attention mask contains a zero")

    let sourcePage = try PackedRGB8(width: 512, height: 512, bytes: source)
    let prepared512 = try DoclingRGBProfile.prepareSinglePage(sourcePage)
    let (tileResults512, officialEnlarged) = try comparePrepared(
        prepared512, oracleRoot: referenceRoot, manifest: manifest, inverseMap: inverseMap)
    try require(
        prepared512.enlargedImage.bytes == officialEnlarged
            && SHA256.hex(officialEnlarged)
                == "a5fac20ded8cd67d4e9308c32ea7cbf49ad2743f11990cbd471978e502d855fb",
        "The 512 input path did not reproduce the official 2048 image assembled from frozen crops")

    let directInput = try PackedRGB8(width: 2048, height: 2048, bytes: officialEnlarged)
    let prepared2048 = try DoclingRGBProfile.prepareSinglePage(directInput)
    try require(
        prepared2048.enlargedImage.bytes == officialEnlarged,
        "The direct 2048 path modified its admitted canvas")
    let (tileResults2048, directEnlarged) = try comparePrepared(
        prepared2048, oracleRoot: referenceRoot, manifest: manifest, inverseMap: inverseMap)
    try require(
        directEnlarged == officialEnlarged, "Direct 2048 crop reconstruction differs from input canvas")
    try require(
        tileResults512 == tileResults2048, "The 512 and direct 2048 paths differ against the same oracle")
    let boundaries = try verifyBoundaryRejections()

    let checks = [
        "512 path matches all 17 official crops and global view": tileResults512.count == 17,
        "direct 2048 path matches all 17 official crops and global view": tileResults2048.count == 17,
        "2048 raster exactly matches stitched frozen official row-major crops": SHA256.hex(officialEnlarged)
            == "a5fac20ded8cd67d4e9308c32ea7cbf49ad2743f11990cbd471978e502d855fb",
        "all 17 pixel masks contain only one": allMasksOne,
        "full language attention mask shape and values are verified": true,
        "old Pillow 12.3 RGB and HF F32 goldens pass": pillowGoldenCount == 9,
        "bounded invalid dimensions, length, overflow, and normalization reject": boundaries.values.allSatisfy
        { $0 },
    ]
    try require(checks.values.allSatisfy { $0 }, "One or more direct RGB profile checks failed")
    return CheckReport(
        status: "pass", sourceRGBSha256: SHA256.hex(source),
        officialEnlargedRGBSha256: SHA256.hex(officialEnlarged), pillowGoldenCount: pillowGoldenCount,
        imageCount: tileResults2048.count, localCropCount: 16, globalViewIndex: 16,
        allPixelMasksOne: allMasksOne,
        tokenCounts: [
            "image": manifest.observedTokenCounts.imageToken,
            "fakeImage": manifest.observedTokenCounts.fakeImageToken,
            "globalImage": manifest.observedTokenCounts.globalImageToken,
            "prompt": manifest.observedTokenCounts.totalPromptTokens,
        ],
        checks: checks, tiles: tileResults2048)
}

@main
private struct DoclingRGBCheckMain {
    static func main() {
        do {
            if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--profile-contract-self-test" {
                let checks = try verifyRectangularProfileSelfTest()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(checks), as: UTF8.self))
                return
            }
            guard CommandLine.arguments.count == 2 else {
                throw CheckFailure.invalid(
                    "Usage: docling-rgb-check <docling-smoke-root> | --profile-contract-self-test")
            }
            let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
            let report = try runChecks(smokeRoot: root)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
        } catch {
            FileHandle.standardError.write(Data("DoclingRGBCheck failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
