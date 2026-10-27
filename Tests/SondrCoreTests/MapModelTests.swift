import Foundation
import GRDB
import MetalTSNE
import Testing
import simd

@testable import SondrCore

// MARK: MapDots (no GPU needed)

@Test func dotsCarryTheClusterOfEverySampleAndTreatWeakMatchesAsUnsorted() throws {
    let (database, ids) = try makeLibrary(samples: 5)
    try database.writer.write { db in
        for cluster in 0..<4 { try db.execute(sql: "INSERT INTO clusters (id, name) VALUES (?, ?)", arguments: [cluster, "c\(cluster)"]) }
        for (id, cluster, score) in [(ids[0], 2, 0.9), (ids[1], 3, 0.1), (ids[2], 0, 0.31)] as [(Int64, Int, Double)] {
            try db.execute(
                sql: "UPDATE samples SET cluster_id = ?, cluster_score = ? WHERE id = ?", arguments: [cluster, score, id])
        }
        let state = TSNEModelState(
            embedding: [SIMD2(0, 0)], referenceWork: [0, 0], workDimensions: 2, inputDimensions: 2, pca: nil)
        let points = ids.enumerated().map { MapPoint(sampleID: $1, x: Float($0), y: Float($0) * 2, fitted: $0 == 0) }
        let mapID = try MapStore.save(db, state: state, parameters: MapParameters(), modelVersion: "m", points: points)
        let dots = try MapDots.load(db, mapID: mapID)
        #expect(dots.count == 5)
        #expect(dots.ids == ids.sorted())
        #expect(dots.cluster == [2, -1, 0, -1, -1], "cluster, unsorted (weak), kept (above 0.22), none, none")
        #expect(dots.fitted == [true, false, false, false, false])
        #expect(dots.x == [0, 1, 2, 3, 4] && dots.y == [0, 2, 4, 6, 8])
    }
}

@Test func clusterLookupForSomeSamplesFollowsTheGivenOrder() throws {
    let (database, ids) = try makeLibrary(samples: 4)
    try database.writer.write { db in
        try db.execute(sql: "INSERT INTO clusters (id, name) VALUES (1, 'c1')")
        try db.execute(sql: "UPDATE samples SET cluster_id = 1, cluster_score = 0.8 WHERE id = ?", arguments: [ids[3]])
        let clusters = try MapDots.clusterIDs(db, for: [ids[3], ids[0], 9999])
        #expect(clusters == [1, -1, -1])
    }
}

// MARK: MapModel

private final class SettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: MapParameters
    private(set) var saves = 0
    init(_ value: MapParameters) { stored = value }
    var value: MapParameters { lock.withLock { stored } }
    func save(_ value: MapParameters) { lock.withLock { stored = value; saves += 1 } }
}

@MainActor
private func makeModel(
    _ database: LibraryDatabase, settings: SettingsBox, unavailable: @escaping @MainActor () -> String? = { nil }
) -> MapModel {
    MapModel(
        database: database, modelVersion: { "m1" },
        settings: MapSettingsStore(load: { settings.value }, save: { settings.save($0) }),
        debounce: .milliseconds(20), unavailableReason: unavailable)
}

private func smallParameters(sample: Int, seed: UInt64 = 42) -> MapParameters {
    var p = MapParameters()
    p.sampleSize = sample
    p.iterations = 200
    p.seed = seed
    return p
}

@Test(.enabled(if: metalAvailable, "Requires a Metal GPU"))
@MainActor func withoutAMapTheModelSaysSoAndOffersOneOnlyForEnoughSamples() async throws {
    let (big, _) = try makeLibrary(samples: 100)
    let model = makeModel(big, settings: SettingsBox(MapParameters()))
    await model.load()
    #expect(model.current == nil && model.dots == nil && !model.hasPrevious)
    #expect(model.canBuild)

    let (small, _) = try makeLibrary(samples: 10)
    let tiny = makeModel(small, settings: SettingsBox(MapParameters()))
    await tiny.load()
    #expect(!tiny.canBuild)
}

@Test(.enabled(if: metalAvailable, "Requires a Metal GPU"))
@MainActor func changingTheDraftWhileTuningComputesAPreviewAndSavesNothing() async throws {
    let (database, _) = try makeLibrary(samples: 200)
    let settings = SettingsBox(smallParameters(sample: 200))
    let model = makeModel(database, settings: settings)
    await model.load()
    model.beginTuning()
    #expect(model.draft == settings.value)

    model.draft.perplexity = 12
    await model.waitForPreview()

    #expect(model.phase == .previewing)
    let preview = try #require(model.preview)
    #expect(preview.parameters.perplexity == 12)
    #expect(model.previewDots?.count == 200)
    #expect(model.current == nil)
    #expect(settings.saves == 0)
}

