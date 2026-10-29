import Foundation
import GRDB

/// What the map view draws: one dot per sample, as parallel arrays so that 250k dots stay cheap.
public struct MapDots: Equatable, Sendable {
    public var ids: [Int64]
    public var x: [Float]
    public var y: [Float]
    /// Cluster id of each sample; -1 if it is unsorted (weak match) or has none.
    public var cluster: [Int]
    /// Whether the sample was part of the fit, as opposed to placed onto the map afterwards.
    public var fitted: [Bool]
    /// Each dim of each sample, scaled to 0...1 with the corpus statistics (see ``DimStats``); NaN if unknown.
    /// Empty when the dims were not loaded.
    public var dimensions: [Dim: [Float]]

    public var count: Int { ids.count }

    public init(ids: [Int64], x: [Float], y: [Float], cluster: [Int], fitted: [Bool], dimensions: [Dim: [Float]] = [:]) {
        self.ids = ids
        self.x = x
        self.y = y
        self.cluster = cluster
        self.fitted = fitted
        self.dimensions = dimensions
    }

    /// The dots with `cluster` replaced by a position on ``ColourRamp`` (0 to 255; -1 if unknown), so the
    /// raster draws them with ``ColourRamp/table`` instead of the cluster colours.
    public func recoloured(by dim: Dim) -> MapDots {
        var dots = self
        let values = dimensions[dim] ?? [Float](repeating: .nan, count: count)
        dots.cluster = values.map { $0.isNaN ? -1 : Int((min(max($0, 0), 1) * 255).rounded()) }
        return dots
    }

    /// The same dots with each axis replaced by the dot's rank share (0 to 1), which spreads them evenly
    /// over the frame. Distances stop meaning anything; neighbours stay neighbours. Equal values stay equal.
    public func rankWarped() -> MapDots {
        var warped = self
        warped.x = Self.rankShares(x)
        warped.y = Self.rankShares(y)
        return warped
    }

    static func rankShares(_ values: [Float]) -> [Float] {
        let order = values.indices.sorted { values[$0] < values[$1] }
        var shares = [Float](repeating: 0, count: values.count)
        var start = 0
        while start < order.count {
            var end = start
            while end + 1 < order.count, values[order[end + 1]] == values[order[start]] { end += 1 }
            let share = (Float(start) + 0.5) / Float(order.count)
            for i in start...end { shares[order[i]] = share }
            start = end + 1
        }
        return shares
    }

    /// All points of a stored map, ordered by sample id.
    public static func load(_ db: Database, mapID: Int64) throws -> MapDots {
        var dots = MapDots(ids: [], x: [], y: [], cluster: [], fitted: [])
        let ranges = try DimStats.ranges(db)
        for dim in Dim.allCases { dots.dimensions[dim] = [] }
        let cursor = try Row.fetchCursor(
            db,
            sql: """
                SELECT map_points.sample_id, map_points.x, map_points.y, map_points.fitted,
                    samples.cluster_id, samples.cluster_score, \(dimColumns)
                FROM map_points JOIN samples ON samples.id = map_points.sample_id
                WHERE map_points.map_id = ? ORDER BY map_points.sample_id
                """, arguments: [mapID])
        while let row = try cursor.next() {
            dots.ids.append(row["sample_id"])
            dots.x.append(Float(row["x"] as Double))
            dots.y.append(Float(row["y"] as Double))
            dots.fitted.append((row["fitted"] as Int) != 0)
            dots.cluster.append(clusterValue(row["cluster_id"], row["cluster_score"]))
            for dim in Dim.allCases { dots.dimensions[dim]!.append(scaled(row[dim.column], dim, ranges)) }
        }
        return dots
    }

    private static var dimColumns: String { Dim.allCases.map { "samples.\($0.column)" }.joined(separator: ", ") }

    private static func scaled(_ value: Double?, _ dim: Dim, _ ranges: [Dim: DimStats.Range]) -> Float {
        guard let value, let range = ranges[dim] else { return .nan }
        return Float(range.normalise(value))
    }

    /// Cluster and scaled dims of each of `ids`, in that order; -1 and NaN for unknown samples.
    public static func annotations(_ db: Database, for ids: [Int64]) throws -> (cluster: [Int], dimensions: [Dim: [Float]]) {
        let ranges = try DimStats.ranges(db)
        var found: [Int64: Row] = [:]
        for start in stride(from: 0, to: ids.count, by: 500) {
            let batch = Array(ids[start..<min(start + 500, ids.count)])
            let marks = batch.map { _ in "?" }.joined(separator: ",")
            for row in try Row.fetchAll(
                db, sql: "SELECT id, cluster_id, cluster_score, \(dimColumns.replacingOccurrences(of: "samples.", with: "")) FROM samples WHERE id IN (\(marks))",
                arguments: StatementArguments(batch))
            {
                found[row["id"]] = row
            }
        }
        var dimensions: [Dim: [Float]] = [:]
        for dim in Dim.allCases { dimensions[dim] = ids.map { id in found[id].map { scaled($0[dim.column], dim, ranges) } ?? .nan } }
        return (ids.map { id in found[id].map { clusterValue($0["cluster_id"], $0["cluster_score"]) } ?? -1 }, dimensions)
    }

    /// Cluster of each of `ids`, in that order; -1 for unsorted, unknown or missing samples.
    public static func clusterIDs(_ db: Database, for ids: [Int64]) throws -> [Int] {
        var found: [Int64: Int] = [:]
        for start in stride(from: 0, to: ids.count, by: 500) {
            let batch = Array(ids[start..<min(start + 500, ids.count)])
            let marks = batch.map { _ in "?" }.joined(separator: ",")
            for row in try Row.fetchAll(
                db, sql: "SELECT id, cluster_id, cluster_score FROM samples WHERE id IN (\(marks))",
                arguments: StatementArguments(batch))
            {
                found[row["id"]] = clusterValue(row["cluster_id"], row["cluster_score"])
            }
        }
        return ids.map { found[$0] ?? -1 }
    }

    private static func clusterValue(_ id: Int?, _ score: Double?) -> Int {
        guard let id, !ClusterAssigner.isUnsorted(score: score) else { return -1 }
        return id
    }
}
