import Foundation

public enum LSMError: String, Error, Codable, Sendable {
    case invalidConfiguration, invalidExample, limitExceeded, unknownExample, needsCompilation
    case insufficientExamples, noSignal, numericalFailure, invalidCache
}

public struct LSMConfiguration: Codable, Equatable, Sendable {
    public enum Composition: String, Codable, Sendable { case documents, labelTotals, balancedLabels }
    public var dimensions: Int
    public var powerIterations: Int
    public var maximumVocabulary: Int
    public var composition: Composition

    public init(
        dimensions: Int = 32, powerIterations: Int = 2, maximumVocabulary: Int = 16_384,
        composition: Composition = .balancedLabels
    ) {
        self.dimensions = dimensions
        self.powerIterations = powerIterations
        self.maximumVocabulary = maximumVocabulary
        self.composition = composition
    }

    public func validate() throws {
        guard (1...64).contains(dimensions), (0...6).contains(powerIterations),
            (2...32_768).contains(maximumVocabulary)
        else { throw LSMError.invalidConfiguration }
    }
}

public struct LSMExample: Codable, Equatable, Sendable {
    public let id: String
    public let tokens: [String]
    public let isPositive: Bool
    public let weight: Double

    public init(id: String, tokens: [String], isPositive: Bool, weight: Double = 1) {
        self.id = id
        self.tokens = tokens
        self.isPositive = isPositive
        self.weight = weight
    }

    func validate() throws {
        guard !id.isEmpty, id.utf8.count <= 256, weight.isFinite, (0...1_000_000).contains(weight),
            tokens.count <= 4096, tokens.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 })
        else { throw LSMError.invalidExample }
    }
}

public struct LSMPrediction: Codable, Sendable {
    public enum Unavailability: String, Codable, Sendable { case emptyInput, unknownVocabulary, noSignal }
    /// Cosine-to-positive minus cosine-to-negative. A ranking margin, never a probability.
    public let score: Double?
    public let positiveSimilarity: Double?
    public let negativeSimilarity: Double?
    public let matchedTokens: Int
    public let totalTokens: Int
    public let unavailability: Unavailability?
}

/// Immutable compiled map. One positive and one negative semantic anchor per category.
public struct LSMModel: Sendable {
    public static let profile = "tractanda.lsm.v1"
    public let configuration: LSMConfiguration
    public let vocabulary: [String]
    public let singularValues: [Double]
    public let capturedEnergyFraction: Double
    public let positiveExamples: Int
    public let negativeExamples: Int
    let globalWeights: [Double]
    let basis: [[Double]]
    let positiveAnchor: [Double]
    let negativeAnchor: [Double]
    private let indices: [String: Int]

    init(
        configuration: LSMConfiguration, vocabulary: [String], globalWeights: [Double],
        projection: LowRankProjection, positiveAnchor: [Double], negativeAnchor: [Double],
        positiveExamples: Int, negativeExamples: Int
    ) {
        self.configuration = configuration
        self.vocabulary = vocabulary
        self.globalWeights = globalWeights
        self.basis = projection.basis
        self.singularValues = projection.singularValues
        self.capturedEnergyFraction = projection.capturedEnergyFraction
        self.positiveAnchor = positiveAnchor
        self.negativeAnchor = negativeAnchor
        self.positiveExamples = positiveExamples
        self.negativeExamples = negativeExamples
        self.indices = Dictionary(uniqueKeysWithValues: vocabulary.enumerated().map { ($1, $0) })
    }

