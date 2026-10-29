import Foundation
import GRDB
import Metal
import MetalTSNE
import Testing
import simd

@testable import SondrCore

private func parameters(sample: Int, seed: UInt64 = 42) -> MapParameters {
    var p = MapParameters()
    p.sampleSize = sample
    p.iterations = 200
    p.seed = seed
    return p
}

private func clusterOf(_ sampleID: Int64, ids: [Int64], clusters: Int = 4) -> Int {
    ids.firstIndex(of: sampleID).map { $0 % clusters } ?? -1
}

/// Share of the 5 nearest fitted points of each placed point that are in its own cluster.
private func placedAgreement(_ points: [MapPoint], ids: [Int64]) -> Double {
    let fitted = points.filter(\.fitted)
    var agree = 0, total = 0
    for point in points where !point.fitted {
        let here = SIMD2(point.x, point.y)
        let nearest = fitted.sorted {
            simd_distance_squared(SIMD2($0.x, $0.y), here) < simd_distance_squared(SIMD2($1.x, $1.y), here)
        }.prefix(5)
        for n in nearest { total += 1; if clusterOf(n.sampleID, ids: ids) == clusterOf(point.sampleID, ids: ids) { agree += 1 } }
    }
    return Double(agree) / Double(total)
}

private func differenceToMap(_ preview: MapPreview, _ points: [MapPoint]) -> Float {
    let current = Dictionary(uniqueKeysWithValues: points.map { ($0.sampleID, SIMD2($0.x, $0.y)) })
    let pairs = zip(preview.sampleIDs, preview.positions).compactMap { id, p in current[id].map { (p, $0) } }
    return (pairs.reduce(0) { $0 + simd_distance_squared($1.0, $1.1) } / Float(pairs.count)).squareRoot()
}

@Test(.enabled(if: metalAvailable, "Requires a Metal GPU"))
func previewUsesARandomSeededSampleAndSavesNothing() async throws {
    let (database, ids) = try makeLibrary(samples: 300)
    let service = MapService(database: database)
    let a = try await service.preview(parameters: parameters(sample: 120), modelVersion: "m1")
    let b = try await service.preview(parameters: parameters(sample: 120), modelVersion: "m1")
    let c = try await service.preview(parameters: parameters(sample: 120, seed: 7), modelVersion: "m1")

    #expect(a.sampleIDs.count == 120 && Set(a.sampleIDs).count == 120)
    #expect(Set(a.sampleIDs).isSubset(of: Set(ids)))
    #expect(a.positions.count == 120)
    #expect(a.sampleIDs == b.sampleIDs, "same seed, same sample")
    #expect(Set(a.sampleIDs) != Set(c.sampleIDs), "another seed, another sample")
    #expect(a.sampleIDs != ids.prefix(120).map { $0 }, "not just the first samples")
    let current = try await database.writer.read { try MapStore.current($0) }
    #expect(current == nil)
}

@Test(.enabled(if: metalAvailable, "Requires a Metal GPU"))
func aSampleLargerThanTheLibraryUsesEverySample() async throws {
    let (database, _) = try makeLibrary(samples: 80)
    let preview = try await MapService(database: database).preview(parameters: parameters(sample: 5_000), modelVersion: "m1")
    #expect(preview.sampleIDs.count == 80)
}

@Test(.enabled(if: metalAvailable, "Requires a Metal GPU"))
func tooFewSamplesGiveAClearError() async throws {
    let (database, _) = try makeLibrary(samples: MapParameters.minimumSamples - 1)
    await #expect(throws: MapError.notEnoughSamples(have: MapParameters.minimumSamples - 1, need: MapParameters.minimumSamples)) {
        try await MapService(database: database).preview(parameters: parameters(sample: 100), modelVersion: "m1")
    }
}