@Test(.enabled(if: metalAvailable, "Requires a Metal GPU"))
@MainActor func onlyTheLatestOfSeveralQuickChangesIsComputed() async throws {
    let (database, _) = try makeLibrary(samples: 200)
    let model = makeModel(database, settings: SettingsBox(smallParameters(sample: 200)))
    await model.load()
    model.beginTuning()
    model.draft.perplexity = 10
    model.draft.perplexity = 20
    model.draft.perplexity = 33
    await model.waitForPreview()
    #expect(model.preview?.parameters.perplexity == 33)
}

@Test(.enabled(if: metalAvailable, "Requires a Metal GPU"))
@MainActor func changesAreIgnoredWhenNotTuning() async throws {
    let (database, _) = try makeLibrary(samples: 100)
    let model = makeModel(database, settings: SettingsBox(smallParameters(sample: 100)))
    await model.load()
    model.draft.perplexity = 12
    await model.waitForPreview()
    #expect(model.preview == nil && model.phase == .idle)
}

@Test(.enabled(if: metalAvailable, "Requires a Metal GPU"))
@MainActor func keepingTheDraftStoresTheMapAndMakesItTheNewDefault() async throws {
    let (database, ids) = try makeLibrary(samples: 300)
    let settings = SettingsBox(smallParameters(sample: 120))
    let model = makeModel(database, settings: settings)
    await model.load()
    model.beginTuning()
    model.draft.perplexity = 14
    await model.waitForPreview()
    await model.keep()

    #expect(model.phase == .idle && model.preview == nil && model.previewDots == nil)
    let current = try #require(model.current)
    #expect(current.fittedCount == 120 && current.pointCount == 300)
    #expect(model.dots?.count == 300)
    #expect(Set(model.dots?.ids ?? []) == Set(ids))
    #expect(settings.value.perplexity == 14 && settings.saves == 1)
    #expect(model.saved.perplexity == 14)
    #expect(!model.hasPrevious)
    #expect(model.isTuning == false)
}

@Test(.enabled(if: metalAvailable, "Requires a Metal GPU"))
@MainActor func discardingAPreviewKeepsTheCurrentMapAndTheOldDefaults() async throws {
    let (database, _) = try makeLibrary(samples: 150)
    let settings = SettingsBox(smallParameters(sample: 150))
    let model = makeModel(database, settings: settings)
    await model.load()
    model.beginTuning()
    model.draft.iterations = 150
    await model.waitForPreview()
    await model.keep()
    let before = model.current?.id

    model.beginTuning()
    model.draft.perplexity = 8
    await model.waitForPreview()
    #expect(model.preview != nil)
    model.discard()

    #expect(model.preview == nil && model.previewDots == nil && model.phase == .idle)
    #expect(model.current?.id == before)
    #expect(settings.value.perplexity == 30)
    #expect(model.draft == model.saved)
}

@Test(.enabled(if: metalAvailable, "Requires a Metal GPU"))
@MainActor func endingTheTuningDropsAPreviewThatWasNotKept() async throws {
    let (database, _) = try makeLibrary(samples: 100)
    let model = makeModel(database, settings: SettingsBox(smallParameters(sample: 100)))
    await model.load()
    model.beginTuning()
    model.draft.perplexity = 9
    await model.waitForPreview()
    model.endTuning()
    #expect(model.preview == nil && !model.isTuning)
}

@Test(.enabled(if: metalAvailable, "Requires a Metal GPU"))
@MainActor func theOldMapCanBeRestoredAfterAKeep() async throws {
    let (database, _) = try makeLibrary(samples: 150)
    let model = makeModel(database, settings: SettingsBox(smallParameters(sample: 150)))
    await model.load()
    for perplexity in [10.0, 25.0] {
        model.beginTuning()
        model.draft.perplexity = perplexity
        await model.waitForPreview()
        await model.keep()
    }
    #expect(model.hasPrevious)
    #expect(model.current?.parameters.perplexity == 25)

    await model.restorePrevious()
    #expect(model.current?.parameters.perplexity == 10)
    #expect(model.hasPrevious, "the restored one can be swapped back")
    await model.restorePrevious()
    #expect(model.current?.parameters.perplexity == 25)
}

@Test(.enabled(if: metalAvailable, "Requires a Metal GPU"))
@MainActor func aFailedPreviewShowsTheReasonAndTheMapStaysAsItWas() async throws {
    let (database, _) = try makeLibrary(samples: 30)
    let model = makeModel(database, settings: SettingsBox(MapParameters()))
    await model.load()
    model.beginTuning()
    model.draft.perplexity = 10
    await model.waitForPreview()
    guard case .failed(let reason) = model.phase else {
        Issue.record("expected a failure, got \(model.phase)")
        return
    }
    #expect(reason.contains("at least"))
    #expect(model.preview == nil)
}

