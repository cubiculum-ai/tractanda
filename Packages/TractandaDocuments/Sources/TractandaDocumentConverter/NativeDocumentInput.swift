import CryptoKit
import DoclingRGB
import Foundation
import MLX
import MLXLMCommon
import TractandaClient

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw TractandaError("documentConverter", message) }
}

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func writeJSON(_ object: Any, _ url: URL) throws {
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        .write(to: url, options: .atomic)
}

func float32LE(_ array: MLXArray) -> Data {
    let values = array.asType(.float32).asArray(Float.self)
    var data = Data()
    data.reserveCapacity(values.count * 4)
    for value in values {
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }
    return data
}

struct NativeDocumentInput: UserInputProcessor {
    let tokenizer: any Tokenizer
    let traceDirectory: URL?
    let comparisonDirectory: URL?

    func prepare(input: UserInput) async throws -> LMInput {
        try require(input.images.count == 1, "One opaque RGB page is required.")
        guard case .array(let rgb) = input.images[0] else {
            throw TractandaError("documentConverter", "A packed RGB array is required.")
        }
        try require(
            rgb.dtype == .uint8 && rgb.ndim == 3 && rgb.shape[2] == 3
                && (1...2048).contains(rgb.shape[0]) && (1...2048).contains(rgb.shape[1]),
            "Unsupported model input shape.")
        let raw = Data(rgb.asArray(UInt8.self))
        let page = try DoclingRGBProfile.prepareSinglePage(
            PackedRGB8(width: rgb.shape[1], height: rgb.shape[0], bytes: raw))
        try require(
            (1...4).contains(page.rows) && (1...4).contains(page.columns)
                && page.tiles.count == page.rows * page.columns + 1
                && page.pixelAttentionMask.allValuesEqualOne
                && page.pixelAttentionMask.shape == [1, page.tiles.count, 512, 512],
            "Invalid full-mask tiling.")
        var arrays: [MLXArray] = []
        for data in page.normalizedTilesHWCFloat32LE {
            let floats = data.withUnsafeBytes { buffer in
                (0..<(data.count / 4)).map {
                    Float(
                        bitPattern: UInt32(
                            littleEndian: buffer.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)))
                }
            }
            arrays.append(MLXArray(floats).reshaped(512, 512, 3))
        }
        let pixels = stacked(arrays).asType(.bfloat16)
        eval(pixels)
        try require(
            pixels.shape == [page.tiles.count, 512, 512, 3] && all(isFinite(pixels)).item(Bool.self),
            "Invalid prepared pixels.")
        let task = "Convert this page to docling."
        let messages: [[String: any Sendable]] = [
            ["role": "user", "content": [["type": "image"], ["type": "text", "text": task]]]
        ]
        let base = try tokenizer.applyChatTemplate(messages: messages, tools: nil, additionalContext: nil)
        let template = tokenizer.decode(tokenIds: base, skipSpecialTokens: false)
        let expectedTemplate =
            "<|start_of_role|>user<|end_of_role|><image>\(task)<|end_of_text|>\n<|start_of_role|>assistant<|end_of_role|>"
        try require(template == expectedTemplate, "Pinned model template changed.")
        var imageRun = ""
        for row in 1...page.rows {
            for column in 1...page.columns {
                imageRun +=
                    "<fake_token_around_image><row_\(row)_col_\(column)>"
                    + String(repeating: "<image>", count: 64)
            }
            imageRun += "\n"
        }
        imageRun +=
            "\n<fake_token_around_image><global-img>" + String(repeating: "<image>", count: 64)
            + "<fake_token_around_image>"
        let expanded = template.replacingOccurrences(of: "<image>", with: imageRun)
        let ids = tokenizer.encode(text: expanded, addSpecialTokens: false)
        try require(
            ids.count <= 1142 && ids.filter { $0 == 100270 }.count == page.tiles.count * 64,
            "Invalid pinned prompt geometry.")
        try require(ids.allSatisfy { (0..<100352).contains($0) }, "Prompt token outside model vocabulary.")
        let tokens = MLXArray(ids).expandedDimensions(axis: 0)
        let textMask = ones(like: tokens)
        eval(textMask)
        let textMaskNonzero = sum(textMask).item(Int.self)
        try require(textMaskNonzero == ids.count, "Invalid text attention mask.")
        if let comparisonDirectory {
            let expected =
                try JSONSerialization.jsonObject(
                    with: Data(contentsOf: comparisonDirectory.appendingPathComponent("prepared.json")))
                as? [String: Any]
            try require(
                expected?["rasterSHA256"] as? String == sha256(raw)
                    && expected?["rasterShape"] as? [Int] == rgb.shape
                    && expected?["tokenIDs"] as? [Int] == ids
                    && expected?["rows"] as? Int == page.rows
                    && expected?["columns"] as? Int == page.columns
                    && expected?["pixelsShape"] as? [Int] == pixels.shape
                    && expected?["gridRGBSHA256"] as? String == sha256(page.enlargedImage.bytes)
                    && expected?["pixelAttentionMaskShape"] as? [Int] == page.pixelAttentionMask.shape
                    && expected?["pixelAttentionMaskMode"] as? String == "implicit-all-valid-pinned-runtime"
                    && expected?["textAttentionMaskShape"] as? [Int] == textMask.shape
                    && expected?["textAttentionMaskNonzero"] as? Int == textMaskNonzero
                    && expected?["allMasksOne"] as? Bool == true,
                "Raster, tokens or mask contract changed after preparation gate.")
        }
        var traces: [[String: Any]] = []
        if traceDirectory != nil || comparisonDirectory != nil {
            for index in page.tiles.indices {
                let actual = float32LE(pixels[index])
                let name = String(format: "tile-%02d.post-f32le", index)
                if let comparisonDirectory {
                    let expected = try Data(contentsOf: comparisonDirectory.appendingPathComponent(name))
                    try require(actual == expected, "Pixels changed after preparation gate.")
                }
                if let traceDirectory {
                    let path = traceDirectory.appendingPathComponent(name)
                    try require(
                        !FileManager.default.fileExists(atPath: path.path),
                        "Refusing to overwrite preparation.")
                    try actual.write(to: path, options: .atomic)
                    traces.append([
                        "index": index, "shape": [512, 512, 3], "actualDtype": "bfloat16",
                        "role": index < page.rows * page.columns ? "local" : "global",
                        "row": index < page.rows * page.columns ? index / page.columns : -1,
                        "column": index < page.rows * page.columns ? index % page.columns : -1,
                        "storageDtype": "float32-le-hwc", "file": name, "sha256": sha256(actual),
                        "rawRGBSHA256": sha256(page.tiles[index].bytes),
                        "precastF32SHA256": sha256(page.normalizedTilesHWCFloat32LE[index]),
                    ])
                }
            }
        }
        if let traceDirectory {
            try raw.write(to: traceDirectory.appendingPathComponent("raster.rgb"), options: .atomic)
            try writeJSON(
                [
                    "generationAttempts": 0, "rasterSHA256": sha256(raw), "rasterShape": rgb.shape,
                    "rows": page.rows, "columns": page.columns,
                    "roundedWidth": page.roundedWidth, "roundedHeight": page.roundedHeight,
                    "gridWidth": page.enlargedImage.width, "gridHeight": page.enlargedImage.height,
                    "gridRGBSHA256": sha256(page.enlargedImage.bytes), "tiles": traces,
                    "tokenIDs": ids, "template": template, "expandedPrompt": expanded,
                    "allMasksOne": true, "pixelAttentionMaskShape": page.pixelAttentionMask.shape,
                    "pixelAttentionMaskAllOne": true,
                    "pixelAttentionMaskMode": "implicit-all-valid-pinned-runtime",
                    "pixelAttentionMaskEvidence": "contract-no-materialized-tensor",
                    "pixelAttentionMaskExpectedNonzero": page.tiles.count * 512 * 512,
                    "textAttentionMaskShape": textMask.shape,
                    "textAttentionMaskNonzero": textMaskNonzero,
                    "textAttentionMaskEvidence": "evaluated-tensor-passed-to-LMInput",
                    "tileOrder": "row-major local crops then global view",
                    "pixelsShape": pixels.shape, "pixelsDtype": "bfloat16",
                ], traceDirectory.appendingPathComponent("prepared.json"))
        }
        return LMInput(text: .init(tokens: tokens, mask: textMask), image: .init(pixels: pixels))
    }
}