    /// Tokens are already normalized by the caller; querying never changes the vocabulary.
    /// Complexity: O(token count × retained dimensions).
    public func predict(tokens: [String]) throws -> LSMPrediction {
        try LSMExample(id: "query", tokens: tokens, isPositive: false).validate()
        var vector = [Double](repeating: 0, count: basis.count)
        var matched = 0
        for token in tokens {
            guard let index = indices[token] else { continue }
            matched += 1
            for component in basis.indices {
                vector[component] += globalWeights[index] * basis[component][index]
            }
        }
        // Length normalization cancels from cosine; retain all tokens in coverage diagnostics.
        let norm = sqrt(LowRankProjection.dot(vector, vector))
        guard norm > 1e-14 else {
            return LSMPrediction(
                score: nil, positiveSimilarity: nil, negativeSimilarity: nil,
                matchedTokens: matched, totalTokens: tokens.count,
                unavailability: tokens.isEmpty ? .emptyInput : matched == 0 ? .unknownVocabulary : .noSignal)
        }
        let normalized = vector.map { $0 / norm }
        let positive = max(-1, min(1, LowRankProjection.dot(normalized, positiveAnchor)))
        let negative = max(-1, min(1, LowRankProjection.dot(normalized, negativeAnchor)))
        return LSMPrediction(
            score: positive - negative, positiveSimilarity: positive, negativeSimilarity: negative,
            matchedTokens: matched, totalTokens: tokens.count, unavailability: nil)
    }
}

/// Mutable training map, confined to one executor. Share the compiled Sendable model for reading.
/// Replacing/removing a named example reverses its exact previous contribution; no blind subtraction is needed.
public final class BinaryLSM {
    public let configuration: LSMConfiguration
    public private(set) var model: LSMModel?
    private var examples: [String: LSMExample] = [:]
    private var tokenCount = 0
    public var exampleCount: Int { examples.count }

    public init(configuration: LSMConfiguration = .init()) throws {
        try configuration.validate()
        self.configuration = configuration
    }

    public func setExample(_ example: LSMExample) throws {
        try example.validate()
        if example.weight == 0 {
            removeExample(id: example.id)
            return
        }
        guard examples[example.id] != nil || examples.count < 10_000 else { throw LSMError.limitExceeded }
        guard examples[example.id] != example else { return }
        let newTokenCount = tokenCount - (examples[example.id]?.tokens.count ?? 0) + example.tokens.count
        guard newTokenCount <= 4_000_000 else { throw LSMError.limitExceeded }
        tokenCount = newTokenCount
        examples[example.id] = example
        model = nil
    }

    public func removeExample(id: String) {
        if let previous = examples.removeValue(forKey: id) {
            tokenCount -= previous.tokens.count
            model = nil
        }
    }

    /// Signed adjustment to a known example's contribution, clamped at zero.
    /// Use setExample for retry-safe replacement. Repeated nonzero adjustments are separate operations.
    public func adjustWeight(for id: String, by delta: Double) throws {
        guard delta.isFinite else { throw LSMError.invalidExample }
        guard let example = examples[id] else { throw LSMError.unknownExample }
        try setExample(
            LSMExample(
                id: id, tokens: example.tokens, isPositive: example.isPositive,
                weight: max(0, example.weight + delta)))
    }

    public func reset() {
        examples.removeAll()
        tokenCount = 0
        model = nil
    }

