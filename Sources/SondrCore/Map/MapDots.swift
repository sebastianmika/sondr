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

    public var count: Int { ids.count }

    public init(ids: [Int64], x: [Float], y: [Float], cluster: [Int], fitted: [Bool]) {
        self.ids = ids
        self.x = x
        self.y = y
        self.cluster = cluster
        self.fitted = fitted
    }

    /// All points of a stored map, ordered by sample id.
    public static func load(_ db: Database, mapID: Int64) throws -> MapDots {
        var dots = MapDots(ids: [], x: [], y: [], cluster: [], fitted: [])
        let cursor = try Row.fetchCursor(
            db,
            sql: """
                SELECT map_points.sample_id, map_points.x, map_points.y, map_points.fitted,
                    samples.cluster_id, samples.cluster_score
                FROM map_points JOIN samples ON samples.id = map_points.sample_id
                WHERE map_points.map_id = ? ORDER BY map_points.sample_id
                """, arguments: [mapID])
        while let row = try cursor.next() {
            dots.ids.append(row["sample_id"])
            dots.x.append(Float(row["x"] as Double))
            dots.y.append(Float(row["y"] as Double))
            dots.fitted.append((row["fitted"] as Int) != 0)
            dots.cluster.append(clusterValue(row["cluster_id"], row["cluster_score"]))
        }
        return dots
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