@Test(.enabled(if: metalAvailable, "Requires a Metal GPU"))
func samplesThatAreNotIndexedOrAreMissingAreLeftOut() async throws {
    let (database, ids) = try makeLibrary(samples: 100)
    try await database.writer.write {
        try $0.execute(sql: "UPDATE samples SET embed_state = 'pending' WHERE id = ?", arguments: [ids[0]])
        try $0.execute(sql: "UPDATE samples SET missing = 1 WHERE id = ?", arguments: [ids[1]])
    }
    let preview = try await MapService(database: database).preview(parameters: parameters(sample: 1_000), modelVersion: "m1")
    #expect(preview.sampleIDs.count == 98)
    #expect(!preview.sampleIDs.contains(ids[0]) && !preview.sampleIDs.contains(ids[1]))
}

@Test(.enabled(if: metalAvailable, "Requires a Metal GPU"))
func aCancelledPreviewThrowsAndWritesNothing() async throws {
    let (database, _) = try makeLibrary(samples: 300)
    let service = MapService(database: database)
    let task = Task { try await service.preview(parameters: parameters(sample: 300), modelVersion: "m1") }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    let current = try await database.writer.read { try MapStore.current($0) }
    #expect(current == nil)
}

@Test(.enabled(if: metalAvailable, "Requires a Metal GPU"))
func previewReportsProgressWithPositionsOfTheFittedSamples() async throws {
    let (database, _) = try makeLibrary(samples: 200)
    let seen = LockedBox<[MapProgress]>([])
    _ = try await MapService(database: database).preview(parameters: parameters(sample: 200), modelVersion: "m1") { progress in
        seen.withValue { $0.append(progress) }
    }
    let events = seen.value
    #expect(events.contains { $0.stage == .loading })
    let fitting = events.filter { $0.stage == .fitting }
    #expect(!fitting.isEmpty)
    #expect(fitting.allSatisfy { $0.positions?.count == 200 })
    #expect(fitting.map(\.done) == fitting.map(\.done).sorted())
}

@Test(.enabled(if: metalAvailable, "Requires a Metal GPU"))
func keepingAPreviewSkipsSamplesRemovedSinceThePreview() async throws {
    let (database, _) = try makeLibrary(samples: 200)
    let service = MapService(database: database)
    let preview = try await service.preview(parameters: parameters(sample: 200), modelVersion: "m1")
    let gone = preview.sampleIDs[0]
    try await database.writer.write { try $0.execute(sql: "DELETE FROM samples WHERE id = ?", arguments: [gone]) }

    let stored = try await service.keep(preview)

    #expect(stored.pointCount == 199)
    let points = try await database.writer.read { try MapStore.points($0, mapID: stored.id) }
    #expect(!points.contains { $0.sampleID == gone })
}

@Test(.enabled(if: metalAvailable, "Requires a Metal GPU"))
func keepingAPreviewPlacesTheRestOfTheLibraryNextToItsOwnCluster() async throws {
    let (database, ids) = try makeLibrary(samples: 400)
    let service = MapService(database: database)
    let p = parameters(sample: 150)
    let preview = try await service.preview(parameters: p, modelVersion: "clap-1")
    let stored = try await service.keep(preview)

    #expect(stored.fittedCount == 150 && stored.pointCount == 400)
    #expect(stored.modelVersion == "clap-1" && stored.parameters == p)
    let points = try await database.writer.read { try MapStore.points($0, mapID: stored.id) }
    #expect(points.count == 400)
    #expect(points.filter(\.fitted).count == 150)
    #expect(Set(points.filter(\.fitted).map(\.sampleID)) == Set(preview.sampleIDs))

    let agreement = placedAgreement(points, ids: ids)
    #expect(agreement > 0.9, "placed samples land among their own cluster")
}

