import Foundation
import GRDB
import MetalTSNE
import simd

/// One sample's place on a map.
public struct MapPoint: Equatable, Sendable {
    public let sampleID: Int64
    public let x: Float
    public let y: Float
    /// True if the sample was part of the fit; false if it was placed onto the map afterwards.
    public let fitted: Bool

    public init(sampleID: Int64, x: Float, y: Float, fitted: Bool) {
        self.sampleID = sampleID
        self.x = x
        self.y = y
        self.fitted = fitted
    }
}

/// Facts about a stored map.
public struct StoredMap: Equatable, Sendable, Identifiable {
    public let id: Int64
    public let createdAt: Date
    /// Embedding model the vectors came from; a map is only valid for that model.
    public let modelVersion: String
    public let parameters: MapParameters
    /// Samples the layout was computed from.
    public let fittedCount: Int
    /// All samples on the map, fitted or placed.
    public let pointCount: Int
    /// Samples on the map when it was built; later additions are placed ones.
    public let builtCount: Int

    /// How much the map has grown since it was built, as a fraction of its size then.
    public var growth: Double { builtCount > 0 ? Double(pointCount - builtCount) / Double(builtCount) : 0 }
}

/// Keeps the 2D map in the database: the current one and the one before it.
///
/// Saving a map makes it current and the old current the previous one; the map before that is
/// dropped. A map consists of its points and the fitted model, so that samples added later can be
/// placed onto it, also after a restart.
public enum MapStore {
    private static let currentKey = "map_current"
    private static let previousKey = "map_previous"

    public static func current(_ db: Database) throws -> StoredMap? { try map(db, key: currentKey) }
    public static func previous(_ db: Database) throws -> StoredMap? { try map(db, key: previousKey) }

