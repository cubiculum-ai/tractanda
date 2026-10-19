#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import DoclingRaster
import Foundation
import MLX
import MLXHuggingFace
import MLXLMCommon
import MLXNN
import MLXVLM
import TractandaClient
import VMLXTokenizers

struct Assets: Decodable {
    struct File: Decodable {
        let file: String
        let bytes: Int
        let sha256: String
    }
    let revision: String
    let files: [File]
}

func verifyModel(_ directory: URL, progress: ((Int64, Int64) throws -> Void)? = nil) throws {
    try require(
        Idefics3.tractandaVisionGELUPatchIdentifier == "idefics3-vision-gelu-f32-v1",
        "Required pinned-runtime inference patch is missing.")
#if os(Linux)
    _ = try LinuxNativeAdmission.active()
#else
    try require(DocumentConverterIdentity().converter == "tractanda.docling-native.v2-idefics3-gelu-f32", "Required converter identity is missing.")
#endif
    let assets = try JSONDecoder().decode(
        Assets.self,
        from: Data(contentsOf: Bundle.module.url(forResource: "ModelAssets", withExtension: "json")!))
    try require(
        assets.revision == DocumentConverterIdentity().modelRevision && assets.files.count == 14,
        "Invalid pinned model manifest.")
    let totalBytes = assets.files.reduce(Int64(0)) { $0 + Int64($1.bytes) }
    var verifiedBytes: Int64 = 0
    for asset in assets.files {
        let url = directory.appendingPathComponent(asset.file)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        try require(
            attributes[.type] as? FileAttributeType == .typeRegular
                && (attributes[.size] as? NSNumber)?.intValue == asset.bytes,
            "Pinned model asset size/type differs.")
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hasher = SHA256()
        while let bytes = try file.read(upToCount: 1024 * 1024), !bytes.isEmpty {
            hasher.update(data: bytes)
            verifiedBytes += Int64(bytes.count)
            try progress?(verifiedBytes, totalBytes)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        try require(actual == asset.sha256, "Pinned model asset hash differs.")
    }
}

func expectedWeights(_ directory: URL) throws -> [String: [Int]] {
    let config = try JSONDecoder().decode(
        Idefics3Configuration.self, from: Data(contentsOf: directory.appendingPathComponent("config.json")))
    try require(
        config.visionConfig.imageSize == 512 && config.visionConfig.patchSize == 16
            && config.scaleFactor == 4 && config.imageTokenIndex == 100270, "Pinned model geometry differs.")
    let model = Idefics3(config)
    let expected = Dictionary(uniqueKeysWithValues: model.parameters().flattened().map { ($0.0, $0.1.shape) })
    let file = try FileHandle(forReadingFrom: directory.appendingPathComponent("model.safetensors"))
    defer { try? file.close() }
    let prefix = try file.read(upToCount: 8) ?? Data()
    try require(prefix.count == 8, "Missing weight header.")
    let count = prefix.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
    try require(count <= 4 * 1024 * 1024, "Weight header exceeds its limit.")
    let bytes = try file.read(upToCount: Int(count)) ?? Data()
    let header = try JSONSerialization.jsonObject(with: bytes) as! [String: [String: Any]]
    let shapes = header.filter { $0.key != "__metadata__" }.mapValues { $0["shape"] as! [Int] }
    try require(expected.count == 471 && expected == shapes, "Pinned weight keys/shapes differ.")
    return expected
}

@main struct TractandaDocumentConverter {
    static func main() async {
#if os(Linux)
        await runOnLinux()
#else
        await run()
#endif
    }
#if os(Linux)
    // Keep the task-local CPU scope outside the main actor. The pinned MLX
    // async wrapper runs concurrently under Swift 6.4; run() retains its isolation.
    nonisolated private static func runOnLinux() async {
        await Device.withDefaultDevice(.cpu) { await run() }
    }
#endif
    private static func run() async {
#if os(Linux)
        do { _ = try LinuxNativeAdmission.active() }
        catch { FileHandle.standardError.write(Data(("Unadmitted Linux document runtime: \(error)\n").utf8)); exit(1) }
#endif
        let args = Array(CommandLine.arguments.dropFirst())
        if let mode = args.first, ["inspect-v1", "worker-v1"].contains(mode) {
            await NativeDocumentWorker.main(args)
            return
        }
        guard (5...6).contains(args.count), ["prepare", "convert", "diagnose"].contains(args[0]) else {
            FileHandle.standardError.write(
                Data("usage: converter prepare|convert MODEL INPUT MEDIA OUTPUT [PREPARATION]\n".utf8))
            exit(1)
        }
        let modelDirectory = URL(fileURLWithPath: args[1], isDirectory: true)
        let inputURL = URL(fileURLWithPath: args[2])
        let output = URL(fileURLWithPath: args[4], isDirectory: args[0] != "convert")
        let preparing = args[0] == "prepare"
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: inputURL.path)
            let inputBytes = (attributes[.size] as? NSNumber)?.intValue ?? Int.max
            try require(
                attributes[.type] as? FileAttributeType == .typeRegular
                    && inputBytes > 0 && inputBytes <= DoclingRasterizer.maximumInputBytes,
                "Original exceeds its admission limit.")
            let input = try Data(contentsOf: inputURL)
            let rasters = try DoclingRasterizer.rasterize(input, mediaType: args[3])
            try verifyModel(modelDirectory)
            let expected = try expectedWeights(modelDirectory)
            var context = try await VLMModelFactory.shared.load(
                from: modelDirectory, using: #huggingFaceTokenizerLoader())
            let weights = Dictionary(
                uniqueKeysWithValues: context.model.parameters().flattened().map { ($0.0, $0.1.shape) })
            try require(weights == expected, "Loaded model weights differ.")
            let visionWeight = context.model.parameters().flattened().first {
                $0.0 == "vision_model.embeddings.patch_embedding.weight"
            }!.1
            try require(visionWeight.dtype == .bfloat16, "Loaded vision weights are not BF16.")
            context.model.train(false)
            context.processor = NativeDocumentInput(tokenizer: context.tokenizer, traceDirectory: nil, comparisonDirectory: nil)
            if args[0] == "diagnose" {
                try require(rasters.count == 1, "Diagnostic requires one page.")
                try await diagnoseInference(
                    context: context, raster: rasters[0], output: output,
                    cached: args.count == 6 && args[5] == "cached")
                return
            }
            let nativeModel = context.model
            var pages: [DocumentGeneratedPage] = []
            if preparing {
                try require(
                    !FileManager.default.fileExists(atPath: output.path),
                    "Preparation directory already exists.")
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            }
            for raster in rasters {
                let pageName = "page-\(raster.pageNumber)"
                let trace = preparing ? output.appendingPathComponent(pageName, isDirectory: true) : nil
                if let trace {
                    try FileManager.default.createDirectory(at: trace, withIntermediateDirectories: false)
                }
                let comparison =
                    args.count == 6
                    ? URL(fileURLWithPath: args[5]).appendingPathComponent(pageName, isDirectory: true) : nil
                context.processor = NativeDocumentInput(
                    tokenizer: context.tokenizer, traceDirectory: trace, comparisonDirectory: comparison)
                if let comparison {
                    let expectedGeometry = try JSON.decode(
                        DocumentPageGeometry.self,
                        Data(contentsOf: comparison.appendingPathComponent("geometry.json")))
                    try require(
                        expectedGeometry == raster.geometry,
                        "Citation geometry changed after preparation gate.")
                    let source =
                        try JSONSerialization.jsonObject(
                            with: Data(contentsOf: comparison.appendingPathComponent("raster-source.json")))
                        as? [String: Any]
                    try require(
                        source?["renderedCanvasSHA256"] as? String == raster.renderedCanvasSHA256,
                        "Fixed render changed after preparation gate.")
                }
                let rawRGB = MLXArray(Array(raster.rgb.bytes)).reshaped(
                    raster.rgb.height, raster.rgb.width, 3)
                let prepared = try await context.processor.prepare(
                    input: UserInput(prompt: "Convert this page to docling.", images: [.array(rawRGB)]))
                if let trace {
                    try JSON.encode(raster.geometry).write(
                        to: trace.appendingPathComponent("geometry.json"), options: .atomic)
                    try writeJSON(
                        [
                            "renderedCanvasSHA256": raster.renderedCanvasSHA256,
                            "renderedCanvasShape": [2048, 2048, 3],
                            "cropBounds": raster.renderedCropBounds,
                            "croppedRasterSHA256": sha256(raster.rgb.bytes),
                            "croppedRasterShape": [raster.rgb.height, raster.rgb.width, 3],
                        ], trace.appendingPathComponent("raster-source.json"))
                    continue
                }
                try writeJSON(
                    ["pageNumber": raster.pageNumber],
                    output.deletingLastPathComponent().appendingPathComponent("page-progress.json"))
                let observer =
                    comparison == nil
                    ? nil : FiniteModel(base: nativeModel, root: output.deletingLastPathComponent())
                if let observer { context.model = observer } else { context.model = nativeModel }
                let rawURL = output.deletingLastPathComponent().appendingPathComponent(
                    pageName + ".output.doctags")
                try require(
                    !FileManager.default.fileExists(atPath: rawURL.path),
                    "Refusing to overwrite generated evidence.")
                try Data().write(to: rawURL, options: .atomic)
                let rawFile = try FileHandle(forWritingTo: rawURL)
                defer { try? rawFile.close() }
                let generationURL = output.deletingLastPathComponent().appendingPathComponent(
                    pageName + ".generation.json")
                try writeJSON(
                    [
                        "pageNumber": raster.pageNumber, "tokensGenerated": NSNull(),
                        "stopReason": "inProgress", "maxTokens": 1024,
                        "finiteForwardInstrumentation": observer != nil,
                    ], generationURL)
                let stream = try generate(
                    input: prepared,
                    parameters: GenerateParameters(maxTokens: 1024, temperature: 0, randomSeed: 17),
                    context: context)
                var raw = ""
                var tokens = 0
                var stop = "missing_completion"
                for await event in stream {
                    switch event {
                    case .chunk(let chunk):
                        try require(
                            chunk.utf8.count <= DoclingParsedPage.maximumRawBytes - raw.utf8.count,
                            "Generated page exceeds its output limit.")
                        raw += chunk
                        try rawFile.write(contentsOf: Data(chunk.utf8))
                    case .info(let info):
                        tokens = info.generationTokenCount
                        stop = String(describing: info.stopReason)
                    default: break
                    }
                }
                try rawFile.synchronize()
                var evidence: [String: Any] = [
                    "pageNumber": raster.pageNumber, "tokensGenerated": tokens,
                    "stopReason": stop, "rawSHA256": sha256(Data(raw.utf8)), "rawBytes": raw.utf8.count,
                    "rasterSHA256": sha256(raster.rgb.bytes), "maxTokens": 1024,
                    "finiteForwardInstrumentation": observer != nil,
                ]
                if let observer {
                    evidence["observedForwards"] = observer.observedForwards
                    evidence["rawArgmaxTokenIDs"] = observer.rawArgmaxTokens
                    evidence["prefillShape"] = observer.prefillShape
                    evidence["decodeShape"] = observer.lastDecodeShape
                }
                try writeJSON(evidence, generationURL)
                guard stop == "stop", tokens < 1024, raw.contains("</doctag>") else {
                    throw TractandaError(
                        "truncatedDocumentOutput", "Document page generation did not complete.")
                }
                pages.append(
                    DocumentGeneratedPage(
                        pageNumber: raster.pageNumber, geometry: raster.geometry,
                        rasterSHA256: sha256(raster.rgb.bytes), rawDocTags: raw, generatedTokens: tokens,
                        stopReason: stop))
            }
            if preparing {
                try writeJSON(
                    [
                        "generationAttempts": 0, "modelLoaded": true, "modelForwardCalls": 0,
                        "inputSHA256": sha256(input), "pages": rasters.count,
                        "weightShapes": weights.count,
                        "identity": try JSONSerialization.jsonObject(
                            with: JSON.encode(DocumentConverterIdentity())),
                    ],
                    output.appendingPathComponent("summary.json"))
            } else {
                let result = DocumentConversionResult(
                    identity: .init(), inputSHA256: sha256(input), pages: pages)
                let data = try JSON.encode(result)
                try require(data.count <= 2 * 1024 * 1024, "Document result exceeds its limit.")
                try data.write(to: output, options: .atomic)
            }
        } catch {
            let code: String
            if let typed = error as? TractandaError {
                code = typed.code
            } else if error is DoclingRasterError {
                code = "unsupportedDocumentInput"
            } else {
                code = "documentConverterFailed"
            }
            if !preparing {
                try? writeJSON(["code": code, "message": "Native document conversion failed."], output)
            }
            FileHandle.standardError.write(Data("\(code): \(String(describing: error).prefix(1024))\n".utf8))
            exit(1)
        }
    }
}
