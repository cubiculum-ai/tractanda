import Foundation
import XCTest

@testable import TractandaLearning

final class LSMTests: XCTestCase {
    private func makeMap() throws -> BinaryLSM {
        let map = try BinaryLSM()
        for (id, text, label) in [
            ("p1", "chess club queen tournament", true), ("p2", "chess rook match club", true),
            ("p3", "club president tournament", true), ("n1", "garden seeds flowers", false),
            ("n2", "garden plants soil", false), ("n3", "invoice business payment", false),
        ] {
            try map.setExample(
                LSMExample(id: id, tokens: text.components(separatedBy: " "), isPositive: label))
        }
        return map
    }

    func testPublishedWeightingAndCosineProjection() throws {
        let map = try BinaryLSM(configuration: .init(dimensions: 2))
        try map.setExample(.init(id: "positive", tokens: ["chess", "common"], isPositive: true))
        try map.setExample(.init(id: "negative", tokens: ["garden", "common"], isPositive: false))
        let model = try map.compile()
        // Bellegarda equations (1)-(2): a common, uniformly distributed term has zero weight.
        XCTAssertEqual(model.globalWeights[model.vocabulary.firstIndex(of: "common")!], 0, accuracy: 1e-14)
        XCTAssertEqual(model.singularValues, [0.5, 0.5])
        XCTAssertEqual(try model.predict(tokens: ["chess"]).score!, 1, accuracy: 1e-12)
        XCTAssertEqual(try model.predict(tokens: ["garden"]).score!, -1, accuracy: 1e-12)
        XCTAssertEqual(try model.predict(tokens: ["chess", "garden"]).score!, 0, accuracy: 1e-12)
        XCTAssertEqual(try model.predict(tokens: ["common"]).unavailability, .noSignal)
        XCTAssertEqual(try model.predict(tokens: ["unseen"]).unavailability, .unknownVocabulary)
        XCTAssertEqual(try model.predict(tokens: []).unavailability, .emptyInput)
        let prediction = try model.predict(tokens: ["chess", "unseen"])
        XCTAssertEqual(prediction.matchedTokens, 1)
        XCTAssertEqual(prediction.totalTokens, 2)
        XCTAssertEqual(prediction.score!, 1, accuracy: 1e-12)
    }

    func testReplacementCorrectionCacheAndReset() throws {
        let map = try makeMap()
        let fresh = try makeMap()
        let query = ["garden", "chess", "president"]
        let original = try map.compile().predict(tokens: query).score!
        try map.setExample(.init(id: "bad", tokens: ["garden", "seeds"], isPositive: true, weight: 4))
        XCTAssertNil(map.model)
        _ = try map.compile()
        try map.adjustWeight(for: "bad", by: -4)
        XCTAssertEqual(try map.compile().predict(tokens: query).score!, original, accuracy: 1e-12)
        let corrected = LSMExample(id: "new", tokens: ["garden", "seeds"], isPositive: false, weight: 0.75)
        try map.setExample(corrected)
        try map.setExample(corrected)
        try fresh.setExample(corrected)
        XCTAssertEqual(map.exampleCount, 7)
        XCTAssertEqual(
            try map.compile().predict(tokens: query).score!,
            try fresh.compile().predict(tokens: query).score!, accuracy: 1e-12)
        let data = try map.encodedCache()
        let restored = try BinaryLSM.make(fromCache: data)
        XCTAssertEqual(try restored.encodedCache(), data)
        XCTAssertEqual(
            try restored.compile().predict(tokens: query).score!,
            try map.compile().predict(tokens: query).score!, accuracy: 1e-12)
        restored.removeExample(id: "new")
        restored.removeExample(id: "new")
        XCTAssertEqual(try restored.compile().predict(tokens: query).score!, original, accuracy: 1e-12)
        restored.reset()
        XCTAssertEqual(restored.exampleCount, 0)
        XCTAssertNil(restored.model)
        XCTAssertThrowsError(try restored.compile()) {
            XCTAssertEqual($0 as? LSMError, .insufficientExamples)
        }
    }

    func testInvalidInputAndCorruptCacheDoNotChangeTraining() throws {
        let map = try makeMap()
        XCTAssertThrowsError(try map.setExample(.init(id: "bad", tokens: [""], isPositive: true)))
        XCTAssertThrowsError(
            try map.setExample(.init(id: "bad", tokens: ["word"], isPositive: true, weight: .infinity)))
        XCTAssertEqual(map.exampleCount, 6)
        XCTAssertThrowsError(try BinaryLSM(configuration: .init(dimensions: 100)))
        XCTAssertThrowsError(try BinaryLSM.make(fromCache: Data("{}".utf8)))
        var cache = try JSONSerialization.jsonObject(with: map.encodedCache()) as! [String: Any]
        cache["profile"] = "future.profile"
        XCTAssertThrowsError(try BinaryLSM.make(fromCache: JSONSerialization.data(withJSONObject: cache)))
        cache["profile"] = LSMModel.profile
        var examples = cache["examples"] as! [[String: Any]]
        examples.append(examples[0])
        cache["examples"] = examples
        XCTAssertThrowsError(try BinaryLSM.make(fromCache: JSONSerialization.data(withJSONObject: cache)))
    }

