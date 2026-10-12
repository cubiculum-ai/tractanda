import Foundation
import MLX
import MLXLMCommon
import MLXNN

// Task-only forwarding observer: no weight, cache, sampler or runtime changes.
final class FiniteModel: Module, VisionLanguageModelProtocol {
    let base: any LanguageModel
    let root: URL
    var observedForwards = 0
    var rawArgmaxTokens = [Int]()
    var prefillShape = [Int]()
    var lastDecodeShape = [Int]()
    init(base: any LanguageModel, root: URL) {
        self.base = base
        self.root = root
    }
    var supportsWholeForwardCompilation: Bool { false }
    func newCache(parameters: GenerateParameters?) -> [any KVCache] { base.newCache(parameters: parameters) }
    func checked(_ output: LMOutput, prefill: Bool) -> LMOutput {
        let finite = all(isFinite(output.logits)).item(Bool.self)
        guard finite else {
            try? writeJSON(
                [
                    "error": "nonfinite raw model logits", "forward": observedForwards,
                    "shape": output.logits.shape,
                ], root.appendingPathComponent("finite-failure-20261007.json"))
            exit(1)
        }
        rawArgmaxTokens.append(output.logits[0, output.logits.dim(1) - 1].argMax().item(Int.self))
        observedForwards += 1
        if prefill { prefillShape = output.logits.shape } else { lastDecodeShape = output.logits.shape }
        return output
    }
    func prepare(_ input: LMInput, cache: [any KVCache], windowSize: Int?) throws -> PrepareResult {
        switch try base.prepare(input, cache: cache, windowSize: windowSize) {
        case .logits(let output): return .logits(checked(output, prefill: true))
        case .tokens(let tokens): return .tokens(tokens)
        }
    }
    func callAsFunction(_ input: LMInput.Text, cache: [any KVCache]?, state: LMOutput.State?) -> LMOutput {
        checked(base(input, cache: cache, state: state), prefill: false)
    }
}
