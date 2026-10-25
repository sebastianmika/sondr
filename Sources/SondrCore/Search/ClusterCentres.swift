import Foundation
import GRDB

public struct ClusterDefinition: Equatable, Sendable, Identifiable {
    /// Negative for a cluster that is not saved yet (see ``ClusterReassignJob/commit(_:edited:)``).
    public var id: Int
    public var name: String
    /// `#RRGGBB`.
    public var color: String
    /// Words separated by spaces; their text embedding is the cluster centre.
    public var keywords: String

    public init(id: Int, name: String, color: String, keywords: String) {
        self.id = id
        self.name = name
        self.color = color
        self.keywords = keywords
    }
}

public enum ClusterError: Error, Equatable, LocalizedError {
    case catalogMissing
    case catalogInvalid(String)
    /// The clusters would be empty, or one has no name.
    case invalidEdit(String)
    /// An earlier cluster change has not been applied to all samples yet.
    case pending

    public var errorDescription: String? {
        switch self {
        case .catalogMissing: return "clusters.json is missing from the app bundle."
        case .catalogInvalid(let why): return "clusters.json is invalid: \(why)"
        case .invalidEdit(let why): return why
        case .pending: return "An earlier change of the clusters is still being applied."
        }
    }
}

/// The clusters and their centre vectors.
///
/// The `clusters` table is the truth and the user edits it. The bundled `clusters.json` only seeds
/// it while the table is empty. A centre is the text embedding of a cluster's keywords; centres
/// are computed once per model version and cached in `cluster_centres`.
public enum ClusterCentres {
    private struct SeedEntry: Decodable {
        let id: Int
        let name: String
        let color: String
        let keywords: [String]
    }

    /// The clusters a new library starts with.
    public static func seed() throws -> [ClusterDefinition] {
        guard let url = Bundle.module.url(forResource: "clusters", withExtension: "json", subdirectory: "Clusters"),
            let data = try? Data(contentsOf: url)
        else { throw ClusterError.catalogMissing }
        do {
            return try JSONDecoder().decode([SeedEntry].self, from: data).map {
                ClusterDefinition(id: $0.id, name: $0.name, color: $0.color, keywords: $0.keywords.joined(separator: " "))
            }
        } catch {
            throw ClusterError.catalogInvalid(error.localizedDescription)
        }
    }

    public static func definitions(_ db: Database) throws -> [ClusterDefinition] {
        try Row.fetchAll(db, sql: "SELECT id, name, color, keywords FROM clusters ORDER BY id").map {
            ClusterDefinition(id: $0["id"], name: $0["name"], color: $0["color"], keywords: $0["keywords"])
        }
    }

    /// Fills an empty `clusters` table from the bundled seed and makes sure `cluster_centres` has a
    /// centre for every cluster for `embedder`'s model version; only missing ones are computed.
    /// Rows the user edited are never overwritten. Centres of other model versions are deleted.
    /// Returns the centres by cluster id.
    @discardableResult
    public static func ensure(database: LibraryDatabase, embedder: any Embedder) async throws -> [Int: [Float]] {
        let seed = try seed()
        let version = try await embedder.modelVersion()
        let clusters = try await database.writer.write { db -> [ClusterDefinition] in
            if try Int.fetchOne(db, sql: "SELECT count(*) FROM clusters")! == 0 {
                for cluster in seed {
                    try db.execute(
                        sql: "INSERT INTO clusters (id, name, color, keywords) VALUES (?, ?, ?, ?)",
                        arguments: [cluster.id, cluster.name, cluster.color, cluster.keywords])
                }
            }
            try db.execute(sql: "DELETE FROM cluster_centres WHERE model_version != ?", arguments: [version])
            return try definitions(db)
        }
        var centres = try await database.writer.read { try load($0, modelVersion: version) }
        for cluster in clusters where centres[cluster.id] == nil {
            let vector = try await embedder.embed(text: cluster.keywords)
            try await database.writer.write { db in
                try db.execute(
                    sql: "INSERT OR REPLACE INTO cluster_centres (cluster_id, model_version, vector) VALUES (?, ?, ?)",
                    arguments: [cluster.id, version, encode(vector)])
            }
            centres[cluster.id] = vector
        }
        return centres
    }

    public static func load(_ db: Database, modelVersion: String) throws -> [Int: [Float]] {
        var result: [Int: [Float]] = [:]
        let rows = try Row.fetchAll(
            db, sql: "SELECT cluster_id, vector FROM cluster_centres WHERE model_version = ?", arguments: [modelVersion])
        for row in rows {
            let data: Data = row["vector"]
            if let vector = decode(data) { result[row["cluster_id"]] = vector }
        }
        return result
    }

    static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decode(_ data: Data) -> [Float]? {
        guard data.count == EmbeddingService.embeddingSize * MemoryLayout<Float>.size else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
