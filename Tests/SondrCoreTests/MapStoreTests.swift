import Foundation
import GRDB
import MetalTSNE
import Testing
import simd

@testable import SondrCore

private func makeDatabase(samples: Int) throws -> (LibraryDatabase, [Int64]) {
    let database = try LibraryDatabase(inMemory: ())
    let ids = try database.writer.write { db -> [Int64] in
        try (0..<samples).map { i in
            try db.execute(
                sql: """
                    INSERT INTO samples (content_hash, canonical_path, filename, rel_path, duration,
                        sample_rate, channels, format, file_size, file_mtime, scanned_at, embed_state)
                    VALUES (?, ?, ?, ?, 1, 48000, 1, 'wav', 1, 0, 0, 'done')
                    """, arguments: ["h\(i)", "/\(i).wav", "\(i).wav", "\(i).wav"])
            return db.lastInsertedRowID
        }
    }
    return (database, ids)
}

private func state(points: Int, seed: Float = 0) -> TSNEModelState {
    TSNEModelState(
        embedding: (0..<points).map { SIMD2(Float($0) + seed, Float($0) * 2) },
        referenceWork: (0..<points * 3).map { Float($0) + seed }, workDimensions: 3, inputDimensions: 5,
        pca: TSNEPCAState(
            mean: [1, 2, 3, 4, 5], components: (0..<15).map { Float($0) * 0.5 }, dim: 5, componentCount: 3))
}

private func points(_ ids: [Int64], fitted: Int) -> [MapPoint] {
    ids.enumerated().map { MapPoint(sampleID: $1, x: Float($0), y: Float($0) * 2, fitted: $0 < fitted) }
}

private func save(_ db: Database, ids: [Int64], seed: Float = 0, version: String = "m1") throws -> Int64 {
    try MapStore.save(
        db, state: state(points: 4, seed: seed), parameters: MapParameters(), modelVersion: version,
        points: points(ids, fitted: 4))
}

@Test func noMapExistsInAFreshDatabase() throws {
    let (database, _) = try makeDatabase(samples: 3)
    try database.writer.read { db in
        let value1 = try MapStore.current(db)
        #expect(value1 == nil)
        let value2 = try MapStore.previous(db)
        #expect(value2 == nil)
    }
}

@Test func savedMapRoundTripsStateParametersAndPoints() throws {
    let (database, ids) = try makeDatabase(samples: 6)
    var parameters = MapParameters()
    parameters.perplexity = 17
    parameters.sampleSize = 1234
    let original = state(points: 4, seed: 0.25)
    try database.writer.write { db in
        _ = try MapStore.save(db, state: original, parameters: parameters, modelVersion: "clap-1", points: points(ids, fitted: 4))
    }
    try database.writer.read { db in
        let storedMap = try MapStore.current(db)
        let map = try #require(storedMap)
        #expect(map.parameters == parameters)
        #expect(map.modelVersion == "clap-1")
        #expect(map.fittedCount == 4)
        #expect(map.pointCount == 6)
        let value3 = try MapStore.modelState(db, mapID: map.id)
        #expect(value3 == original)
        let stored = try MapStore.points(db, mapID: map.id)
        #expect(stored.count == 6)
        #expect(stored.map(\.sampleID).sorted() == ids.sorted())
        #expect(stored.filter(\.fitted).count == 4)
        #expect(stored.first { $0.sampleID == ids[3] }?.y == 6)
    }
}

@Test func newMapBecomesCurrentAndTheOldOneIsKeptAsPrevious() throws {
    let (database, ids) = try makeDatabase(samples: 4)
    let (first, second) = try database.writer.write { db in (try save(db, ids: ids, seed: 1), try save(db, ids: ids, seed: 2)) }
    try database.writer.read { db in
        let value4 = try MapStore.current(db)?.id
        #expect(value4 == second)
        let value5 = try MapStore.previous(db)?.id
        #expect(value5 == first)
        let value6 = try MapStore.modelState(db, mapID: first)
        #expect(value6 == state(points: 4, seed: 1))
    }
}

@Test func onlyTwoVersionsAreKept() throws {
    let (database, ids) = try makeDatabase(samples: 4)
    let (first, second, third) = try database.writer.write { db in
        (try save(db, ids: ids, seed: 1), try save(db, ids: ids, seed: 2), try save(db, ids: ids, seed: 3))
    }
    try database.writer.read { db in
        let value7 = try MapStore.current(db)?.id
        #expect(value7 == third)
        let value8 = try MapStore.previous(db)?.id
        #expect(value8 == second)
        let value9 = try Int.fetchOne(db, sql: "SELECT count(*) FROM maps")
        #expect(value9 == 2)
        let value10 = try Int.fetchOne(db, sql: "SELECT count(*) FROM map_points WHERE map_id = ?", arguments: [first])
        #expect(value10 == 0)
    }
}

