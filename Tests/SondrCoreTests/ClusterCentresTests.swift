import Foundation
import GRDB
import Testing

@testable import SondrCore

private final class TextStub: Embedder, @unchecked Sendable {
    private let lock = NSLock()
    private var _prompts: [String] = []
    let version: String

    init(version: String = "stub-1") { self.version = version }

    var prompts: [String] { lock.withLock { _prompts } }

    func modelVersion() async throws -> String { version }
    func embed(audio clips: [[Float]]) async throws -> [[Float]] { clips.map { _ in [Float](repeating: 0, count: 512) } }

    func embed(text: String) async throws -> [Float] {
        lock.withLock { _prompts.append(text) }
        var v = [Float](repeating: 0, count: 512)
        v[abs(text.hashValue) % 512] = 1
        return v
    }
}

@Test func catalogHasEightZeroBasedClusters() throws {
    let catalog = try ClusterCentres.catalog()
    #expect(catalog.map(\.id) == Array(0..<8))
    #expect(catalog.map(\.name) == ["kicks", "snares", "hats/perc", "bass", "pads", "leads", "vox chops", "fx/risers"])
}

@Test func keywordBagsOfBassPadsAndLeadsDoNotStartWithDrums() throws {
    let catalog = try ClusterCentres.catalog()
    for name in ["bass", "pads", "leads"] {
        let bag = try #require(catalog.first { $0.name == name }).keywords
        #expect(!bag.contains("drums"), "\(name) bag has 'drums' (legacy bug)")
    }
    #expect(catalog[0].prompt == "drums kick deep boom thump")
}

@Test func ensureCreatesClustersAndOneCentrePerCluster() async throws {
    let database = try LibraryDatabase(inMemory: ())
    let embedder = TextStub()
    let centres = try await ClusterCentres.ensure(database: database, embedder: embedder)

    #expect(Set(centres.keys) == Set(0..<8))
    let ids = try await database.writer.read { try Int.fetchAll($0, sql: "SELECT id FROM clusters ORDER BY id") }
    #expect(ids == Array(0..<8))
    let stored = try await database.writer.read { try ClusterCentres.load($0, modelVersion: "stub-1") }
    #expect(stored == centres)
    #expect(embedder.prompts.count == 8)
}

@Test func centresAreComputedOncePerModelVersion() async throws {
    let database = try LibraryDatabase(inMemory: ())
    let embedder = TextStub()
    _ = try await ClusterCentres.ensure(database: database, embedder: embedder)
    _ = try await ClusterCentres.ensure(database: database, embedder: embedder)
    #expect(embedder.prompts.count == 8)  // second call used the cache

    let newer = TextStub(version: "stub-2")
    _ = try await ClusterCentres.ensure(database: database, embedder: newer)
    #expect(newer.prompts.count == 8)
    let versions = try await database.writer.read { try String.fetchAll($0, sql: "SELECT DISTINCT model_version FROM cluster_centres") }
    #expect(versions == ["stub-2"])  // old version removed
}

@Test func missingCentreIsFilledInWithoutRecomputingTheOthers() async throws {
    let database = try LibraryDatabase(inMemory: ())
    let embedder = TextStub()
    _ = try await ClusterCentres.ensure(database: database, embedder: embedder)
    try await database.writer.write { try $0.execute(sql: "DELETE FROM cluster_centres WHERE cluster_id = 3") }
    let centres = try await ClusterCentres.ensure(database: database, embedder: embedder)
    #expect(centres.count == 8)
    #expect(embedder.prompts.count == 9)
}

@Test func clusterReferencesOutsideTheCatalogAreRejectedByTheDatabase() async throws {
    let database = try LibraryDatabase(inMemory: ())
    _ = try await ClusterCentres.ensure(database: database, embedder: TextStub())
    await #expect(throws: DatabaseError.self) {
        try await database.writer.write { db in
            try db.execute(sql: "INSERT INTO cluster_centres (cluster_id, model_version, vector) VALUES (8, 'x', x'00')")
        }
    }
}