    /// Writes a new map and makes it current. All or nothing.
    @discardableResult
    public static func save(
        _ db: Database, state: TSNEModelState, parameters: MapParameters, modelVersion: String, points: [MapPoint]
    ) throws -> Int64 {
        try db.inSavepoint {
            let json = String(data: try JSONEncoder().encode(parameters), encoding: .utf8) ?? "{}"
            try db.execute(
                sql: """
                    INSERT INTO maps (created_at, model_version, parameters, fitted_count, input_dims, work_dims,
                        ref_embedding, ref_work, pca_dim, pca_count, pca_mean, pca_components, built_count)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    Date().timeIntervalSince1970, modelVersion, json, state.embedding.count, state.inputDimensions,
                    state.workDimensions, floatData(state.embedding.flatMap { [$0.x, $0.y] }), floatData(state.referenceWork),
                    state.pca?.dim, state.pca?.componentCount, state.pca.map { floatData($0.mean) },
                    state.pca.map { floatData($0.components) }, points.count,
                ])
            let id = db.lastInsertedRowID
            try insert(db, mapID: id, points: points)

            if let old = try metaID(db, previousKey) { try db.execute(sql: "DELETE FROM maps WHERE id = ?", arguments: [old]) }
            if let current = try metaID(db, currentKey) { try setMeta(db, previousKey, current) } else { try clearMeta(db, previousKey) }
            try setMeta(db, currentKey, id)
            return .commit
        }
        return try metaID(db, currentKey)!
    }

    /// Swaps the current and previous maps. Returns false if there is no previous map.
    @discardableResult
    public static func restorePrevious(_ db: Database) throws -> Bool {
        guard let previous = try metaID(db, previousKey) else { return false }
        let current = try metaID(db, currentKey)
        try setMeta(db, currentKey, previous)
        if let current { try setMeta(db, previousKey, current) } else { try clearMeta(db, previousKey) }
        return true
    }

    /// The fitted model of a map, or nil if the map or its data is gone.
    public static func modelState(_ db: Database, mapID: Int64) throws -> TSNEModelState? {
        guard
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT input_dims, work_dims, ref_embedding, ref_work, pca_dim, pca_count, pca_mean, pca_components
                    FROM maps WHERE id = ?
                    """, arguments: [mapID])
        else { return nil }
        let flat = floats(row["ref_embedding"] as Data)
        let pca: TSNEPCAState? = (row["pca_dim"] as Int?).flatMap { dim in
            (row["pca_count"] as Int?).map {
                TSNEPCAState(
                    mean: floats(row["pca_mean"] as Data), components: floats(row["pca_components"] as Data), dim: dim,
                    componentCount: $0)
            }
        }
        return TSNEModelState(
            embedding: stride(from: 0, to: flat.count - 1, by: 2).map { SIMD2(flat[$0], flat[$0 + 1]) },
            referenceWork: floats(row["ref_work"] as Data), workDimensions: row["work_dims"],
            inputDimensions: row["input_dims"], pca: pca)
    }

    public static func points(_ db: Database, mapID: Int64) throws -> [MapPoint] {
        try Row.fetchAll(db, sql: "SELECT sample_id, x, y, fitted FROM map_points WHERE map_id = ?", arguments: [mapID]).map {
            MapPoint(sampleID: $0["sample_id"], x: Float($0["x"] as Double), y: Float($0["y"] as Double), fitted: ($0["fitted"] as Int) != 0)
        }
    }

    /// Adds placed (not fitted) points to an existing map.
    public static func addPoints(_ db: Database, mapID: Int64, points: [MapPoint]) throws {
        try insert(db, mapID: mapID, points: points)
    }

    /// Indexed, present samples that have no point on the map yet.
    public static func unmappedSampleIDs(_ db: Database, mapID: Int64, after: Int64 = 0, limit: Int) throws -> [Int64] {
        try Int64.fetchAll(
            db,
            sql: """
                SELECT id FROM samples
                WHERE embed_state = 'done' AND missing = 0 AND id > ?
                    AND id NOT IN (SELECT sample_id FROM map_points WHERE map_id = ?)
                ORDER BY id LIMIT ?
                """, arguments: [after, mapID, limit])
    }

    public static func deleteAll(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM maps")
        try clearMeta(db, currentKey)
        try clearMeta(db, previousKey)
    }

    // MARK: Helpers

    private static func map(_ db: Database, key: String) throws -> StoredMap? {
        guard let id = try metaID(db, key),
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT created_at, model_version, parameters, fitted_count, built_count,
                        (SELECT count(*) FROM map_points WHERE map_id = maps.id) AS total
                    FROM maps WHERE id = ?
                    """, arguments: [id])
        else { return nil }
        let json: String = row["parameters"]
        return StoredMap(
            id: id, createdAt: Date(timeIntervalSince1970: row["created_at"]), modelVersion: row["model_version"],
            parameters: (try? JSONDecoder().decode(MapParameters.self, from: Data(json.utf8))) ?? MapParameters(),
            fittedCount: row["fitted_count"], pointCount: row["total"], builtCount: (row["built_count"] as Int?) ?? row["total"])
    }

    private static func insert(_ db: Database, mapID: Int64, points: [MapPoint]) throws {
        let statement = try db.cachedStatement(
            sql: "INSERT OR REPLACE INTO map_points (map_id, sample_id, x, y, fitted) VALUES (?, ?, ?, ?, ?)")
        for p in points {
            try statement.execute(arguments: [mapID, p.sampleID, Double(p.x), Double(p.y), p.fitted ? 1 : 0])
        }
    }

    private static func metaID(_ db: Database, _ key: String) throws -> Int64? {
        try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key]).flatMap(Int64.init)
    }

    private static func setMeta(_ db: Database, _ key: String, _ id: Int64) throws {
        try db.execute(
            sql: "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            arguments: [key, String(id)])
    }

    private static func clearMeta(_ db: Database, _ key: String) throws {
        try db.execute(sql: "DELETE FROM meta WHERE key = ?", arguments: [key])
    }

    private static func floatData(_ values: [Float]) -> Data { values.withUnsafeBytes { Data($0) } }

    private static func floats(_ data: Data) -> [Float] {
        data.withUnsafeBytes { raw in
            (0..<(data.count / 4)).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
        }
    }
}