@Test(.enabled(if: metalAvailable, "Requires a Metal GPU"))
func newSamplesAreProjectedOntoTheMapAlsoAfterARestart() async throws {
    let (database, _) = try makeLibrary(samples: 200)
    let first = MapService(database: database)
    let stored = try await first.keep(try await first.preview(parameters: parameters(sample: 200), modelVersion: "m1"))
    _ = try makeLibrary(samples: 30, from: 200, into: database)
    try await database.writer.write {  // two that must be ignored
        try $0.execute(sql: "UPDATE samples SET embed_state = 'pending' WHERE id = (SELECT max(id) FROM samples)")
        try $0.execute(sql: "UPDATE samples SET missing = 1 WHERE id = (SELECT max(id) - 1 FROM samples)")
    }

    let restarted = MapService(database: database)  // no cached model
    let placed = try await restarted.placeNewSamples()
    #expect(placed == 28)
    let map = try await database.writer.read { try MapStore.current($0) }
    #expect(map?.id == stored.id && map?.pointCount == 228 && map?.fittedCount == 200)
    let again = try await restarted.placeNewSamples()
    #expect(again == 0)
}

@Test(.enabled(if: metalAvailable, "Requires a Metal GPU"))
func placingSamplesWithoutAMapDoesNothing() async throws {
    let (database, _) = try makeLibrary(samples: 80)
    let placed = try await MapService(database: database).placeNewSamples()
    #expect(placed == 0)
}

@Test(.enabled(if: metalAvailable, "Requires a Metal GPU"))
func restoringThePreviousMapMakesItCurrentAgainAndNewSamplesGoToIt() async throws {
    let (database, _) = try makeLibrary(samples: 150)
    let service = MapService(database: database)
    let first = try await service.keep(try await service.preview(parameters: parameters(sample: 100, seed: 1), modelVersion: "m1"))
    let second = try await service.keep(try await service.preview(parameters: parameters(sample: 100, seed: 2), modelVersion: "m1"))
    #expect(first.id != second.id)

    let restored = try await service.restorePrevious()
    #expect(restored)
    let current = try await database.writer.read { try MapStore.current($0) }
    #expect(current?.id == first.id)

    _ = try makeLibrary(samples: 10, from: 150, into: database)
    let placed = try await service.placeNewSamples()
    #expect(placed == 10)
    let count = try await database.writer.read { try MapStore.points($0, mapID: first.id).count }
    #expect(count == 160)
}

@Test(.enabled(if: metalAvailable, "Requires a Metal GPU"))
func restoringWhenThereIsNoPreviousMapReturnsFalse() async throws {
    let (database, _) = try makeLibrary(samples: 80)
    let restored = try await MapService(database: database).restorePrevious()
    #expect(restored == false)
}

/// Collects values from `@Sendable` callbacks.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func withValue(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}

@Test(.enabled(if: metalAvailable, "Requires a Metal GPU"))
func aNewPreviewIsAlignedToTheCurrentMap() async throws {
    let (database, ids) = try makeLibrary(samples: 300)
    let service = MapService(database: database)
    let stored = try await service.keep(try await service.preview(parameters: parameters(sample: 200, seed: 1), modelVersion: "m1"))
    let points = try await database.writer.read { try MapStore.points($0, mapID: stored.id) }

    let aligned = try await service.preview(parameters: parameters(sample: 200, seed: 2), modelVersion: "m1")
    let raw = try await service.preview(parameters: parameters(sample: 200, seed: 2), modelVersion: "m1", alignToCurrent: false)
    #expect(aligned.isAligned && !raw.isAligned)
    #expect(aligned.state.embedding == aligned.positions, "the model must live in the aligned space")
    #expect(differenceToMap(aligned, points) < differenceToMap(raw, points))

    // A map built from an aligned preview still places new samples next to their own cluster.
    let kept = try await service.keep(aligned)
    let all = try await database.writer.read { try MapStore.points($0, mapID: kept.id) }
    #expect(placedAgreement(all, ids: ids) > 0.9)
}