@Test func restoringThePreviousMapSwapsThemAndCanBeUndone() throws {
    let (database, ids) = try makeDatabase(samples: 4)
    let (first, second) = try database.writer.write { db in (try save(db, ids: ids, seed: 1), try save(db, ids: ids, seed: 2)) }
    try database.writer.write { db in
        let restored = try MapStore.restorePrevious(db)
        #expect(restored)
    }
    try database.writer.read { db in
        let value11 = try MapStore.current(db)?.id
        #expect(value11 == first)
        let value12 = try MapStore.previous(db)?.id
        #expect(value12 == second)
    }
    try database.writer.write { db in
        let restored = try MapStore.restorePrevious(db)
        #expect(restored)
    }
    try database.writer.read { db in
        let id = try MapStore.current(db)?.id
        #expect(id == second)
    }
}

@Test func restoringWithoutAPreviousMapDoesNothing() throws {
    let (database, ids) = try makeDatabase(samples: 4)
    try database.writer.write { db in
        let value13 = try MapStore.restorePrevious(db)
        #expect(value13 == false)
        let only = try save(db, ids: ids)
        let value14 = try MapStore.restorePrevious(db)
        #expect(value14 == false)
        let value15 = try MapStore.current(db)?.id
        #expect(value15 == only)
    }
}

@Test func addingPointsExtendsAMapAndFindsTheUnmappedSamples() throws {
    let (database, ids) = try makeDatabase(samples: 8)
    try database.writer.write { db in
        let id = try MapStore.save(
            db, state: state(points: 4), parameters: MapParameters(), modelVersion: "m1", points: points(Array(ids.prefix(4)), fitted: 4))
        let value16 = try MapStore.unmappedSampleIDs(db, mapID: id, limit: 100).sorted()
        #expect(value16 == Array(ids.suffix(4)).sorted())
        let built = try MapStore.current(db)?.builtCount
        #expect(built == 4)
        try MapStore.addPoints(db, mapID: id, points: points(Array(ids.suffix(4)), fitted: 0))
        let stillBuilt = try MapStore.current(db)?.builtCount
        #expect(stillBuilt == 4, "the size at build time does not grow with placed samples")
        let unmapped = try MapStore.unmappedSampleIDs(db, mapID: id, limit: 100)
        #expect(unmapped.isEmpty)
        let value17 = try MapStore.current(db)?.pointCount
        #expect(value17 == 8)
        let value18 = try MapStore.current(db)?.fittedCount
        #expect(value18 == 4)
    }
}

@Test func unmappedSamplesIgnoreSamplesThatAreNotIndexedOrMissing() throws {
    let (database, ids) = try makeDatabase(samples: 6)
    try database.writer.write { db in
        try db.execute(sql: "UPDATE samples SET embed_state = 'pending' WHERE id = ?", arguments: [ids[4]])
        try db.execute(sql: "UPDATE samples SET missing = 1 WHERE id = ?", arguments: [ids[5]])
        let id = try MapStore.save(
            db, state: state(points: 4), parameters: MapParameters(), modelVersion: "m1", points: points(Array(ids.prefix(4)), fitted: 4))
        let unmapped = try MapStore.unmappedSampleIDs(db, mapID: id, limit: 100)
        #expect(unmapped.isEmpty)
    }
}

@Test func removingASampleRemovesItsMapPoint() throws {
    let (database, ids) = try makeDatabase(samples: 4)
    try database.writer.write { db in
        let id = try save(db, ids: ids)
        try db.execute(sql: "DELETE FROM samples WHERE id = ?", arguments: [ids[0]])
        let value19 = try MapStore.points(db, mapID: id).count
        #expect(value19 == 3)
    }
}

@Test func deleteAllRemovesEveryMap() throws {
    let (database, ids) = try makeDatabase(samples: 4)
    try database.writer.write { db in
        _ = try save(db, ids: ids, seed: 1)
        _ = try save(db, ids: ids, seed: 2)
        try MapStore.deleteAll(db)
        let value20 = try MapStore.current(db)
        #expect(value20 == nil)
        let value21 = try MapStore.previous(db)
        #expect(value21 == nil)
        let value22 = try Int.fetchOne(db, sql: "SELECT count(*) FROM map_points")
        #expect(value22 == 0)
    }
}