    func testIndependentLabelsAndDocumentBoundaries() throws {
        func trained(merged: Bool, composition: LSMConfiguration.Composition) throws -> LSMModel {
            let map = try BinaryLSM(configuration: .init(dimensions: 2, composition: composition))
            let rows = [
                (true, ["red", "red", "green"]), (true, ["red", "blue"]),
                (false, ["blue", "blue", "green"]), (false, ["green", "yellow"]),
            ]
            if merged {
                for label in [true, false] {
                    try map.setExample(
                        .init(
                            id: String(label), tokens: rows.filter { $0.0 == label }.flatMap { $0.1 },
                            isPositive: label))
                }
            } else {
                for (index, row) in rows.enumerated() {
                    try map.setExample(.init(id: String(index), tokens: row.1, isPositive: row.0))
                }
            }
            return try map.compile()
        }
        let aggregate = try trained(merged: false, composition: .labelTotals)
        let merged = try trained(merged: true, composition: .labelTotals)
        let documents = try trained(merged: false, composition: .documents)
        let query = ["red", "green"]
        XCTAssertEqual(
            try aggregate.predict(tokens: query).score!, try merged.predict(tokens: query).score!,
            accuracy: 1e-12)
        XCTAssertGreaterThan(
            abs(try documents.predict(tokens: query).score! - aggregate.predict(tokens: query).score!), 1e-4)
        let separate = try makeMap()
        let before = try separate.compile().predict(tokens: ["chess"]).score
        let other = try makeMap()
        other.reset()
        XCTAssertEqual(try separate.compile().predict(tokens: ["chess"]).score, before)
    }

    func testBalancedLabelsIgnoreUniformChangesInClassMass() throws {
        func model(negativeWeight: Double) throws -> LSMModel {
            let map = try BinaryLSM()
            try map.setExample(.init(id: "p", tokens: ["red", "red", "blue"], isPositive: true))
            try map.setExample(
                .init(id: "n", tokens: ["blue", "blue", "green"], isPositive: false, weight: negativeWeight))
            return try map.compile()
        }
        let first = try model(negativeWeight: 1)
        let doubled = try model(negativeWeight: 2)
        for query in [["red"], ["blue"], ["red", "green"], ["green", "blue"]] {
            XCTAssertEqual(
                try first.predict(tokens: query).score!, try doubled.predict(tokens: query).score!,
                accuracy: 1e-12)
        }
        let empty = try BinaryLSM()
        try empty.setExample(.init(id: "p", tokens: ["same"], isPositive: true))
        try empty.setExample(.init(id: "n", tokens: ["same"], isPositive: false))
        XCTAssertThrowsError(try empty.compile()) { XCTAssertEqual($0 as? LSMError, .noSignal) }
    }

    func testNumericalFixturesAgainstIndependentSVD() throws {
        struct Fixture: Decodable {
            let name: String
            let columns: [[Double]]
            let dimensions: Int
            let singularValues: [Double]
            let projector: [[Double]]
            let tolerance: Double
        }
        let url = Bundle.module.url(forResource: "svd", withExtension: "json", subdirectory: "Fixtures")!
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        for fixture in fixtures {
            let matrix = SemanticMatrix(
                rowCount: fixture.columns[0].count,
                columns: fixture.columns.map { vector in
                    vector.enumerated().compactMap { $1 == 0 ? nil : .init(row: $0, value: $1) }
                })
            let projection = try LowRankProjection.make(
                from: matrix, dimensions: fixture.dimensions, iterations: 4)
            XCTAssertEqual(projection.singularValues.count, fixture.singularValues.count, fixture.name)
            for (actual, expected) in zip(projection.singularValues, fixture.singularValues) {
                XCTAssertEqual(actual, expected, accuracy: fixture.tolerance, fixture.name)
            }
            for row in 0..<matrix.rowCount {
                for column in 0..<matrix.rowCount {
                    let actual = projection.basis.reduce(0) { $0 + $1[row] * $1[column] }
                    XCTAssertEqual(
                        actual, fixture.projector[row][column], accuracy: fixture.tolerance, fixture.name)
                }
            }
        }
    }
}
