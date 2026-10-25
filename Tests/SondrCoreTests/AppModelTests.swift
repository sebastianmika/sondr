import Foundation
import GRDB
import Testing

@testable import SondrCore

/// Deterministic fake model: audio vector depends on the clip, text vector on the words.
private struct FakeEmbedder: Embedder {
    func modelVersion() async throws -> String { "fake" }

    func embed(audio clips: [[Float]]) async throws -> [[Float]] {
        clips.map { Self.vector(seed: UInt64(truncatingIfNeeded: Int(($0.prefix(3000).reduce(0, +) * 1000).rounded()))) }
    }

    func embed(text: String) async throws -> [Float] { Self.vector(seed: UInt64(truncatingIfNeeded: text.utf8.reduce(0) { $0 &* 31 &+ Int($1) })) }

    static func vector(seed: UInt64) -> [Float] {
        var state = seed | 1
        let v = (0..<512).map { _ -> Float in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state >> 11) % 2000 - 1000)
        }
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return v.map { $0 / norm }
    }
}

private struct Workspace {
    let folder: URL
    let library: URL
    let databaseURL: URL

    init(files: Int = 0) throws {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("sondr-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        folder = LibraryScanner.realURL(made)
        library = folder.appendingPathComponent("Samples")
        databaseURL = folder.appendingPathComponent("db/library.sqlite")
        if files > 0 { try TestLibraryGenerator.generate(count: files, into: library) }
    }

    func remove() { try? FileManager.default.removeItem(at: folder) }

    @MainActor func model(embedder: (any Embedder)? = FakeEmbedder()) -> AppModel {
        AppModel(
            databaseURL: databaseURL, modelsDirectory: nil, embedder: embedder,
            mapSettings: MapSettingsStore(load: { MapParameters() }, save: { _ in }))
    }
}

@MainActor @Test func startWithoutModelsStillOpensTheLibrary() async throws {
    let work = try Workspace()
    defer { work.remove() }
    let app = work.model(embedder: nil)
    #expect(app.startup == .loading)
    await app.start()

    #expect(app.startup == .ready)
    #expect(!app.modelsAvailable)
    #expect(app.stats == LibraryStats())
    #expect(app.search == nil)
    await app.startIndexing()
    #expect(app.message?.contains("models") == true)
}

@MainActor @Test func unwritableDatabaseLocationIsReportedNotCrashed() async {
    let app = AppModel(databaseURL: URL(fileURLWithPath: "/dev/null/x/library.sqlite"), modelsDirectory: nil)
    await app.start()
    if case .failed(let reason) = app.startup { #expect(!reason.isEmpty) } else { Issue.record("expected failure") }
}

@MainActor @Test func addingAFolderScansItAndUpdatesTheNumbers() async throws {
    let work = try Workspace(files: 30)
    defer { work.remove() }
    let app = work.model()
    await app.start()
    let version = app.libraryVersion

    await app.addLocation(work.library)

    #expect(app.stats.samples == 30)
    #expect(app.stats.pending == 30)
    #expect(app.locations.map(\.sampleCount) == [30])
    #expect(app.libraryVersion > version)
    #expect(app.lastScanSummary?.new == 30)
    #expect(!app.isScanning)
    #expect(!app.tagCounts.isEmpty)
}

@MainActor @Test func indexingFillsTheVectorIndexAndClusters() async throws {
    let work = try Workspace(files: 24)
    defer { work.remove() }
    let app = work.model()
    await app.start()
    await app.addLocation(work.library)

    await app.startIndexing()

    #expect(app.stats.indexed == 24)
    #expect(app.stats.pending == 0)
    #expect(await app.vectorIndex.count == 24)
    #expect(app.indexProgress == nil)
    #expect(app.lastIndexSummary?.done == 24)
    #expect(app.clusters.count == 8)
    #expect(app.clusters.map(\.count).reduce(0, +) + app.unsortedCount == 24)
}

@MainActor @Test func reopeningTheLibraryRestoresTheIndex() async throws {
    let work = try Workspace(files: 12)
    defer { work.remove() }
    let first = work.model()
    await first.start()
    await first.addLocation(work.library)
    await first.startIndexing()

    let second = work.model()
    await second.start()
    #expect(second.stats.indexed == 12)
    #expect(await second.vectorIndex.count == 12)
    #expect(second.search != nil)
}

@MainActor @Test func removingALocationDropsItsSamplesFromTheIndexToo() async throws {
    let work = try Workspace(files: 10)
    defer { work.remove() }
    let app = work.model()
    await app.start()
    await app.addLocation(work.library)
    await app.startIndexing()
    let location = try #require(app.locations.first)

    await app.removeLocation(location)

    #expect(app.stats == LibraryStats())
    #expect(app.locations.isEmpty)
    #expect(await app.vectorIndex.count == 0)
    #expect(FileManager.default.fileExists(atPath: work.library.appendingPathComponent("Pack 000").path))  // files stay
}

@MainActor @Test func rescanKeepsTheSettingsTheLocationWasAddedWith() async throws {
    let work = try Workspace(files: 5)
    defer { work.remove() }
    let app = work.model()
    await app.start()
    await app.addLocation(work.library)
    let location = try #require(app.locations.first)
    await app.rescan(location)
    #expect(app.lastScanSummary?.skipped == 5)
    #expect(app.lastScanSummary?.new == 0)
}

// MARK: BrowseModel

@MainActor private func indexedApp(files: Int, _ work: Workspace) async -> AppModel {
    let app = work.model()
    await app.start()
    await app.addLocation(work.library)
    await app.startIndexing()
    return app
}

@MainActor @Test func browsePagesInAndSortsOnTheDatabase() async throws {
    let work = try Workspace(files: 450)
    defer { work.remove() }
    let app = await indexedApp(files: 450, work)
    let browse = BrowseModel(app: app)

    await browse.reload()
    #expect(browse.rows.count == BrowseModel.pageSize)
    #expect(browse.total == 450)
    #expect(browse.hasMore)

    await browse.loadMoreIfNeeded(at: browse.rows[browse.rows.count - 1])
    #expect(browse.rows.count == 2 * BrowseModel.pageSize)
    await browse.loadMoreIfNeeded(at: browse.rows[browse.rows.count - 1])
    #expect(browse.rows.count == 450)
    #expect(!browse.hasMore)
    #expect(Set(browse.rows.map(\.id)).count == 450)
    let names = browse.rows.map { $0.name.lowercased() }
    #expect(names == names.sorted())

    browse.sort = SampleSort(.filename, ascending: false)
    await browse.reload()
    #expect(browse.rows.first?.name.lowercased() == names.last)
}

@MainActor @Test func rowIDMovingStepsAndClampsWithinLoadedRows() async throws {
    let work = try Workspace(files: 60)
    defer { work.remove() }
    let app = await indexedApp(files: 60, work)
    let browse = BrowseModel(app: app)
    #expect(browse.rowID(moving: 1, from: []) == nil)

    await browse.reload()
    let ids = browse.rows.map(\.id)
    #expect(browse.rowID(moving: 1, from: []) == ids.first)
    #expect(browse.rowID(moving: -1, from: []) == ids.last)
    #expect(browse.rowID(moving: 1, from: [ids[0]]) == ids[1])
    #expect(browse.rowID(moving: 10, from: [ids[0]]) == ids[10])
    #expect(browse.rowID(moving: -1, from: [ids[0]]) == ids[0])
    #expect(browse.rowID(moving: 10, from: [ids[ids.count - 3]]) == ids.last)
    #expect(browse.rowID(moving: 1, from: [ids[0], ids[1]]) == ids.first)
}

@MainActor @Test func browseCollapsesGroupsAndExpandsThemOnDemand() async throws {
    let work = try Workspace(files: 60)
    defer { work.remove() }
    let app = await indexedApp(files: 60, work)
    let database = try #require(app.database)
    let browse = BrowseModel(app: app)
    await browse.reload()
    #expect(browse.total == 57 + 3)

    let ids = try await database.writer.read { try Int64.fetchAll($0, sql: "SELECT id FROM samples ORDER BY id LIMIT 4") }
    try await database.writer.write { db in
        try db.execute(sql: "INSERT INTO sample_groups (id, location_id, folder, key, name, representative_id) VALUES (1, 1, '', 'x_{p}', 'x', ?)", arguments: [ids[2]])
        for (index, id) in ids.enumerated() {
            try db.execute(sql: "UPDATE samples SET group_id = 1, pitch = ?, pitch_label = 'N' || ? WHERE id = ?", arguments: [48 + index, index, id])
        }
    }
    await browse.reload()
    #expect(browse.total == 57)
    #expect(browse.rows.contains { $0.id == ids[2] })
    #expect(!browse.rows.contains { $0.id == ids[0] })
    #expect(browse.visibleIDs.count == browse.rows.count)

    await browse.setExpanded(1, true)
    let groupRow = try #require(browse.row(ids[2]))
    #expect(browse.children(of: groupRow).map(\.id) == [ids[0], ids[1], ids[3]])
    #expect(browse.visibleIDs.count == browse.rows.count + 3)
    #expect(browse.row(ids[0])?.multisample?.pitchLabel == "N0")
    let index = try #require(browse.visibleIDs.firstIndex(of: ids[2]))
    #expect(browse.rowID(moving: 1, from: [ids[2]]) == browse.visibleIDs[index + 1])
    #expect(browse.rows(for: [ids[3], ids[2]]).map(\.id) == [ids[2], ids[3]])

    browse.collapseGroups = false
    await browse.settle()
    #expect(browse.total == 60)
    #expect(!browse.showsGroups)
    #expect(browse.children(of: groupRow).isEmpty)

    browse.collapseGroups = true
    await browse.settle()
    #expect(browse.total == 57)
    #expect(browse.showsGroups)
    let again = try #require(browse.row(ids[2]))
    #expect(again.multisample?.size == 4)
    await browse.setExpanded(1, true)
    #expect(browse.children(of: again).count == 3)
}

@MainActor @Test func togglingGroupsOffAndOnAfterAnAreaSelectionKeepsEveryGroup() async throws {
    let work = try Workspace(files: 120)
    defer { work.remove() }
    let app = await indexedApp(files: 120, work)
    let database = try #require(app.database)
    let browse = BrowseModel(app: app)
    await browse.reload()

    // 100 samples in 20 groups of 5; the area covers 80 of them (4 per group).
    let ids = try await database.writer.read { try Int64.fetchAll($0, sql: "SELECT id FROM samples ORDER BY id LIMIT 100") }
    try await database.writer.write { db in
        for group in 0..<20 {
            let members = ids[(group * 5)..<(group * 5 + 5)]
            try db.execute(
                sql: "INSERT INTO sample_groups (id, location_id, folder, key, name, representative_id) VALUES (?, 1, '', ?, ?, ?)",
                arguments: [group + 1, "g\(group)_{p}", "g\(group)", members[members.startIndex + 2]])
            for (index, id) in members.enumerated() {
                try db.execute(
                    sql: "UPDATE samples SET group_id = ?, pitch = ?, pitch_label = 'N' || ? WHERE id = ?",
                    arguments: [group + 1, 48 + index, index, id])
            }
        }
    }
    let area = Set(ids.enumerated().filter { $0.offset % 5 != 4 }.map(\.element))
    #expect(area.count == 80)

    browse.filter.sampleIDs = area
    await browse.settle()
    #expect(browse.showsGroups)
    #expect(browse.rows.count == 20 && browse.total == 20)

    browse.collapseGroups = false
    await browse.settle()
    #expect(!browse.showsGroups)
    #expect(browse.rows.count == 80 && browse.total == 80)

    browse.collapseGroups = true
    await browse.settle()
    #expect(browse.showsGroups)
    #expect(browse.rows.count == 20 && browse.total == 20)
}

@MainActor @Test func keywordAndTagFiltersNarrowTheList() async throws {
    let work = try Workspace(files: 120)
    defer { work.remove() }
    let app = await indexedApp(files: 120, work)
    let browse = BrowseModel(app: app)
    await browse.reload()
    let all = browse.total

    browse.searchText = "kick"
    await browse.settle()
    #expect(browse.total > 0 && browse.total < all)
    #expect(browse.rows.allSatisfy { $0.relPath.lowercased().contains("kick") })

    browse.searchText = ""
    await browse.settle()
    #expect(browse.total == all)
    browse.filter.tags = ["drum"]
    await browse.settle()
    #expect(browse.total > 0 && browse.total < all)
    #expect(browse.rows.allSatisfy { $0.tags.contains("drum") })
}

@MainActor @Test func textSearchShowsScoredResultsAndRespectsFilters() async throws {
    let work = try Workspace(files: 60)
    defer { work.remove() }
    let app = await indexedApp(files: 60, work)
    let browse = BrowseModel(app: app)
    browse.mode = .text
    browse.searchText = "punchy kick"
    await browse.settle()

    #expect(browse.content == .textSearch("punchy kick"))
    #expect(browse.rows.count == 60)
    #expect(browse.scores.count == 60)
    let scores = browse.rows.compactMap { browse.scores[$0.id] }
    #expect(scores == scores.sorted(by: >))

    browse.filter.tags = ["drum"]
    await browse.settle()  // the same search with the new filter
    #expect(browse.content == .textSearch("punchy kick"))
    #expect(browse.rows.count < 60 && browse.rows.allSatisfy { $0.tags.contains("drum") })

    await browse.clearResults()
    await browse.settle()
    #expect(browse.content == .browse)
    #expect(browse.scores.isEmpty)
    #expect(browse.searchText.isEmpty)
    #expect(browse.rows.count == browse.total)
}

@MainActor @Test func similarShowsOtherSamplesBestFirst() async throws {
    let work = try Workspace(files: 40)
    defer { work.remove() }
    let app = await indexedApp(files: 40, work)
    let browse = BrowseModel(app: app)
    await browse.reload()
    let first = browse.rows[0]

    await browse.showSimilar(to: first)

    #expect(browse.content == .similar(to: first.id, name: first.name))
    #expect(browse.rows.count == 39)
    #expect(!browse.rows.contains { $0.id == first.id })
}

@MainActor @Test func textSearchWithoutModelsExplainsWhy() async throws {
    let work = try Workspace(files: 5)
    defer { work.remove() }
    let app = work.model(embedder: nil)
    await app.start()
    await app.addLocation(work.library)
    let browse = BrowseModel(app: app)
    browse.mode = .text
    browse.searchText = "kick"
    await browse.settle()
    #expect(browse.errorMessage?.contains("models") == true)
}

@MainActor @Test func failedSamplesAreListedWithTheirReason() async throws {
    let work = try Workspace(files: 6)
    defer { work.remove() }
    let app = work.model()
    await app.start()
    await app.addLocation(work.library)
    let victim = try await app.database!.writer.read { try String.fetchOne($0, sql: "SELECT canonical_path FROM samples ORDER BY id LIMIT 1")! }
    try Data("garbage".utf8).write(to: URL(fileURLWithPath: victim))
    await app.startIndexing()
    #expect(app.stats.failed == 1)

    let browse = BrowseModel(app: app)
    browse.filter.embedState = "failed"
    await browse.reload()
    #expect(browse.rows.count == 1)
    #expect(browse.rows.first?.embedError?.isEmpty == false)
}

@Test func modelLocatorPrefersTheEnvironmentAndChecksForAllFiles() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("models-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    #expect(!ModelLocator.isComplete(folder))
    #expect(ModelLocator.find(environment: ["SONDR_MODELS": folder.path], bundle: Bundle(for: BundleToken.self))?.path != folder.path)
    for name in ModelLocator.requiredFiles {
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    #expect(ModelLocator.isComplete(folder))
    #expect(ModelLocator.find(environment: ["SONDR_MODELS": folder.path], bundle: Bundle(for: BundleToken.self))?.path == folder.path)
}

private final class BundleToken {}

// MARK: PlaybackModel

private func row(id: Int64 = 1, path: String, name: String) -> SampleRow {
    SampleRow(
        id: id, filename: name, name: name, relPath: name, canonicalPath: path, duration: 1, sampleRate: 48000, channels: 1,
        format: "wav", missing: false, embedState: "done", embedError: nil, clusterID: nil, clusterScore: nil,
        tags: [], dims: nil, waveThumb: nil)
}

@MainActor @Test func playingAMissingFileShowsAnErrorInsteadOfCrashing() {
    let playback = PlaybackModel()
    playback.play(row(path: "/nonexistent/kick.wav", name: "kick.wav"))
    #expect(playback.errorMessage?.contains("kick.wav") == true)
    #expect(!playback.isPlaying && playback.playingID == nil)
}

@MainActor @Test func playingACorruptFileShowsAnError() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
    try Data("garbage".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let playback = PlaybackModel()
    playback.play(row(path: file.path, name: "bad.wav"))
    #expect(playback.errorMessage != nil)
    #expect(!playback.isPlaying)
}

@MainActor @Test func playbackStartsStopsAndTogglesOneSampleAtATime() {
    let playback = PlaybackModel()
    let kick = row(id: 1, path: Fixtures.url("audio/loop_12s.flac").path, name: "loop")
    let other = row(id: 2, path: Fixtures.url("audio/loop_10s.flac").path, name: "loop10")
    playback.play(kick)
    if playback.errorMessage != nil { return }  // no audio output in this environment
    #expect(playback.isPlaying && playback.playingID == 1)
    playback.play(other)
    #expect(playback.playingID == 2)
    playback.toggle(other)
    #expect(!playback.isPlaying && playback.playingID == nil && playback.progress == 0)
    playback.autoAudition = true
    playback.selectionChanged(to: kick)
    #expect(playback.playingID == 1)
    playback.selectionChanged(to: nil)
    #expect(playback.playingID == nil)
}

// MARK: Tags

@MainActor @Test func tagEditsGoThroughTheModelAndRefreshTheCloud() async throws {
    let work = try Workspace(files: 20)
    defer { work.remove() }
    let app = work.model(embedder: nil)
    await app.start()
    await app.addLocation(work.library)
    let ids = try await app.database!.writer.read { try Int64.fetchAll($0, sql: "SELECT id FROM samples") }
    let version = app.libraryVersion

    await app.addTag("Favourite", to: ids)
    #expect(app.tagCounts.contains(TagCount(name: "favourite", count: 20)))
    #expect(app.libraryVersion > version)

    await app.renameTag("favourite", to: "fav")
    #expect(app.tagCounts.contains(TagCount(name: "fav", count: 20)))
    #expect(!app.tagCounts.contains { $0.name == "favourite" })

    await app.renameTag("fav", to: "drum")  // taken: tells the user instead of throwing
    #expect(app.message?.contains("Merge") == true)

    await app.mergeTag("fav", into: "drum")
    #expect(app.tagCounts.first { $0.name == "drum" }?.count == 20)

    await app.removeTag("drum", from: Array(ids.prefix(5)))
    #expect(app.tagCounts.first { $0.name == "drum" }?.count == 15)

    await app.deleteTag("drum")
    #expect(!app.tagCounts.contains { $0.name == "drum" })
    #expect(await app.allTags().contains { $0.name == "drum" } == false)
}

@MainActor @Test func theMapModelExistsOnceTheLibraryIsOpen() async throws {
    let work = try Workspace()
    defer { work.remove() }
    let app = work.model()
    #expect(app.map == nil)
    await app.start()
    let map = try #require(app.map)
    #expect(map.current == nil && !map.canBuild)
}

@MainActor @Test(.enabled(if: metalAvailable, "Requires a Metal GPU"))
func indexingPlacesNewSamplesOnTheCurrentMapAndRemovingAFolderRemovesThem() async throws {
    let work = try Workspace(files: 60)
    defer { work.remove() }
    let app = work.model()
    await app.start()
    await app.addLocation(work.library)
    await app.startIndexing()
    let map = try #require(app.map)
    #expect(map.canBuild)

    map.beginTuning()
    map.draft.sampleSize = 60
    map.draft.iterations = 150
    await map.waitForPreview()
    await map.keep()
    #expect(map.current?.pointCount == 60)

    let more = work.folder.appendingPathComponent("More")
    try TestLibraryGenerator.generate(count: 15, into: more, seed: 2)
    await app.addLocation(more)
    await app.startIndexing()
    #expect(map.current?.pointCount == 75 && map.dots?.count == 75)

    let location = try #require(app.locations.first { $0.path.hasSuffix("More") })
    await app.removeLocation(location)
    #expect(map.dots?.count == 60)
}

@MainActor @Test(.enabled(if: metalAvailable, "Requires a Metal GPU"))
func aPreviewDoesNotStartWhileIndexingRuns() async throws {
    let work = try Workspace(files: 80)
    defer { work.remove() }
    let app = work.model()
    await app.start()
    await app.addLocation(work.library)
    let map = try #require(app.map)
    #expect(map.unavailableReasonForTesting() == nil)
    let indexing = Task { await app.startIndexing() }
    while !app.isIndexing { await Task.yield() }
    #expect(map.unavailableReasonForTesting() != nil)
    await indexing.value
    #expect(map.unavailableReasonForTesting() == nil)
}

@MainActor @Test func browseCanBeRestrictedToTheSamplesPickedOnTheMap() async throws {
    let work = try Workspace(files: 40)
    defer { work.remove() }
    let app = await indexedApp(files: 40, work)
    let browse = BrowseModel(app: app)
    await browse.reload()
    let picked = Set(browse.rows.prefix(7).map(\.id))

    browse.filter.sampleIDs = picked
    await browse.settle()
    #expect(browse.total == 7 && Set(browse.rows.map(\.id)) == picked)

    browse.filter.sampleIDs = nil
    await browse.settle()
    #expect(browse.total == 40)
}

@MainActor @Test func aSampleThatIsNotOnTheLoadedPageCanStillBeLookedUp() async throws {
    let work = try Workspace(files: 450)
    defer { work.remove() }
    let app = await indexedApp(files: 450, work)
    let browse = BrowseModel(app: app)
    await browse.reload()
    #expect(browse.rows.count == BrowseModel.pageSize)
    let all = try await app.database!.writer.read { try SampleQuery.ids($0, filter: SampleFilter()) }
    let missing = try #require(all.first { id in !browse.rows.contains { $0.id == id } })

    #expect(browse.row(missing) == nil)
    await browse.pin(missing)
    #expect(browse.row(missing)?.id == missing)
    #expect(browse.rows.count == BrowseModel.pageSize, "the list itself is unchanged")

    let onPage = try #require(browse.rows.first)
    await browse.pin(onPage.id)
    #expect(browse.row(onPage.id) == onPage)
    #expect(browse.row(missing) == nil, "pinning another sample replaces the first")
}

@MainActor @Test func theHighlightFollowsFiltersAndSearchResults() async throws {
    let work = try Workspace(files: 120)
    defer { work.remove() }
    let app = await indexedApp(files: 120, work)
    let browse = BrowseModel(app: app)
    await browse.reload()
    #expect(browse.highlight == nil, "nothing is narrowed down, nothing to highlight")

    let revisionBefore = browse.highlightRevision
    browse.filter.tags = ["drum"]
    await browse.settle()
    #expect(browse.highlightRevision > revisionBefore, "views can tell the highlight changed")
    let drums = try #require(browse.highlight)
    let expected = try await app.database!.writer.read { db -> Set<Int64> in
        var filter = SampleFilter()
        filter.tags = ["drum"]
        return Set(try SampleQuery.ids(db, filter: filter))
    }
    #expect(!drums.isEmpty && drums == expected)

    browse.filter.tags = []
    browse.filter.sampleIDs = [Int64(5), Int64(6)]
    await browse.settle()
    #expect(browse.highlight == [5, 6])

    browse.filter.sampleIDs = nil
    await browse.settle()
    #expect(browse.highlight == nil)

    browse.mode = .text
    browse.searchText = "warm pad"
    await browse.runSearch()
    await browse.settle()
    #expect(browse.highlight == Set(browse.rows.map(\.id)) && browse.highlight?.count == BrowseModel.searchResultCount)

    await browse.clearResults()
    await browse.settle()
    #expect(browse.highlight == nil)
}

// MARK: Location tag settings

@MainActor @Test func addingAFolderWithTagSettingsTagsEverySample() async throws {
    let work = try Workspace(files: 20)
    defer { work.remove() }
    let app = work.model()
    await app.start()
    let tagging = LocationTagging(extraTags: ["Drumhaus"], rules: [TagRule(kind: .text, pattern: "kick")])

    await app.addLocation(work.library, tagging: tagging)

    #expect(app.locations.first?.tagging == LocationTagging(extraTags: ["drumhaus"], rules: tagging.rules))
    let counts = Dictionary(uniqueKeysWithValues: await app.allTags().map { ($0.name, $0.count) })
    #expect(counts["drumhaus"] == 20)
    #expect(counts["kick"] == nil)
    #expect(counts["snare"] ?? 0 > 0)
}

@MainActor @Test func changingALocationsTagsRetagsItsSamples() async throws {
    let work = try Workspace(files: 20)
    defer { work.remove() }
    let app = work.model()
    await app.start()
    await app.addLocation(work.library, tagging: LocationTagging(extraTags: ["old"]))
    let location = try #require(app.locations.first)
    let change = LocationTagging(extraTags: ["new"], rules: [TagRule(kind: .text, pattern: "snare")])

    #expect(await app.retagCount(for: location, new: change) == 20)
    #expect(await app.retagCount(for: location, new: location.tagging) == 0)
    await app.updateLocation(location, tagging: change)

    let counts = Dictionary(uniqueKeysWithValues: await app.allTags().map { ($0.name, $0.count) })
    #expect(counts["new"] == 20 && counts["old"] == nil && counts["snare"] == nil)
    #expect(counts["kick"] ?? 0 > 0)
    #expect(!app.isRetagging && app.retagProgress == nil)
    #expect(app.locations.first?.tagging == change)
}

@MainActor @Test func globalRulesApplyToAllLocationsAndNewScans() async throws {
    let work = try Workspace(files: 20)
    defer { work.remove() }
    let app = work.model()
    await app.start()
    await app.addLocation(work.library)

    await app.updateGlobalRules([TagRule(kind: .glob, pattern: "snar*")])
    #expect(app.globalTagRules == [TagRule(kind: .glob, pattern: "snar*")])
    #expect(await app.allTags().first { $0.name == "snare" } == nil)

    try TestLibraryGenerator.generate(count: 5, into: work.folder.appendingPathComponent("More"))
    await app.addLocation(work.folder.appendingPathComponent("More"))
    #expect(await app.allTags().first { $0.name == "snare" } == nil)
}

@MainActor @Test func invalidGlobalRulesAreRefusedWithAMessage() async throws {
    let work = try Workspace()
    defer { work.remove() }
    let app = work.model()
    await app.start()
    await app.updateGlobalRules([TagRule(kind: .regex, pattern: "(")])
    #expect(app.message?.contains("regular expression") == true)
    #expect(app.globalTagRules.isEmpty)
}

@MainActor @Test func aPendingRetagFinishesWhenTheAppStarts() async throws {
    let work = try Workspace(files: 12)
    defer { work.remove() }
    let first = work.model()
    await first.start()
    await first.addLocation(work.library)
    let database = try #require(first.database)
    // Simulates a quit in the middle of a change: committed, never applied.
    try await database.writer.write { db in
        let old = try TaggingStore.load(db)
        var new = old
        new.global = [TagRule(kind: .text, pattern: "kick")]
        try TagRetagJob.commit(db, old: old, new: new)
    }

    let second = work.model()
    await second.start()
    #expect(await second.allTags().first { $0.name == "kick" } == nil)
    #expect(try await database.writer.read { try !TagRetagJob.hasPending($0) })
}

@MainActor @Test func rescanAllVisitsEveryLocation() async throws {
    let work = try Workspace(files: 5)
    defer { work.remove() }
    let app = work.model()
    await app.start()
    await app.addLocation(work.library)
    let second = work.folder.appendingPathComponent("Second")
    try TestLibraryGenerator.generate(count: 4, into: second)
    await app.addLocation(second)
    try TestLibraryGenerator.generate(count: 3, into: second.appendingPathComponent("extra"))

    await app.rescanAll()

    // The generator repeats content, so the extra files are duplicates: look at paths, not samples.
    let paths = try await app.database!.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM sample_paths")! }
    #expect(paths == 12)
}

@MainActor @Test func updatingMultisampleRulesStoresThemAndRegroupsTheLocation() async throws {
    let work = try Workspace()
    defer { work.remove() }
    let app = work.model(embedder: nil)
    await app.start()
    let database = try #require(app.database)

    // Five indexed piano notes with near-identical embeddings, so name-only grouping is accepted.
    let notes = ["C3", "E3", "G3", "C4", "E4"]
    let vector = [Float(1)] + [Float](repeating: 0, count: VectorIndex.dimension - 1)
    try await database.writer.write { db in
        try db.execute(sql: "INSERT INTO locations (id, path, added_at) VALUES (1, '/lib', 0)")
        for (index, note) in notes.enumerated() {
            let id = Int64(index + 1)
            let file = "Keys/Piano_\(note).wav"
            try db.execute(
                sql: """
                    INSERT INTO samples (id, content_hash, canonical_path, filename, rel_path, duration,
                        sample_rate, channels, format, embed_state, file_size, file_mtime, scanned_at)
                    VALUES (?, ?, ?, ?, ?, 1, 48000, 1, 'wav', 'done', 1, 0, 0)
                    """, arguments: [id, "h\(id)", "/lib/\(file)", file, file])
            try db.execute(
                sql: "INSERT INTO sample_paths (sample_id, path, location_id) VALUES (?, ?, 1)", arguments: [id, "/lib/\(file)"])
            try db.execute(
                sql: "INSERT INTO embeddings (sample_id, vector) VALUES (?, ?)",
                arguments: [id, EmbeddingCodec.encode(vector)])
        }
    }
    await app.refresh()
    let location = try #require(app.locations.first)
    let groupCount = { try await database.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM sample_groups")! } }

    let off = MultisampleRules(overrides: [.init(folder: "Keys", group: false)])
    await app.updateMultisampleRules(location, rules: off)
    #expect(app.locations.first?.multisampleRules == off)
    #expect(try await groupCount() == 0)

    await app.updateMultisampleRules(location, rules: MultisampleRules())
    #expect(app.locations.first?.multisampleRules == MultisampleRules())
    #expect(try await groupCount() == 1)
}