@Test(.enabled(if: metalAvailable, "Requires a Metal GPU"))
func theFirstPreviewHasNothingToAlignTo() async throws {
    let (database, _) = try makeLibrary(samples: 100)
    let preview = try await MapService(database: database).preview(parameters: parameters(sample: 100), modelVersion: "m1")
    #expect(!preview.isAligned)
}

@Test(.enabled(if: metalAvailable, "Requires a Metal GPU"))
func aMapFromAnotherEmbeddingModelIsNotUsedForAlignment() async throws {
    let (database, _) = try makeLibrary(samples: 150)
    let service = MapService(database: database)
    _ = try await service.keep(try await service.preview(parameters: parameters(sample: 150), modelVersion: "old-model"))
    let preview = try await service.preview(parameters: parameters(sample: 150), modelVersion: "new-model")
    #expect(!preview.isAligned)
}

/// Samples 0..<members of `ids` become one multisample group whose representative is `ids[representative]`.
private func groupFirst(_ members: Int, of ids: [Int64], representative: Int, in database: LibraryDatabase) throws {
    try database.writer.write { db in
        try db.execute(sql: "INSERT INTO locations (id, path, added_at) VALUES (1, '/lib', 0)")
        try db.execute(
            sql: "INSERT INTO sample_groups (id, location_id, folder, key, name, representative_id) VALUES (1, 1, '', 'k_{p}', 'K', ?)",
            arguments: [ids[representative]])
        for id in ids.prefix(members) { try db.execute(sql: "UPDATE samples SET group_id = 1 WHERE id = ?", arguments: [id]) }
    }
}

@Test(.enabled(if: metalAvailable, "Requires a Metal GPU"))
func collapsingAMultisampleGroupFitsOnePointForIt() async throws {
    let (database, ids) = try makeLibrary(samples: 120)
    try groupFirst(20, of: ids, representative: 5, in: database)
    var collapsed = parameters(sample: 1_000)
    collapsed.collapseMultisamples = true
    let preview = try await MapService(database: database).preview(parameters: collapsed, modelVersion: "m1")

    #expect(preview.sampleIDs.count == 101)
    #expect(preview.sampleIDs.contains(ids[5]))
    #expect(Set(preview.sampleIDs).isDisjoint(with: ids.prefix(20).filter { $0 != ids[5] }))
    #expect(preview.groups == [ids[5]: Array(ids.prefix(20)).sorted()])
}

@Test(.enabled(if: metalAvailable, "Requires a Metal GPU"))
func keepingACollapsedPreviewPutsEveryGroupMemberAtTheGroupPoint() async throws {
    let (database, ids) = try makeLibrary(samples: 120)
    try groupFirst(20, of: ids, representative: 5, in: database)
    var collapsed = parameters(sample: 1_000)
    collapsed.collapseMultisamples = true
    let service = MapService(database: database)
    let stored = try await service.keep(try await service.preview(parameters: collapsed, modelVersion: "m1"))
    let points = try await database.writer.read { try MapStore.points($0, mapID: stored.id) }

    #expect(points.count == 120)
    let byID = Dictionary(uniqueKeysWithValues: points.map { ($0.sampleID, $0) })
    let anchor = try #require(byID[ids[5]])
    #expect(anchor.fitted)
    for id in ids.prefix(20) where id != ids[5] {
        let member = try #require(byID[id])
        #expect(member.x == anchor.x && member.y == anchor.y && !member.fitted)
    }
}

@Test(.enabled(if: metalAvailable, "Requires a Metal GPU"))
func withoutCollapsingEveryGroupMemberIsFittedOnItsOwn() async throws {
    let (database, ids) = try makeLibrary(samples: 120)
    try groupFirst(20, of: ids, representative: 5, in: database)
    let preview = try await MapService(database: database).preview(parameters: parameters(sample: 1_000), modelVersion: "m1")
    #expect(preview.sampleIDs.count == 120 && preview.groups.isEmpty)
}