@Test(.enabled(if: metalAvailable, "Requires a Metal GPU"))
@MainActor func noPreviewStartsWhileTheGPUIsBusyWithSomethingElse() async throws {
    let (database, _) = try makeLibrary(samples: 100)
    let model = makeModel(database, settings: SettingsBox(smallParameters(sample: 100)), unavailable: { "Indexing is running." })
    await model.load()
    model.beginTuning()
    model.draft.perplexity = 10
    await model.waitForPreview()
    #expect(model.preview == nil)
    #expect(model.phase == .failed("Indexing is running."))
}

@Test(.enabled(if: metalAvailable, "Requires a Metal GPU"))
@MainActor func newSamplesAreAddedToTheMapAndSuggestARebuildOnceTheLibraryHasGrown() async throws {
    let (database, _) = try makeLibrary(samples: 200)
    let model = makeModel(database, settings: SettingsBox(smallParameters(sample: 200)))
    await model.load()
    model.beginTuning()
    model.draft.iterations = 150
    await model.waitForPreview()
    await model.keep()
    #expect(model.rebuildHint == nil)

    _ = try makeLibrary(samples: 20, from: 200, into: database)  // +10 %
    await model.placeNewSamples()
    #expect(model.current?.pointCount == 220 && model.dots?.count == 220)
    #expect(model.rebuildHint == nil)

    _ = try makeLibrary(samples: 40, from: 220, into: database)  // +30 % in all
    await model.placeNewSamples()
    #expect(model.current?.pointCount == 260)
    #expect(model.rebuildHint != nil)
}

@Test(.enabled(if: metalAvailable, "Requires a Metal GPU"))
@MainActor func parametersFromTheStoredMapAreShownInTheDraftAfterARestart() async throws {
    let (database, _) = try makeLibrary(samples: 120)
    let settings = SettingsBox(smallParameters(sample: 120))
    let first = makeModel(database, settings: settings)
    await first.load()
    first.beginTuning()
    first.draft.perplexity = 17
    await first.waitForPreview()
    await first.keep()

    let second = makeModel(database, settings: SettingsBox(settings.value))
    await second.load()
    #expect(second.current?.parameters.perplexity == 17)
    #expect(second.dots?.count == 120)
}

@Test @MainActor func settingsEditedInTheSettingsWindowAreClampedSavedAndUsedAsTheNextDraft() throws {
    let (database, _) = try makeLibrary(samples: 3)
    let box = SettingsBox(MapParameters())
    let model = makeModel(database, settings: box)
    var p = MapParameters()
    p.perplexity = 500
    p.sampleSize = 12_000
    model.saveSettings(p)

    #expect(box.value.perplexity == MapParameters.perplexityRange.upperBound)
    #expect(box.value.sampleSize == 12_000)
    #expect(model.saved == box.value)
    #expect(model.draft == box.value)

    model.beginTuning()
    #expect(model.draft.sampleSize == 12_000)
}

@Test @MainActor func settingsSavedWhileTuningDoNotDisturbTheDraft() throws {
    let (database, _) = try makeLibrary(samples: 3)
    let model = makeModel(database, settings: SettingsBox(MapParameters()))
    model.beginTuning()
    model.draft.iterations = 777
    var p = MapParameters()
    p.sampleSize = 5_000
    model.saveSettings(p)
    #expect(model.draft.iterations == 777)
    #expect(model.saved.sampleSize == 5_000)
}

@Test @MainActor func theLayoutPanelCanBeRequestedFromTheSettingsWindow() throws {
    let (database, _) = try makeLibrary(samples: 3)
    let model = makeModel(database, settings: SettingsBox(MapParameters()))
    #expect(!model.layoutPanelRequested)
    model.requestLayoutPanel()
    #expect(model.layoutPanelRequested)
    model.layoutPanelRequested = false
    #expect(!model.layoutPanelRequested)
}

@Test(.enabled(if: metalAvailable, "Requires a Metal GPU"))
@MainActor func aPreviewCanBeStartedWithoutChangingAnySetting() async throws {
    let (database, _) = try makeLibrary(samples: 100)
    let model = makeModel(database, settings: SettingsBox(smallParameters(sample: 100)))
    await model.load()
    model.beginTuning()
    #expect(model.preview == nil)
    model.requestPreview()
    await model.waitForPreview()
    #expect(model.preview != nil && model.phase == .previewing)
}

@Test(.enabled(if: metalAvailable, "Requires a Metal GPU"))
@MainActor func theRevisionChangesWheneverWhatIsDrawnChanges() async throws {
    let (database, _) = try makeLibrary(samples: 100)
    let model = makeModel(database, settings: SettingsBox(smallParameters(sample: 100)))
    await model.load()
    let atStart = model.revision
    model.beginTuning()
    model.requestPreview()
    await model.waitForPreview()
    let withPreview = model.revision
    #expect(withPreview > atStart)
    await model.keep()
    #expect(model.revision > withPreview)
}