@Test func savingFailsWithoutLeavingAHalfWrittenMap() throws {
    let (database, ids) = try makeDatabase(samples: 4)
    try database.writer.write { db in _ = try save(db, ids: ids, seed: 1) }
    let bad = [MapPoint(sampleID: 99_999, x: 0, y: 0, fitted: true)]  // no such sample
    #expect(throws: (any Error).self) {
        try database.writer.write { db in
            _ = try MapStore.save(db, state: state(points: 1), parameters: MapParameters(), modelVersion: "m1", points: bad)
        }
    }
    try database.writer.read { db in
        let value23 = try Int.fetchOne(db, sql: "SELECT count(*) FROM maps")
        #expect(value23 == 1)
        let value24 = try MapStore.previous(db)
        #expect(value24 == nil)
    }
}

@Test func indexJobDropsMapsWhenTheModelVersionChanges() throws {
    let (database, ids) = try makeDatabase(samples: 4)
    try database.writer.write { db in
        _ = try save(db, ids: ids)
        try db.execute(sql: "INSERT INTO meta (key, value) VALUES ('model_version', 'old')")
    }
    try database.writer.write { db in try IndexJob.discardStaleDerivedData(db, storedVersion: "old", newVersion: "new") }
    try database.writer.read { db in
        let current = try MapStore.current(db)
        #expect(current == nil)
    }
}

// MARK: Parameters

@Test func parametersStartAtTheDocumentedDefaults() {
    let p = MapParameters()
    #expect(p.sampleSize == 30_000)
    #expect(p.perplexity == 30 && p.earlyExaggeration == 12 && p.iterations == 300)
    #expect(p.pcaDimensions == 50)
    #expect(p.seed == 42)
    let upstream = TSNEParameters()
    #expect(p.perplexity == upstream.perplexity && p.earlyExaggeration == upstream.earlyExaggeration)
    #expect(p.iterations == upstream.iterations && p.pcaDimensions == upstream.pcaDimensions)
}

@Test func parametersSurviveJSON() throws {
    var p = MapParameters()
    p.perplexity = 44
    p.pcaDimensions = nil
    p.seed = 7
    p.learningRate = 150
    p.collapseMultisamples = true
    let data = try JSONEncoder().encode(p)
    let value25 = try JSONDecoder().decode(MapParameters.self, from: data)
    #expect(value25 == p)
}

@Test func missingFieldsInStoredJSONFallBackToDefaults() throws {
    let decoded = try JSONDecoder().decode(MapParameters.self, from: Data(#"{"perplexity": 12}"#.utf8))
    #expect(decoded.perplexity == 12)
    #expect(decoded.iterations == MapParameters().iterations)
    #expect(!decoded.collapseMultisamples)
}

@Test func clampingKeepsEveryValueInItsDocumentedRange() {
    var p = MapParameters()
    p.perplexity = 1000
    p.earlyExaggeration = 0
    p.iterations = 5
    p.sampleSize = 10
    p.pcaDimensions = 1
    let c = p.clamped()
    #expect(c.perplexity == MapParameters.perplexityRange.upperBound)
    #expect(c.earlyExaggeration == MapParameters.earlyExaggerationRange.lowerBound)
    #expect(c.iterations == MapParameters.iterationsRange.lowerBound)
    #expect(c.sampleSize == MapParameters.sampleSizeRange.lowerBound)
    #expect(c.pcaDimensions == MapParameters.pcaRange.lowerBound)
}

@Test func tsneParametersAreAdaptedToSmallSamples() {
    let small = MapParameters().tsne(pointCount: 100, inputDimensions: 512)
    #expect(small.perplexity <= 33)  // perplexity must stay below a third of the points
    #expect(small.neighborCount <= 99)
    let normal = MapParameters().tsne(pointCount: 20_000, inputDimensions: 512)
    #expect(normal.perplexity == 30 && normal.neighborCount == 90)
    #expect(normal.pcaDimensions == 50)
}

@Test func tsneParametersCarryEverySetting() {
    var p = MapParameters()
    p.earlyExaggeration = 20
    p.iterations = 500
    p.earlyExaggerationIterations = 100
    p.learningRate = 321
    p.initialization = .random
    p.seed = 9
    p.pcaDimensions = nil
    p.neighborCount = 120
    let t = p.tsne(pointCount: 20_000, inputDimensions: 512)
    #expect(t.earlyExaggeration == 20 && t.iterations == 500 && t.earlyExaggerationIterations == 100)
    #expect(t.learningRate == 321 && t.initialization == .random && t.seed == 9)
    #expect(t.pcaDimensions == nil && t.neighborCount == 120)
}

@Test func pcaIsNeverLargerThanTheInput() {
    #expect(MapParameters().tsne(pointCount: 20_000, inputDimensions: 32).pcaDimensions == 32)
}
