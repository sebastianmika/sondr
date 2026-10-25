import GRDB

public struct ClusterInfo: Equatable, Sendable, Identifiable {
    public let id: Int
    public let name: String
    /// `#RRGGBB`.
    public let color: String
    /// Words whose text embedding is the cluster centre, separated by spaces.
    public let keywords: String
    /// Present samples assigned here with a score at or above the unsorted threshold.
    public let count: Int
}

extension LibraryInfo {
    /// The clusters with their counts, plus the number of finished, present samples shown as unsorted.
    public static func clusters(_ db: Database) throws -> (clusters: [ClusterInfo], unsorted: Int) {
        let threshold = Double(ClusterAssigner.unsortedThreshold)
        let clusters = try Row.fetchAll(
            db,
            sql: """
                SELECT clusters.id, clusters.name, clusters.color, clusters.keywords,
                    (SELECT count(*) FROM samples WHERE cluster_id = clusters.id AND cluster_score >= ? AND missing = 0) AS n
                FROM clusters ORDER BY clusters.id
                """, arguments: [threshold]
        ).map { ClusterInfo(id: $0["id"], name: $0["name"], color: $0["color"], keywords: $0["keywords"], count: $0["n"]) }
        let unsorted = try Int.fetchOne(
            db,
            sql: """
                SELECT count(*) FROM samples WHERE embed_state = 'done' AND missing = 0
                    AND (cluster_id IS NULL OR cluster_score IS NULL OR cluster_score < ?)
                """, arguments: [threshold])!
        return (clusters, unsorted)
    }
}
