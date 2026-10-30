import Foundation
import GRDB
import Observation

public enum StartupState: Equatable, Sendable {
    case loading
    case ready
    case failed(String)
}

public struct ScanStatus: Equatable, Sendable {
    public var location: String
    public var progress: ScanProgress?
}

/// A scan waiting its turn in ``AppModel/scanQueue``, followed by indexing if `index` is set.
public struct QueuedScan {
    public var url: URL
    var extensions: Set<String>?
    var maxLength: Double?
    var tagging: LocationTagging?
    var multisampleRules: MultisampleRules?
    var dropRareTagsUpTo: Int?
    var name: String?
    var index: Bool
}

/// State of the whole app: the open library, running jobs and the numbers the sidebar shows.
/// Views read it; its methods are the only things that start jobs or change the library.
@MainActor
@Observable
public final class AppModel {
    public private(set) var startup = StartupState.loading
    public private(set) var stats = LibraryStats()
    public private(set) var locations: [LocationInfo] = []
    public private(set) var clusters: [ClusterInfo] = []
    public private(set) var unsortedCount = 0
    public private(set) var tagCounts: [TagCount] = []
    /// False if the Core ML models were not found: browsing and scanning still work.
    public private(set) var modelsAvailable = false
    public private(set) var scanStatus: ScanStatus?
    /// Set while a change of tag settings is being applied to the samples.
    public private(set) var retagProgress: RetagProgress?
    /// Set while the samples are assigned to the edited clusters.
    public private(set) var reclusterProgress: ReclusterProgress?
    /// Blacklist for the tags of all locations.
    public private(set) var globalTagRules: [TagRule] = []
    public private(set) var indexProgress: IndexProgress?
    public private(set) var lastScanSummary: ScanSummary?
    public private(set) var lastIndexSummary: IndexSummary?
    /// Bumped whenever the set of samples may have changed, so lists reload.
    public private(set) var libraryVersion = 0
    /// An error to show in an alert. Results of jobs go to ``notices``.
    public var message: String?
    /// Results of finished jobs, newest last. They clear themselves a few seconds after the last one.
    public private(set) var notices: [String] = []
    /// Locations waiting to be scanned (and indexed); the first one is next.
    public private(set) var scanQueue: [QueuedScan] = []
    private var draining = false
    private var noticeTask: Task<Void, Never>?

    public private(set) var database: LibraryDatabase?
    public let vectorIndex = VectorIndex()
    public private(set) var search: SearchService?
    public private(set) var embedder: (any Embedder)?
    /// The 2D map; nil until the library is open.
    public private(set) var map: MapModel?
    private var indexRun: IndexRun?
    private var reclusterRun: ReclusterRun?
    private let mapSettings: MapSettingsStore

    private let databaseURL: URL
    public let modelsDirectory: URL?
    public var databasePath: String { databaseURL.path }

    /// - Parameters:
    ///   - databaseURL: Library file; default ``LibraryDatabase/defaultURL()``.
    ///   - modelsDirectory: Models folder; default ``ModelLocator/find(environment:bundle:)``.
    ///   - embedder: Replaces the Core ML embedder (tests).
    ///   - computeUnits: Hardware for the Core ML models.
    ///   - mapSettings: Where the 2D map settings are kept; default the app's user defaults.
    public init(
        databaseURL: URL = LibraryDatabase.defaultURL(), modelsDirectory: URL? = ModelLocator.find(),
        embedder: (any Embedder)? = nil, computeUnits: EmbeddingService.ComputeUnits = .cpuAndGPU,
        mapSettings: MapSettingsStore = .userDefaults()
    ) {
        self.mapSettings = mapSettings
        self.databaseURL = databaseURL
        self.modelsDirectory = modelsDirectory
        self.embedder = embedder ?? modelsDirectory.map { EmbeddingService(modelsDirectory: $0, computeUnits: computeUnits) }
        modelsAvailable = self.embedder != nil
    }

    public var isScanning: Bool { scanStatus != nil }
    public var isIndexing: Bool { indexProgress != nil }
    public var isRetagging: Bool { retagProgress != nil }
    public var isReclustering: Bool { reclusterProgress != nil }
    /// True while a location is being scanned or indexed for ``addLocation(_:tagging:multisampleRules:dropRareTagsUpTo:name:)``.
    public var isQueueRunning: Bool { draining }

