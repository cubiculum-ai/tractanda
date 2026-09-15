import Foundation

/// Sparse columns of a term/composition matrix. Entries are ordered by term index.
struct SemanticMatrix {
    struct Entry {
        let row: Int
        let value: Double
    }
    let rowCount: Int
    let columns: [[Entry]]

    func multiplied(by vectors: [[Double]]) -> [[Double]] {
        var result = vectors.map { _ in [Double](repeating: 0, count: rowCount) }
        for (column, entries) in columns.enumerated() {
            for component in vectors.indices {
                let coefficient = vectors[component][column]
                for entry in entries { result[component][entry.row] += entry.value * coefficient }
            }
        }
        return result
    }

    func transposeMultiplied(by vectors: [[Double]]) -> [[Double]] {
        vectors.map { vector in
            columns.map { column in column.reduce(0) { $0 + $1.value * vector[$1.row] } }
        }
    }

    var squaredNorm: Double { columns.reduce(0) { $0 + $1.reduce(0) { $0 + $1.value * $1.value } } }
}

/// Fixed-seed subspace iteration and a one-sided Jacobi SVD on the compressed matrix.
/// All arithmetic is Swift Double; no Accelerate, BLAS or platform-specific runtime is required.
struct LowRankProjection {
    let basis: [[Double]]
    let singularValues: [Double]
    let capturedEnergyFraction: Double

    static func make(from matrix: SemanticMatrix, dimensions: Int, iterations: Int) throws -> Self {
        let width = min(dimensions + 8, matrix.rowCount, matrix.columns.count)
        guard width > 0, matrix.squaredNorm > 0 else { throw LSMError.noSignal }
        var basis: [[Double]]
        if width == matrix.columns.count {
            basis = matrix.columns.map { column in
                var vector = [Double](repeating: 0, count: matrix.rowCount)
                for entry in column { vector[entry.row] = entry.value }
                return vector
            }
        } else {
            var generator = SemanticRandomGenerator()
            let probes = (0..<width).map { _ in matrix.columns.map { _ in generator.normal() } }
            basis = matrix.multiplied(by: probes)
        }
        basis = orthonormalized(basis)
        for _ in 0..<iterations {
            let right = orthonormalized(matrix.transposeMultiplied(by: basis))
            basis = orthonormalized(matrix.multiplied(by: right))
        }
        guard !basis.isEmpty else { throw LSMError.noSignal }
        // (Q^T A)^T has only width columns. Jacobi avoids squaring its condition number.
        let decomposition = try jacobi(matrix.transposeMultiplied(by: basis))
        let largest = decomposition.singularValues.max() ?? 0
        let indices = decomposition.singularValues.indices.sorted {
            if decomposition.singularValues[$0] == decomposition.singularValues[$1] { return $0 < $1 }
            return decomposition.singularValues[$0] > decomposition.singularValues[$1]
        }.filter { decomposition.singularValues[$0] > largest * 1e-10 }.prefix(dimensions)
        guard !indices.isEmpty else { throw LSMError.noSignal }
        let left = indices.map { index in
            var vector = [Double](repeating: 0, count: matrix.rowCount)
            for component in basis.indices {
                let coefficient = decomposition.rotation[index][component]
                for row in vector.indices { vector[row] += coefficient * basis[component][row] }
            }
            return vector
        }
        let singularValues = indices.map { decomposition.singularValues[$0] }
        let captured = singularValues.reduce(0) { $0 + $1 * $1 } / matrix.squaredNorm
        guard captured.isFinite, captured <= 1 + 1e-8 else { throw LSMError.numericalFailure }
        return Self(basis: left, singularValues: singularValues, capturedEnergyFraction: min(1, captured))
    }

    static func dot(_ first: [Double], _ second: [Double]) -> Double {
        var result = 0.0
        for index in first.indices { result += first[index] * second[index] }
        return result
    }

    private static func orthonormalized(_ input: [[Double]]) -> [[Double]] {
        let scale = input.map { sqrt(dot($0, $0)) }.max() ?? 0
        guard scale > 0 else { return [] }
        var result: [[Double]] = []
        for var vector in input {
            // Reorthogonalize: a single Gram-Schmidt pass loses small singular directions.
            for _ in 0..<2 {
                for previous in result {
                    let coefficient = dot(vector, previous)
                    for row in vector.indices { vector[row] -= coefficient * previous[row] }
                }
            }
            let norm = sqrt(dot(vector, vector))
            if norm > scale * 1e-12 { result.append(vector.map { $0 / norm }) }
        }
        return result
    }

    private static func jacobi(_ input: [[Double]]) throws -> (singularValues: [Double], rotation: [[Double]])
    {
        var columns = input
        let count = columns.count
        var rotation = (0..<count).map { column in (0..<count).map { $0 == column ? 1.0 : 0.0 } }
        var hasConverged = count < 2
        for _ in 0..<80 where !hasConverged {
            hasConverged = true
            for first in 0..<count {
                for second in (first + 1)..<count {
                    let alpha = dot(columns[first], columns[first])
                    let beta = dot(columns[second], columns[second])
                    let gamma = dot(columns[first], columns[second])
                    guard alpha > 0, beta > 0, abs(gamma) > 1e-12 * sqrt(alpha * beta) else { continue }
                    hasConverged = false
                    let zeta = (beta - alpha) / (2 * gamma)
                    let tangent = (zeta >= 0 ? 1.0 : -1.0) / (abs(zeta) + hypot(1, zeta))
                    let cosine = 1 / sqrt(1 + tangent * tangent)
                    let sine = cosine * tangent
                    for row in columns[first].indices {
                        let left = columns[first][row]
                        let right = columns[second][row]
                        columns[first][row] = cosine * left - sine * right
                        columns[second][row] = sine * left + cosine * right
                    }
                    for row in 0..<count {
                        let left = rotation[first][row]
                        let right = rotation[second][row]
                        rotation[first][row] = cosine * left - sine * right
                        rotation[second][row] = sine * left + cosine * right
                    }
                }
            }
        }
        guard hasConverged else { throw LSMError.numericalFailure }
        return (columns.map { sqrt(dot($0, $0)) }, rotation)
    }
}

private struct SemanticRandomGenerator {
    private var state: UInt64 = 0x7472_6163_7461_6e64
    private mutating func uniform() -> Double {
        state &+= 0x9e37_79b9_7f4a_7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
        value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb
        value ^= value >> 31
        return (Double(value >> 11) + 0.5) / 9_007_199_254_740_992
    }
    mutating func normal() -> Double {
        let radius = sqrt(-2 * log(uniform()))
        return radius * cos(2 * Double.pi * uniform())
    }
}
