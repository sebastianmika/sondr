import Foundation

/// A symmetric, normalized sparse affinity matrix in compressed sparse row
/// (CSR) form.
///
/// Every undirected relationship is stored twice: once in each direction. The
/// sum of all directed values is therefore approximately one. Rows may be in
/// any column order, but self-edges, negative values, and non-finite values are
/// rejected.
public struct TSNEAffinityGraph: Sendable {
    /// Absolute component of the tolerance used when comparing reciprocal
    /// directed edges. A relative tolerance is added for larger values.
    public static let symmetryAbsoluteTolerance: Float = 1e-7

    /// Relative component of the tolerance used when comparing reciprocal
    /// directed edges.
    public static let symmetryRelativeTolerance: Float = 1e-4

    /// Allowed absolute error in the sum of all directed values.
    public static let normalizationTolerance: Double = 1e-4

    public let pointCount: Int
    public let rowOffsets: [UInt32]
    public let columnIndices: [UInt32]
    public let values: [Float]

    public init(
        pointCount: Int,
        rowOffsets: [UInt32],
        columnIndices: [UInt32],
        values: [Float]
    ) throws {
        guard pointCount > 0 else {
            throw TSNEError.invalidInput("an affinity graph must contain at least one point")
        }
        guard pointCount <= Int(UInt32.max) else {
            throw TSNEError.invalidInput("affinity pointCount must fit in UInt32")
        }
        guard pointCount < Int.max, rowOffsets.count == pointCount + 1 else {
            throw TSNEError.invalidInput(
                "affinity rowOffsets must contain pointCount + 1 entries")
        }
        guard columnIndices.count == values.count else {
            throw TSNEError.invalidInput(
                "affinity columnIndices and values must have the same length")
        }
        guard values.count <= Int(UInt32.max) else {
            throw TSNEError.invalidInput("an affinity graph cannot contain more than UInt32.max entries")
        }
        guard rowOffsets.first == 0,
              rowOffsets.last == UInt32(values.count) else {
            throw TSNEError.invalidInput(
                "affinity rowOffsets must start at zero and end at the stored edge count")
        }

        for row in 0..<pointCount {
            guard rowOffsets[row] <= rowOffsets[row + 1] else {
                throw TSNEError.invalidInput(
                    "affinity rowOffsets must be nondecreasing (row \(row))")
            }
        }

        var sum = 0.0
        var rowsAreCanonical = true

        for row in 0..<pointCount {
            let start = Int(rowOffsets[row])
            let end = Int(rowOffsets[row + 1])
            var previousColumn: UInt32?
            for index in start..<end {
                let storedColumn = columnIndices[index]
                let column = Int(storedColumn)
                guard column < pointCount else {
                    throw TSNEError.invalidInput(
                        "affinity column index \(column) in row \(row) is outside 0..<\(pointCount)")
                }
                guard column != row else {
                    throw TSNEError.invalidInput(
                        "affinity graph contains a self-edge at point \(row)")
                }
                let value = values[index]
                guard value.isFinite, value >= 0 else {
                    throw TSNEError.invalidInput(
                        "affinity value at stored edge \(index) must be finite and nonnegative")
                }
                if let previousColumn, storedColumn <= previousColumn {
                    rowsAreCanonical = false
                }
                previousColumn = storedColumn
                sum += Double(value)
            }
        }

        // A one-point problem has no legal edges; its empty graph is the sole
        // exception to the usual sum-to-one rule.
        if pointCount == 1 && values.isEmpty {
            sum = 1
        }
        guard abs(sum - 1) <= Self.normalizationTolerance else {
            throw TSNEError.invalidInput(
                "affinity values must sum to 1 (received \(sum))")
        }

        func validateSymmetry(row: UInt32, column: UInt32, value: Double, reverse: Double) throws {
            let tolerance = Double(Self.symmetryAbsoluteTolerance)
                + Double(Self.symmetryRelativeTolerance) * max(abs(value), abs(reverse))
            guard abs(value - reverse) <= tolerance else {
                throw TSNEError.invalidInput(
                    "affinity values for points \(row) and \(column) are not symmetric")
            }
        }

        if rowsAreCanonical {
            // Canonical CSR needs no auxiliary edge map: reciprocal values are
            // found directly by binary search in the opposite sorted row.
            func value(in row: Int, column: UInt32) -> Double {
                var lower = Int(rowOffsets[row])
                var upper = Int(rowOffsets[row + 1])
                while lower < upper {
                    let middle = lower + (upper - lower) / 2
                    if columnIndices[middle] < column {
                        lower = middle + 1
                    } else {
                        upper = middle
                    }
                }
                guard lower < Int(rowOffsets[row + 1]),
                      columnIndices[lower] == column else { return 0 }
                return Double(values[lower])
            }

            for row in 0..<pointCount {
                for index in Int(rowOffsets[row])..<Int(rowOffsets[row + 1]) {
                    let column = columnIndices[index]
                    try validateSymmetry(
                        row: UInt32(row), column: column,
                        value: Double(values[index]),
                        reverse: value(in: Int(column), column: UInt32(row)))
                }
            }
        } else {
            // Unsorted and duplicate rows remain valid. Canonicalize one row at
            // a time into compact arrays rather than retaining a global hash
            // table whose overhead dominates multi-million-edge graphs.
            var canonicalOffsets: [Int] = [0]
            canonicalOffsets.reserveCapacity(pointCount + 1)
            var canonicalColumns: [UInt32] = []
            var canonicalValues: [Double] = []
            canonicalColumns.reserveCapacity(columnIndices.count)
            canonicalValues.reserveCapacity(values.count)

            for row in 0..<pointCount {
                var pairs: [(column: UInt32, value: Double)] = []
                pairs.reserveCapacity(Int(rowOffsets[row + 1] - rowOffsets[row]))
                for index in Int(rowOffsets[row])..<Int(rowOffsets[row + 1]) {
                    pairs.append((columnIndices[index], Double(values[index])))
                }
                pairs.sort { $0.column < $1.column }
                var index = 0
                while index < pairs.count {
                    let column = pairs[index].column
                    var value = pairs[index].value
                    index += 1
                    while index < pairs.count, pairs[index].column == column {
                        value += pairs[index].value
                        index += 1
                    }
                    canonicalColumns.append(column)
                    canonicalValues.append(value)
                }
                canonicalOffsets.append(canonicalColumns.count)
            }

            func canonicalValue(in row: Int, column: UInt32) -> Double {
                var lower = canonicalOffsets[row]
                var upper = canonicalOffsets[row + 1]
                while lower < upper {
                    let middle = lower + (upper - lower) / 2
                    if canonicalColumns[middle] < column {
                        lower = middle + 1
                    } else {
                        upper = middle
                    }
                }
                guard lower < canonicalOffsets[row + 1],
                      canonicalColumns[lower] == column else { return 0 }
                return canonicalValues[lower]
            }

            for row in 0..<pointCount {
                for index in canonicalOffsets[row]..<canonicalOffsets[row + 1] {
                    let column = canonicalColumns[index]
                    try validateSymmetry(
                        row: UInt32(row), column: column,
                        value: canonicalValues[index],
                        reverse: canonicalValue(in: Int(column), column: UInt32(row)))
                }
            }
        }

        self.pointCount = pointCount
        self.rowOffsets = rowOffsets
        self.columnIndices = columnIndices
        self.values = values
    }
}

extension TSNEAffinityGraph {
    /// Trusted internal path for `Affinities.build`, whose construction already
    /// guarantees canonical bounds, symmetry, and normalization. Avoiding the
    /// public validator's edge dictionary is important for multi-million-edge
    /// prepared problems.
    init(pointCount: Int, sparseAffinities: SparseAffinities) {
        self.pointCount = pointCount
        self.rowOffsets = sparseAffinities.rowStart
        self.columnIndices = sparseAffinities.colIndex
        self.values = sparseAffinities.values
    }
}
