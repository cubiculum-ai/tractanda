import DoclingRaster
import Foundation
import MLX
import MLXLMCommon
import MLXNN

private final class DiagnosticCapture {
    let root: URL
    var values: [String: MLXArray] = [:]
    init(root: URL) { self.root = root }
    func retain(_ name: String, _ array: MLXArray) {
        if name == "merged", values[name] != nil { return }
        values[name] = array
    }
    func publish() throws -> [String: Any] {
        var receipt: [String: Any] = [:]
        for (name, array) in values {
            let observed = name == "vision" ? array[0..., .stride(by: 8), .stride(by: 16)] : array
            let bytes = float32LE(observed)
            try bytes.write(to: root.appendingPathComponent(name + ".f32le"), options: .atomic)
            receipt[name] = [
                "shape": observed.shape, "originalShape": array.shape,
                "dtype": String(describing: array.dtype), "sha256": sha256(bytes),
            ]
        }
        return receipt
    }
}

private final class DiagnosticLayerNorm: LayerNorm {
    let capture: DiagnosticCapture
    init(original: LayerNorm, capture: DiagnosticCapture) {
        self.capture = capture
        super.init(
            dimensions: original.dimensions, eps: original.eps,
            affine: original.weight != nil, bias: original.bias != nil)
        update(parameters: original.parameters())
    }
    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        let result = super.callAsFunction(x)
        capture.retain("vision", result)
        return result
    }
}

private final class DiagnosticLinear: Linear {
    let capture: DiagnosticCapture
    init(original: Linear, capture: DiagnosticCapture) {
        self.capture = capture
        super.init(original.weight.shape[1], original.weight.shape[0], bias: original.bias != nil)
        update(parameters: original.parameters())
    }
    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        let result = super.callAsFunction(x)
        capture.retain("projector", result)
        return result
    }
}

private final class DiagnosticRMSNorm: RMSNorm {
    let capture: DiagnosticCapture
    init(original: RMSNorm, capture: DiagnosticCapture) {
        self.capture = capture
        super.init(dimensions: original.weight.shape[0], eps: original.eps)
        update(parameters: original.parameters())
    }
    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        capture.retain("merged", x)
        return super.callAsFunction(x)
    }
}

func diagnoseInference(context: ModelContext, raster: DocumentRasterPage, output: URL, cached: Bool = false)
    async throws
{
    try require(!FileManager.default.fileExists(atPath: output.path), "Diagnostic output exists.")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
    let capture = DiagnosticCapture(root: output)
    var replacements: [String: Module] = [:]
    guard let model = context.model as? Module else {
        throw NSError(domain: "diagnostic", code: 1)
    }
    model.visit { name, child in
        if name == "language_model.layers.0.input_layernorm", let norm = child as? RMSNorm {
            replacements[name] = DiagnosticRMSNorm(original: norm, capture: capture)
        }
        if name == "vision_model.post_layernorm", let norm = child as? LayerNorm {
            replacements[name] = DiagnosticLayerNorm(original: norm, capture: capture)
        }
        if name == "connector.modality_projection.proj", let linear = child as? Linear {
            replacements[name] = DiagnosticLinear(original: linear, capture: capture)
        }
    }
    try require(replacements.count == 3, "Missing diagnostic observation boundaries.")
    try model.update(modules: ModuleChildren.unflattened(replacements), verify: .all)
    let processor = NativeDocumentInput(
        tokenizer: context.tokenizer, traceDirectory: nil, comparisonDirectory: nil)
    let rgb = MLXArray(Array(raster.rgb.bytes)).reshaped(raster.rgb.height, raster.rgb.width, 3)
    let prepared = try await processor.prepare(
        input: UserInput(prompt: "Convert this page to docling.", images: [.array(rgb)]))
    let prefix = [100327, 100260, 27, 1092, 62]
    let ids = prepared.text.tokens.asArray(Int.self) + prefix
    let tokens = MLXArray(ids).expandedDimensions(axis: 0)
    let input = LMInput(text: .init(tokens: tokens, mask: ones(like: tokens)), image: prepared.image)
    var tieValues = [Float](repeating: -10, count: 100352)
    tieValues[1135] = 27.125
    tieValues[2287] = 27.125
    let tie = MLXArray(tieValues).asType(.bfloat16)
    let tieArgmax = tie.argMax().item(Int.self)
    let tieSample = GenerateParameters(maxTokens: 1, temperature: 0).sampler().sample(
        logits: tie.expandedDimensions(axis: 0)
    ).item(Int.self)
    let cache = context.model.newCache(parameters: GenerateParameters(maxTokens: 1, temperature: 0))
    var result = try context.model.prepare(cached ? prepared : input, cache: cache, windowSize: nil)
    var forwardArgmax: [Int] = []
    if case .logits(let first) = result {
        forwardArgmax.append(first.logits[0, first.logits.dim(1) - 1].argMax().item(Int.self))
    }
    if cached {
        for token in prefix {
            let next = MLXArray([token]).expandedDimensions(axis: 0)
            let logits = context.model(.init(tokens: next, mask: ones(like: next)), cache: cache, state: nil)
            try require(all(isFinite(logits.logits)).item(Bool.self), "Nonfinite cached diagnostic.")
            forwardArgmax.append(logits.logits[0, logits.logits.dim(1) - 1].argMax().item(Int.self))
            result = .logits(logits)
        }
    }
    guard case .logits(let logits) = result else { throw NSError(domain: "diagnostic", code: 2) }
    let row = logits.logits[0, logits.logits.dim(1) - 1]
    eval(row)
    try require(all(isFinite(row)).item(Bool.self), "Nonfinite diagnostic logits.")
    let data = float32LE(row)
    try data.write(to: output.appendingPathComponent("logits.f32le"), options: .atomic)
    let values = row.asType(.float32).asArray(Float.self)
    let top = values.indices.sorted { values[$0] > values[$1] }.prefix(10)
    let microInput = MLXArray((0...256).map { Float($0 - 128) / 16 }).asType(.bfloat16)
    let microBaseline = safeGeluApproximate(microInput)
    let microFloat = safeGeluApproximate(microInput.asType(.float32)).asType(.bfloat16)
    try float32LE(microInput).write(to: output.appendingPathComponent("gelu-input.f32le"), options: .atomic)
    try float32LE(microBaseline).write(
        to: output.appendingPathComponent("gelu-baseline.f32le"), options: .atomic)
    try float32LE(microFloat).write(
        to: output.appendingPathComponent("gelu-f32-intermediate.f32le"), options: .atomic)
    let tensors = try capture.publish()
    try writeJSON(
        [
            "modelForwardCalls": cached ? 6 : 1, "generationAttempts": 0,
            "cacheMode": cached ? "prompt-prefill-plus-five-fixed-tokens" : "full-prefix",
            "forwardArgmax": forwardArgmax, "sharedPrefix": prefix,
            "promptTokenCount": ids.count, "inputRasterSHA256": sha256(raster.rgb.bytes),
            "argmax": row.argMax().item(Int.self), "logitsSHA256": sha256(data),
            "candidates": Array(top).map { ["id": $0, "value": values[$0]] as [String: Any] },
            "tieMicrocheck": [
                "vocabulary": 100352, "dtype": "bfloat16", "tieIDs": [1135, 2287],
                "argmax": tieArgmax, "actualGreedySampler": tieSample,
            ],
            "score50": values[1135], "score66": values[2287], "tensors": tensors,
            "observerEffect":
                "Subclass returns unchanged baseline output; retained arrays are materialized after logits evaluation. No arithmetic replacement.",
        ], output.appendingPathComponent("report.json"))
}
