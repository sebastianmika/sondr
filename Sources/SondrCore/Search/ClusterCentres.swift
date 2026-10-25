import Foundation
import GRDB

public struct ClusterDefinition: Decodable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let color: String
    public let keywords: [String]

    /// The text that is embedded to get the cluster centre.
    public var prompt: String { keywords.joined(separator: " ") }
}

public enum ClusterError: Error, Equatable, LocalizedError {
    case catalogMissing
    case catalogInvalid(String)

    public var errorDescription: String? {
        switch self {
        case .catalogMissing: return "clusters.json is missing from the app bundle."
        case .catalogInvalid(let why): return "clusters.json is invalid: \(why)"
        }
    }
}

/// The eight fixed categories and their centre vectors.
///
/// Ids are 0...7 everywhere (the legacy app stored 1...8 against ids 0...7). A centre is the
/// text embedding of a category's keyword bag; centres are computed once per model version and
/// cached in `cluster_centres`.
public enum ClusterCentres {
    public static func catalog() throws -> [ClusterDefinition] {
        guard let url = Bundle.module.url(forResource: "clusters", withExtension: "json", subdirectory: "Clusters"),
            let data = try? Data(contentsOf: url)
        else { throw ClusterError.catalogMissing }
        let clusters: [ClusterDefinition]
        do { clusters = try JSONDecoder().decode([ClusterDefinition].self, from: data) } catch {
            throw ClusterError.catalogInvalid(error.localizedDescription)
        }
        guard clusters.map(\.id) == Array(0..<clusters.count), !clusters.isEmpty else {
            throw ClusterError.catalogInvalid("ids must be 0...\(clusters.count - 1) in order")
        }
        return clusters
    }

    /// Makes sure `clusters` has the catalog's rows and `cluster_centres` has a centre for each
    /// of them for `embedder`'s model version. Centres of other model versions are deleted.
    /// Returns the centres by cluster id.
    @discardableResult
    public static func ensure(database: LibraryDatabase, embedder: any Embedder) async throws -> [Int: [Float]] {
        let catalog = try catalog()
        let version = try await embedder.modelVersion()
        try await database.writer.write { db in
            for cluster in catalog {
                try db.execute(
                    sql: """
                        INSERT INTO clusters (id, name, color) VALUES (?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET name = excluded.name, color = excluded.color
                        """, arguments: [cluster.id, cluster.name, cluster.color])
            }
            try db.execute(sql: "DELETE FROM cluster_centres WHERE model_version != ?", arguments: [version])
        }
        var centres = try await database.writer.read { try load($0, modelVersion: version) }
        for cluster in catalog where centres[cluster.id] == nil {
            let vector = try await embedder.embed(text: cluster.prompt)
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