    @discardableResult
    public func compile() throws -> LSMModel {
        if let model { return model }
        let samples = examples.values.filter { !$0.tokens.isEmpty }.sorted { $0.id < $1.id }
        let positives = samples.filter(\.isPositive).count
        guard positives > 0, positives < samples.count else { throw LSMError.insufficientExamples }
        var documents = samples.map { sample in
            Dictionary(sample.tokens.map { ($0, 1.0) }, uniquingKeysWith: +)
        }
        var weights = samples.map(\.weight)
        if configuration.composition != .documents {
            var totals: [[String: Double]] = [[:], [:]]
            for (index, sample) in samples.enumerated() {
                for (term, count) in documents[index] {
                    totals[sample.isPositive ? 0 : 1][term, default: 0] += count * sample.weight
                }
            }
            if configuration.composition == .balancedLabels {
                totals = totals.map { counts in
                    let total = counts.values.reduce(0, +)
                    return counts.mapValues { $0 / total }
                }
            }
            documents = totals
            weights = [1, 1]
        }
        var totals: [String: Double] = [:]
        for (index, document) in documents.enumerated() {
            for (term, count) in document { totals[term, default: 0] += count * weights[index] }
        }
        let vocabulary = totals.keys.sorted {
            totals[$0] == totals[$1] ? $0 < $1 : totals[$0]! > totals[$1]!
        }.prefix(configuration.maximumVocabulary).sorted()
        let indices = Dictionary(uniqueKeysWithValues: vocabulary.enumerated().map { ($1, $0) })
        var entropy = [Double](repeating: 0, count: vocabulary.count)
        for (index, document) in documents.enumerated() {
            for (term, count) in document {
                guard let row = indices[term] else { continue }
                let probability = count * weights[index] / totals[term]!
                if probability > 0 { entropy[row] -= probability * log(probability) }
            }
        }
        let globalWeights = entropy.map { max(0, min(1, 1 - $0 / log(Double(documents.count)))) }
        let columns = documents.enumerated().map { index, document in
            let length = document.values.reduce(0, +)
            return document.compactMap { term, count -> SemanticMatrix.Entry? in
                guard let row = indices[term], globalWeights[row] > 1e-14 else { return nil }
                return SemanticMatrix.Entry(
                    row: row, value: sqrt(weights[index]) * globalWeights[row] * count / length)
            }.sorted { $0.row < $1.row }
        }
        let projection = try LowRankProjection.make(
            from: SemanticMatrix(rowCount: vocabulary.count, columns: columns),
            dimensions: configuration.dimensions, iterations: configuration.powerIterations)
        var positiveAnchor = [Double](repeating: 0, count: projection.basis.count)
        var negativeAnchor = positiveAnchor
        let projected = SemanticMatrix(rowCount: vocabulary.count, columns: columns).transposeMultiplied(
            by: projection.basis)
        for index in documents.indices {
            let isPositive =
                configuration.composition != .documents ? index == 0 : samples[index].isPositive
            for component in projection.basis.indices {
                // Remove sqrt(weight) from the matrix column, then apply weight for the centroid.
                let contribution = projected[component][index] * sqrt(weights[index])
                if isPositive {
                    positiveAnchor[component] += contribution
                } else {
                    negativeAnchor[component] += contribution
                }
            }
        }
        func normalized(_ vector: [Double]) throws -> [Double] {
            let norm = sqrt(LowRankProjection.dot(vector, vector))
            guard norm > 1e-14 else { throw LSMError.noSignal }
            return vector.map { $0 / norm }
        }
        let compiled = try LSMModel(
            configuration: configuration, vocabulary: vocabulary, globalWeights: globalWeights,
            projection: projection, positiveAnchor: normalized(positiveAnchor),
            negativeAnchor: normalized(negativeAnchor),
            positiveExamples: positives, negativeExamples: samples.count - positives)
        model = compiled
        return compiled
    }

    /// Portable, disposable recipe cache. Recompilation on restore avoids trusting cached numerical factors.
    /// The recipe retains exact examples for subsequent correction; it is not an item/feedback history.
    public func encodedCache() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(
            Cache(
                profile: LSMModel.profile, configuration: configuration,
                examples: examples.values.sorted { $0.id < $1.id }))
        guard data.count <= 64 * 1024 * 1024 else { throw LSMError.limitExceeded }
        return data
    }

    public static func make(fromCache data: Data) throws -> BinaryLSM {
        guard data.count <= 64 * 1024 * 1024 else { throw LSMError.invalidCache }
        do {
            let cache = try JSONDecoder().decode(Cache.self, from: data)
            guard cache.profile == LSMModel.profile, cache.examples.count <= 10_000,
                Set(cache.examples.map(\.id)).count == cache.examples.count
            else { throw LSMError.invalidCache }
            let result = try BinaryLSM(configuration: cache.configuration)
            for example in cache.examples { try result.setExample(example) }
            return result
        } catch { throw LSMError.invalidCache }
    }

    private struct Cache: Codable {
        let profile: String
        let configuration: LSMConfiguration
        let examples: [LSMExample]
    }
}
