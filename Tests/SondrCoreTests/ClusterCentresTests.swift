import Foundation
import GRDB
import Testing

@testable import SondrCore

final class TextStub: Embedder, @unchecked Sendable {
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

@Test func seedHasFourteenZeroBasedClusters() throws {
    let seed = try ClusterCentres.seed()
    #expect(seed.map(\.id) == Array(0..<14))
    #expect(seed.map(\.name) == ["Kicks", "Snares & Claps", "Hi-Hats & Cymbals", "Percussion", "Drum Loops", "Bass", "Synth Notes", "Chords & Stabs", "Pads & Drones", "Keys & Organs", "Brass, Strings & Guitar", "Vocals", "FX & Risers", "Textures & Foley"])
    #expect(seed.allSatisfy { ClusterPalette.RGB(hex: $0.color) != nil })
}

@Test func keywordsOfBassSynthNotesAndPadsDoNotStartWithDrums() throws {
    let seed = try ClusterCentres.seed()
    for name in ["Bass", "Synth Notes", "Pads & Drones"] {
        let bag = try #require(seed.first { $0.name == name }).keywords
        #expect(!bag.hasPrefix("drums"), "\(name) bag has 'drums' (legacy bug)")
    }
    #expect(seed[0].keywords == "a deep, punchy electronic kick drum hit with a low thump")
}

@Test func ensureSeedsAnEmptyTableAndComputesOneCentrePerCluster() async throws {
    let database = try LibraryDatabase(inMemory: ())
    let embedder = TextStub()
    let centres = try await ClusterCentres.ensure(database: database, embedder: embedder)

    #expect(Set(centres.keys) == Set(0..<14))
    let ids = try await database.writer.read { try Int.fetchAll($0, sql: "SELECT id FROM clusters ORDER BY id") }
    #expect(ids == Array(0..<14))
    let stored = try await database.writer.read { try ClusterCentres.load($0, modelVersion: "stub-1") }
    #expect(stored == centres)
    #expect(embedder.prompts.count == 14)
}

@Test func ensureNeverOverwritesOrReseedsUserRows() async throws {
    let database = try LibraryDatabase(inMemory: ())
    try await database.writer.write {
        try $0.execute(sql: "INSERT INTO clusters (id, name, color, keywords) VALUES (5, 'mine', '#112233', 'foo bar')")
    }
    let embedder = TextStub()
    let centres = try await ClusterCentres.ensure(database: database, embedder: embedder)
    #expect(Set(centres.keys) == [5])
    #expect(embedder.prompts == ["foo bar"])
    let rows = try await database.writer.read { try ClusterCentres.definitions($0) }
    #expect(rows == [ClusterDefinition(id: 5, name: "mine", color: "#112233", keywords: "foo bar")])
}

@Test func centresAreComputedOncePerModelVersion() async throws {
    let database = try LibraryDatabase(inMemory: ())
    let embedder = TextStub()
    _ = try await ClusterCentres.ensure(database: database, embedder: embedder)
    _ = try await ClusterCentres.ensure(database: database, embedder: embedder)
    #expect(embedder.prompts.count == 14)  // second call used the cache

    let newer = TextStub(version: "stub-2")
    _ = try await ClusterCentres.ensure(database: database, embedder: newer)
    #expect(newer.prompts.count == 14)
    let versions = try await database.writer.read { try String.fetchAll($0, sql: "SELECT DISTINCT model_version FROM cluster_centres") }
    #expect(versions == ["stub-2"])  // old version removed
}

@Test func missingCentreIsFilledInWithoutRecomputingTheOthers() async throws {
    let database = try LibraryDatabase(inMemory: ())
    let embedder = TextStub()
    _ = try await ClusterCentres.ensure(database: database, embedder: embedder)
    try await database.writer.write { try $0.execute(sql: "DELETE FROM cluster_centres WHERE cluster_id = 3") }
    let centres = try await ClusterCentres.ensure(database: database, embedder: embedder)
    #expect(centres.count == 14)
    #expect(embedder.prompts.count == 15)
}

@Test func centresOfUnknownClustersAreRejectedByTheDatabase() async throws {
    let database = try LibraryDatabase(inMemory: ())
    _ = try await ClusterCentres.ensure(database: database, embedder: TextStub())
    await #expect(throws: DatabaseError.self) {
        try await database.writer.write { db in
            try db.execute(sql: "INSERT INTO cluster_centres (cluster_id, model_version, vector) VALUES (14, 'x', x'00')")
        }
    }
}