    private func note(_ text: String) {
        notices = Array((notices + [text]).suffix(3))
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { self?.notices = [] }
        }
    }
    /// Cluster colours for the sidebar, the table and the map.
    public var palette: ClusterPalette { ClusterPalette(clusters) }

    // MARK: Startup

    public func start() async {
        guard startup == .loading else { return }
        do {
            let database = try LibraryDatabase(url: databaseURL)
            self.database = database
            _ = try await Reconciliation.run(database: database)
            try await vectorIndex.load(from: database)
            if let embedder {
                search = SearchService(database: database, index: vectorIndex, embedder: embedder)
            }
            let embedderForMap = embedder
            let mapModel = MapModel(
                database: database,
                modelVersion: {
                    if let embedderForMap { return try await embedderForMap.modelVersion() }
                    return try await database.writer.read {
                        try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key = 'model_version'")
                    } ?? "unknown"
                },
                settings: mapSettings,
                unavailableReason: { [weak self] in
                    self?.isIndexing == true ? "Indexing is running. Try again when it has finished." : nil
                })
            map = mapModel
            await mapModel.load()
            await refresh()
            await finishPendingRetag()
            await finishPendingRecluster()
            startup = .ready
        } catch {
            startup = .failed(error.localizedDescription)
        }
    }

    /// Reloads the numbers shown in the sidebar and (unless `reloadLists` is false) tells lists to reload.
    public func refresh(reloadLists: Bool = true) async {
        guard let database else { return }
        do {
            let (stats, locations, clusterInfo, tags, globalRules) = try await database.writer.read { db in
                (
                    try LibraryInfo.stats(db), try LibraryInfo.locations(db), try LibraryInfo.clusters(db),
                    try SampleQuery.tagCounts(db, limit: 200), try TaggingStore.load(db).global
                )
            }
            globalTagRules = globalRules
            self.stats = stats
            self.locations = locations
            clusters = clusterInfo.clusters
            unsortedCount = clusterInfo.unsorted
            tagCounts = tags
            if reloadLists {
                libraryVersion += 1
                await map?.reloadFromDatabase()
            }
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: Locations and scanning

    /// Adds a folder to the library, scans it and indexes it, one queued location after the other. `tagging`
    /// (extra tags and blacklist) is stored on the location and applies to every sample found in it.
    ///
    /// With `dropRareTagsUpTo`, the new samples' auto tags used by that many samples or fewer, or by under 1% of
    /// them, are removed.
    ///
    /// If the queue is already running, the location joins it and this returns at once; otherwise it returns when
    /// the queue is empty.
    public func addLocation(
        _ url: URL, tagging: LocationTagging? = nil, multisampleRules: MultisampleRules? = nil,
        dropRareTagsUpTo: Int? = nil, name: String? = nil
    ) async {
        await enqueue([
            QueuedScan(
                url: url, extensions: nil, maxLength: nil, tagging: tagging, multisampleRules: multisampleRules,
                dropRareTagsUpTo: dropRareTagsUpTo, name: name, index: true)
        ])
    }

    /// Scans every known location again, one after the other.
    public func rescanAll() async {
        await enqueue(locations.map(rescanItem))
    }

    /// Scans a known location again with the settings it was added with.
    public func rescan(_ location: LocationInfo) async {
        await enqueue([rescanItem(location)])
    }

    private func rescanItem(_ location: LocationInfo) -> QueuedScan {
        let extensions = location.typeFilter.map { Set($0.split(separator: ",").map(String.init)) }
        return QueuedScan(
            url: URL(fileURLWithPath: location.path), extensions: extensions, maxLength: location.maxLength,
            index: false)
    }

    private func enqueue(_ items: [QueuedScan]) async {
        scanQueue += items
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while !scanQueue.isEmpty {
            let item = scanQueue.removeFirst()
            // A job the user started by hand holds the turn.
            while isScanning || isIndexing || isRetagging { try? await Task.sleep(for: .milliseconds(250)) }
            await run(item)
        }
    }

    private func run(_ item: QueuedScan) async {
        guard let summary = await scan(item) else { return }
        var text =
            "\(item.url.lastPathComponent): \(summary.new) new, \(summary.duplicate) duplicates, \(summary.errors) unreadable."
        if item.index && modelsAvailable, let indexed = await runIndexing(retryFailed: false) { text += " " + indexed }
        note(text)
    }

    /// What adding `url` with these settings would tag; see ``TagPreview``.
    public func previewTags(of url: URL) async throws -> TagPreview {
        try await TagPreview.scan(root: url, tagger: Tagger.bundled())
    }

    /// Returns the summary if the scan ran to the end.
    private func scan(_ item: QueuedScan) async -> ScanSummary? {
        guard let database, !isScanning, !isIndexing, !isRetagging else { return nil }
        var completed: ScanSummary?
        scanStatus = ScanStatus(location: item.url.path, progress: nil)
        defer { scanStatus = nil }
        do {
            let scanner = try LibraryScanner(database: database)
            let summary = try await scanner.scan(root: item.url, extensions: item.extensions, maxLength: item.maxLength, tagging: item.tagging, multisampleRules: item.multisampleRules, dropRareTagsUpTo: item.dropRareTagsUpTo, name: item.name) { [weak self] progress in
                Task { @MainActor [weak self] in self?.scanStatus?.progress = progress }
            }
            lastScanSummary = summary
            try await vectorIndex.load(from: database)  // files that vanished leave the index
            await regroup()
            completed = summary
        } catch {
            message = error.localizedDescription
        }
        await refresh()
        return completed
    }

    /// Gives a location a new display name; a blank name goes back to the folder's name.
    public func renameLocation(_ location: LocationInfo, to name: String) async {
        guard let database else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        do {
            try await database.writer.write {
                try $0.execute(
                    sql: "UPDATE locations SET name = ? WHERE id = ?",
                    arguments: [trimmed.isEmpty ? nil : trimmed, location.id])
            }
        } catch {
            message = error.localizedDescription
        }
        await refresh(reloadLists: false)  // only the location list changes
    }

    /// Removes a location from the library. Audio files are not touched.
    public func removeLocation(_ location: LocationInfo) async {
        guard let database, !isScanning, !isIndexing, !isRetagging, !draining else { return }
        do {
            let removed = try await database.writer.write { try LibraryInfo.removeLocation($0, id: location.id) }
            for id in removed { await vectorIndex.remove(id: id) }
            note("Removed \(location.path) and \(removed.count) samples.")
        } catch {
            message = error.localizedDescription
        }
        await refresh()
    }

    // MARK: Tag settings

    /// How many samples a change of this location's tag settings would retag.
    public func retagCount(for location: LocationInfo, new: LocationTagging) async -> Int {
        guard let database else { return 0 }
        return (try? await database.writer.read { db -> Int in
            let old = try TaggingStore.load(db)
            var changed = old
            changed.locations[location.id] = LocationTagging(
                extraTags: TaggingStore.normalised(new.extraTags), rules: new.rules)
            return try TagRetag.affectedSampleIDs(db, old: old, new: changed).count
        }) ?? 0
    }

    /// How many samples a change of the global blacklist would retag.
    public func retagCount(globalRules: [TagRule]) async -> Int {
        guard let database else { return 0 }
        return (try? await database.writer.read { db -> Int in
            let old = try TaggingStore.load(db)
            var changed = old
            changed.global = globalRules
            return try TagRetag.affectedSampleIDs(db, old: old, new: changed).count
        }) ?? 0
    }

    /// Saves new tag settings for a location and retags the samples that are affected.
    public func updateLocation(_ location: LocationInfo, tagging: LocationTagging) async {
        await changeTagSettings { settings in settings.locations[location.id] = tagging }
    }

    /// Saves the global blacklist and retags all samples.
    public func updateGlobalRules(_ rules: [TagRule]) async {
        await changeTagSettings { $0.global = rules }
    }

    private func changeTagSettings(_ change: @escaping @Sendable (inout TaggingSettings) -> Void) async {
        guard let database, !isScanning, !isRetagging, !isReclustering else { return }
        do {
            try await database.writer.write { db in
                let old = try TaggingStore.load(db)
                var new = old
                change(&new)
                try TagRetagJob.commit(db, old: old, new: new)
            }
        } catch {
            message = error.localizedDescription
            return
        }
        await finishPendingRetag()
    }

    /// Applies a committed but unfinished change of tag settings (also after the app was quit).
    private func finishPendingRetag() async {
        guard let database, !isRetagging,
            (try? await database.writer.read { try TagRetagJob.hasPending($0) }) == true
        else { return }
        retagProgress = RetagProgress(total: 0, done: 0)
        defer { retagProgress = nil }
        do {
            let run = try TagRetagJob.start(database: database, tagger: Tagger.bundled())
            for await progress in run.progress { retagProgress = progress }
            let summary = try await run.result()
            note(summary.cancelled ? "Retagging stopped." : "Retagged \(summary.samples) samples.")
        } catch {
            message = error.localizedDescription
        }
        await refresh()
    }

    // MARK: Clusters

    /// Saves the edited clusters (see ``ClusterReassignJob/commit(_:edited:)``) and, if the centres
    /// changed, assigns all samples again in the background. Needs the models and no other job.
    public func saveClusters(_ edited: [ClusterDefinition]) async {
        guard let database else { return }
        guard embedder != nil else {
            message = "The Core ML models were not found. See the README for how to build them."
            return
        }
        guard !isScanning, !isIndexing, !isRetagging, !isReclustering else {
            message = "Wait for the running job to finish before changing the clusters."
            return
        }
        do {
            let needsReassign = try await database.writer.write { try ClusterReassignJob.commit($0, edited: edited) }
            if !needsReassign {
                note("Clusters saved.")
                await refresh()
            }
        } catch {
            message = error.localizedDescription
            return
        }
        await finishPendingRecluster()
    }

    /// Stops the assignment after the chunk in flight; it resumes at the next launch.
    public func cancelRecluster() { reclusterRun?.cancel() }

    /// Applies a committed but unfinished change of the clusters (also after the app was quit).
    private func finishPendingRecluster() async {
        guard let database, let embedder, !isReclustering,
            (try? await database.writer.read { try ClusterReassignJob.hasPending($0) }) == true
        else { return }
        reclusterProgress = ReclusterProgress(total: 0, done: 0)
        defer {
            reclusterProgress = nil
            reclusterRun = nil
        }
        do {
            let run = try ClusterReassignJob.start(database: database, embedder: embedder)
            reclusterRun = run
            for await progress in run.progress { reclusterProgress = progress }
            let summary = try await run.result()
            note(summary.cancelled ? "Sorting into clusters stopped." : "Sorted \(summary.samples) samples into clusters.")
        } catch {
            message = error.localizedDescription
        }
        await refresh()
    }

    // MARK: Tags

    /// Adds a manual tag to the samples (one transaction).
    public func addTag(_ name: String, to ids: [Int64]) async {
        await editTags { try LibraryTags.add($0, sampleIDs: ids, name: name) }
    }

    public func removeTag(_ name: String, from ids: [Int64]) async {
        await editTags { try LibraryTags.remove($0, sampleIDs: ids, name: name) }
    }

    /// Renames a tag; if the new name exists, the message says to merge instead.
    public func renameTag(_ old: String, to new: String) async {
        await editTags { try LibraryTags.rename($0, from: old, to: new) }
    }

    public func mergeTag(_ source: String, into target: String) async {
        await editTags { try LibraryTags.merge($0, source: source, into: target) }
    }

    public func deleteTag(_ name: String) async {
        await editTags { try LibraryTags.delete($0, name: name) }
    }

    /// Merges several tags into one in a single transaction: if one fails, none is merged.
    public func mergeTags(_ sources: [String], into target: String) async {
        await editTags { db in for source in sources { try LibraryTags.merge(db, source: source, into: target) } }
    }

    /// Deletes several tags in a single transaction.
    public func deleteTags(_ names: [String]) async {
        await editTags { db in for name in names { try LibraryTags.delete(db, name: name) } }
    }

    /// Every tag with its use count, most used first (for the tag manager).
    public func allTags() async -> [TagCount] {
        guard let database else { return [] }
        return (try? await database.writer.read { try SampleQuery.tagCounts($0, limit: 1_000_000) }) ?? []
    }

    private func editTags(_ edit: @escaping @Sendable (Database) throws -> Void) async {
        guard let database else { return }
        do {
            try await database.writer.write { try edit($0) }
        } catch {
            message = error.localizedDescription
        }
        await refresh()
    }

    // MARK: Indexing

    public func startIndexing(retryFailed: Bool = false) async {
        if let text = await runIndexing(retryFailed: retryFailed) { note(text) }
    }

    /// Returns the result text if indexing ran to the end or was stopped.
    private func runIndexing(retryFailed: Bool) async -> String? {
        guard let database, let embedder, !isIndexing else {
            if embedder == nil { message = "The Core ML models were not found. See the README for how to build them." }
            return nil
        }
        var result: String?
        do {
            let run = try IndexJob.start(
                database: database, embedder: embedder, retryFailed: retryFailed, vectorIndex: vectorIndex)
            indexRun = run
            indexProgress = IndexProgress(total: 0, done: 0, failed: 0)
            for await progress in run.progress {
                indexProgress = progress
                if progress.done % 256 == 0 { await refresh(reloadLists: false) }
            }
            let summary = try await run.result()
            lastIndexSummary = summary
            result = summary.cancelled ? "Indexing stopped: \(summary.done) done." : summary.message
        } catch {
            message = error.localizedDescription
        }
        indexRun = nil
        indexProgress = nil
        await map?.placeNewSamples()
        await refresh()
        return result
    }

    public func cancelIndexing() { indexRun?.cancel() }

    // MARK: Multisamples

    /// Saves which folders of a location may form multisamples and groups that location again.
    public func updateMultisampleRules(_ location: LocationInfo, rules: MultisampleRules) async {
        guard let database else { return }
        do {
            try await database.writer.write { try MultisampleStore.save($0, locationID: location.id, rules) }
            try await MultisampleGrouper.rebuild(database: database, locationID: location.id)
        } catch {
            message = error.localizedDescription
        }
        await refresh()
    }

    /// The groups of a location, by name; empty when the library cannot be read.
    public func groups(in location: LocationInfo) async -> [MultisampleGroups.Info] {
        guard let database else { return [] }
        return (try? await MultisampleGroups.list(database: database, locationID: location.id)) ?? []
    }

    /// The members of a group in pitch order.
    public func members(ofGroup groupID: Int64) async -> [SampleRow] {
        guard let database else { return [] }
        return (try? await database.writer.read { try SampleQuery.members($0, groupID: groupID) }) ?? []
    }

    /// Samples of a location in no group whose name contains `text`.
    public func ungroupedSamples(in location: LocationInfo, matching text: String) async -> [SampleRow] {
        guard let database else { return [] }
        return (try? await database.writer.read { try SampleQuery.ungrouped($0, locationID: location.id, matching: text) }) ?? []
    }

    /// Runs one edit of ``MultisampleGroups`` and shows the result in the list; a failure becomes ``message``.
    public func editGroups(_ edit: (LibraryDatabase) async throws -> Void) async {
        guard let database else { return }
        do { try await edit(database) } catch { message = error.localizedDescription }
        await refresh()
    }

    /// The groups that samples of the first sample's location can be added to.
    public func groups(forSample id: Int64) async -> [MultisampleGroups.Info] {
        guard let database, let location = try? await MultisampleGroups.locationID(database: database, ofSample: id) else { return [] }
        return (try? await MultisampleGroups.list(database: database, locationID: location)) ?? []
    }

    /// Groups the samples; see ``MultisampleGroups/place(database:sampleIDs:name:into:)``.
    public func group(sampleIDs: [Int64], named name: String, into groupID: Int64?) async {
        await editGroups { try await MultisampleGroups.place(database: $0, sampleIDs: sampleIDs, name: name, into: groupID) }
    }

    /// Finds multisample groups again in every location; see ``MultisampleGrouper``. Groups whose members
    /// are not indexed yet are picked up by the run after indexing.
    public func regroup() async {
        guard let database else { return }
        do {
            let ids = try await database.writer.read { try Int64.fetchAll($0, sql: "SELECT id FROM locations") }
            for id in ids { try await MultisampleGrouper.rebuild(database: database, locationID: id) }
        } catch {
            message = error.localizedDescription
        }
    }
}
