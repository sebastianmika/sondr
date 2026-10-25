import GRDB

/// Per-dim corpus statistics. Raw dim values are stored per sample; the 5th and 95th percentile
/// of each dim live in `dim_stats` and are recomputed after an index batch. Normalising is done
/// when reading, so a batch never rewrites the whole `samples` table.
public enum DimStats {
    /// Raw values at or below `low` map to 0, at or above `high` to 1.
    public struct Range: Equatable, Sendable {
        public var low: Double
        public var high: Double

        /// Linear rescale of `value` to [0, 1], clipped. A degenerate range (all values equal)
        /// maps everything to 0.5.
        public func normalise(_ value: Double) -> Double {
            let span = high - low
            if span < AudioFeatures.epsilon { return 0.5 }
            return min(max((value - low) / span, 0), 1)
        }
    }

    /// Writes the six raw dims of a sample.
    public static func store(_ db: Database, sampleID: Int64, dims: RawDims) throws {
        let assignments = Dim.allCases.map { "\($0.column) = ?" }.joined(separator: ", ")
        let values = Dim.allCases.map { dims[$0] }
        try db.execute(
            sql: "UPDATE samples SET \(assignments) WHERE id = ?",
            arguments: StatementArguments(values) + [sampleID])
    }

    /// Recomputes p5/p95 of every dim over all samples that have a value (missing samples included:
    /// they are still in the library). With fewer than 5 values, min and max are used.
    public static func recompute(_ db: Database) throws {
        for dim in Dim.allCases {
            let values = try Double.fetchAll(
                db, sql: "SELECT \(dim.column) FROM samples WHERE \(dim.column) IS NOT NULL ORDER BY \(dim.column)")
            guard let first = values.first, let last = values.last else {
                try db.execute(sql: "DELETE FROM dim_stats WHERE dim = ?", arguments: [dim.rawValue])
                continue
            }
            let (low, high) = values.count < 5 ? (first, last) : (percentile(values, 5), percentile(values, 95))
            try db.execute(
                sql: """
                    INSERT INTO dim_stats (dim, p5, p95) VALUES (?, ?, ?)
                    ON CONFLICT(dim) DO UPDATE SET p5 = excluded.p5, p95 = excluded.p95
                    """, arguments: [dim.rawValue, low, high])
        }
    }

    /// Current ranges; dims without statistics are absent.
    public static func ranges(_ db: Database) throws -> [Dim: Range] {
        var result: [Dim: Range] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT dim, p5, p95 FROM dim_stats") {
            if let dim = Dim(rawValue: row["dim"]) { result[dim] = Range(low: row["p5"], high: row["p95"]) }
        }
        return result
    }

    /// Linear-interpolation percentile of sorted values (numpy's default method).
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        let position = Double(sorted.count - 1) * p / 100
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }
}
