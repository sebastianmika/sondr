import Foundation
import GRDB
import Observation
import simd

/// How the map is drawn. Unlike ``MapParameters`` it never changes the layout stored in the database.
public struct MapDisplay: Codable, Equatable, Sendable {
    /// Spread the dots evenly over the frame (see ``MapDots/rankWarped()``).
    public var rankWarp = false

    public init() {}
}

/// Where the map settings are kept between runs.
public struct MapSettingsStore: Sendable {
    public var load: @Sendable () -> MapParameters
    public var save: @Sendable (MapParameters) -> Void
    public var loadDisplay: @Sendable () -> MapDisplay
    public var saveDisplay: @Sendable (MapDisplay) -> Void

    public init(
        load: @escaping @Sendable () -> MapParameters, save: @escaping @Sendable (MapParameters) -> Void,
        loadDisplay: @escaping @Sendable () -> MapDisplay = { MapDisplay() }, saveDisplay: @escaping @Sendable (MapDisplay) -> Void = { _ in }
    ) {
        self.load = load
        self.save = save
        self.loadDisplay = loadDisplay
        self.saveDisplay = saveDisplay
    }

    /// Stores the settings as JSON under one key.
    public static func userDefaults(_ defaults: UserDefaults = .standard, key: String = "mapParameters") -> MapSettingsStore {
        let box = DefaultsBox(defaults: defaults)
        return MapSettingsStore(
            load: {
                box.defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(MapParameters.self, from: $0) }?.clamped()
                    ?? MapParameters()
            },
            save: { box.defaults.set(try? JSONEncoder().encode($0), forKey: key) },
            loadDisplay: { box.defaults.data(forKey: key + "Display").flatMap { try? JSONDecoder().decode(MapDisplay.self, from: $0) } ?? MapDisplay() },
            saveDisplay: { box.defaults.set(try? JSONEncoder().encode($0), forKey: key + "Display") })
    }

    /// `UserDefaults` is safe to use from any thread; it is just not marked as such.
    private struct DefaultsBox: @unchecked Sendable { let defaults: UserDefaults }
}

/// State of the 2D map for the views: the current map, the settings, and the preview being tuned.
///
/// While `isTuning`, every change to ``draft`` computes a new preview after a short pause, and a new
/// change cancels the one in flight. The preview is only a preview: ``keep()`` saves it (and makes the
/// draft the new default), ``discard()`` drops it.
@MainActor
@Observable
public final class MapModel {
    public enum Phase: Equatable {
        case idle
        case computing(done: Int, total: Int)
        case previewing
        case working(String)
        case failed(String)
    }

    public private(set) var phase = Phase.idle
    public private(set) var current: StoredMap?
    public private(set) var hasPrevious = false
    /// The current map.
    public private(set) var dots: MapDots? { didSet { revision += 1 } }
    private var layoutDots: MapDots? { didSet { dots = shown(layoutDots) } }
    public private(set) var preview: MapPreview?
    /// The previewed layout (the fitted sample only), also while it is still being computed.
    public private(set) var previewDots: MapDots? { didSet { revision += 1 } }
    private var layoutPreviewDots: MapDots? { didSet { previewDots = shown(layoutPreviewDots) } }
    /// How the dots are drawn. Persisted; `dots` and `previewDots` follow it.
    public var display = MapDisplay() {
        didSet {
            guard display != oldValue else { return }
            settings.saveDisplay(display)
            dots = shown(layoutDots)
            previewDots = shown(layoutPreviewDots)
        }
    }

    private func shown(_ dots: MapDots?) -> MapDots? { display.rankWarp ? dots?.rankWarped() : dots }
    /// Changes whenever ``dots`` or ``previewDots`` change, so a view knows when to draw again.
    public private(set) var revision = 0
    public private(set) var canBuild = false
    public private(set) var isTuning = false
    /// The settings the next map is built with.
    public private(set) var saved = MapParameters()
    /// Settings being tried. Changing them while tuning starts a new preview.
    public var draft = MapParameters() {
        didSet { if !applyingDraft, isTuning, draft != oldValue { schedulePreview() } }
    }

    /// Suggests rebuilding once the library has grown noticeably since the map was built.
    public var rebuildHint: String? {
        guard let current, current.growth > Self.growthHint else { return nil }
        return "The library has grown by \(Int((current.growth * 100).rounded())) % since this map was built. Rebuilding may give a better layout."
    }

    static let growthHint = 0.2

    /// Set when something outside the map view (the Settings window) wants the layout panel opened.
    public var layoutPanelRequested = false

    public func requestLayoutPanel() { layoutPanelRequested = true }

    /// Saves settings edited outside a tuning session. They become the starting point of the next one.
    public func saveSettings(_ parameters: MapParameters) {
        let clamped = parameters.clamped()
        settings.save(clamped)
        saved = clamped
        if !isTuning { setDraft(clamped) }
    }

    private let database: LibraryDatabase
    private let service: MapService
    private let modelVersion: @Sendable () async throws -> String
    private let settings: MapSettingsStore
    private let debounce: Duration
    private let unavailableReason: @MainActor () -> String?
    private var previewTask: Task<Void, Never>?
    private var generation = 0
    private var applyingDraft = false

    public init(
        database: LibraryDatabase, modelVersion: @escaping @Sendable () async throws -> String,
        settings: MapSettingsStore, debounce: Duration = .milliseconds(400),
        unavailableReason: @escaping @MainActor () -> String? = { nil }
    ) {
        self.database = database
        self.service = MapService(database: database)
        self.modelVersion = modelVersion
        self.settings = settings
        self.debounce = debounce
        self.unavailableReason = unavailableReason
        self.display = settings.loadDisplay()
    }

    /// Why no preview can start right now, if something else is using the GPU.
    func unavailableReasonForTesting() -> String? { unavailableReason() }

    // MARK: Loading

    /// Reads the current map and the saved settings.
    public func load() async {
        setDraft(settings.load().clamped(), saved: true)
        await reload(force: true)
    }

    /// Re-reads the map after samples were added or removed.
    public func reloadFromDatabase() async { await reload() }

    private func reload(force: Bool = false) async {
        do {
            let (map, previous, indexed) = try await database.writer.read { db in
                (
                    try MapStore.current(db), try MapStore.previous(db) != nil,
                    try Int.fetchOne(
                        db,
                        sql: """
                            SELECT count(*) FROM samples JOIN embeddings ON embeddings.sample_id = samples.id
                            WHERE samples.embed_state = 'done' AND samples.missing = 0
                            """) ?? 0
                )
            }
            canBuild = indexed >= MapParameters.minimumSamples
            hasPrevious = previous
            if force || map?.id != current?.id || map?.pointCount != current?.pointCount {
                if let map {
                    let id = map.id
                    layoutDots = try await database.writer.read { try MapDots.load($0, mapID: id) }
                } else {
                    layoutDots = nil
                }
            }
            current = map
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: Tuning

    /// Opens a tuning session: the draft starts at the saved settings.
    public func beginTuning() {
        guard !isTuning else { return }
        setDraft(saved)
        isTuning = true
    }

    /// Closes the tuning session and drops a preview that was not kept.
    public func endTuning() {
        discard()
        isTuning = false
    }

    /// Drops the preview and puts the draft back to the saved settings.
    public func discard() {
        generation += 1
        previewTask?.cancel()
        previewTask = nil
        preview = nil
        layoutPreviewDots = nil
        if case .working = phase { return }
        phase = .idle
        setDraft(saved)
    }

    /// Computes a preview of the draft as it is now (no setting has to change). Only while tuning.
    public func requestPreview() {
        guard isTuning else { return }
        schedulePreview()
    }

    /// Resolves when the preview that is being computed (if any) is finished.
    public func waitForPreview() async {
        await previewTask?.value
    }

    private func schedulePreview() {
        if case .working = phase { return }
        generation += 1
        let mine = generation
        previewTask?.cancel()
        preview = nil
        phase = .computing(done: 0, total: 0)
        let parameters = draft
        previewTask = Task { [weak self] in
            do {
                try await Task.sleep(for: self?.debounce ?? .zero)
                guard let self, self.generation == mine else { return }
                if let reason = self.unavailableReason() {
                    self.phase = .failed(reason)
                    return
                }
                let version = try await self.modelVersion()
                let result = try await self.service.preview(parameters: parameters, modelVersion: version) { [weak self] progress in
                    Task { @MainActor [weak self] in self?.apply(progress, generation: mine) }
                }
                try Task.checkCancellation()
                guard self.generation == mine else { return }
                let clusters = try await self.database.writer.read { try MapDots.clusterIDs($0, for: result.sampleIDs) }
                guard self.generation == mine else { return }
                self.preview = result
                self.layoutPreviewDots = Self.dots(ids: result.sampleIDs, positions: result.positions, clusters: clusters)
                self.phase = .previewing
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.generation == mine else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    private var liveClusters: [Int]?

    private func apply(_ progress: MapProgress, generation mine: Int) {
        guard generation == mine, case .computing = phase else { return }
        switch progress.stage {
        case .fitting:
            phase = .computing(done: progress.done, total: progress.total)
            guard let ids = progress.sampleIDs, let positions = progress.positions else { return }
            if layoutPreviewDots?.ids != ids {
                liveClusters = nil
                Task { [database] in
                    let clusters = try? await database.writer.read { try MapDots.clusterIDs($0, for: ids) }
                    await MainActor.run { if self.generation == mine { self.liveClusters = clusters } }
                }
            }
            layoutPreviewDots = Self.dots(ids: ids, positions: positions, clusters: liveClusters ?? [Int](repeating: -1, count: ids.count))
        default:
            break
        }
    }

    private static func dots(ids: [Int64], positions: [SIMD2<Float>], clusters: [Int]) -> MapDots {
        MapDots(
            ids: ids, x: positions.map(\.x), y: positions.map(\.y), cluster: clusters,
            fitted: [Bool](repeating: true, count: ids.count))
    }

    // MARK: Keeping and restoring

    /// Saves the preview as the current map, places all other samples onto it, and makes the draft the new default.
    public func keep() async {
        guard let preview, phase == .previewing else { return }
        phase = .working("Placing samples")
        do {
            _ = try await service.keep(preview) { [weak self] progress in
                let text = progress.stage == .saving ? "Saving" : "Placing samples (\(progress.done) of \(progress.total))"
                Task { @MainActor [weak self] in
                    if case .working = self?.phase { self?.phase = .working(text) }
                }
            }
            settings.save(preview.parameters)
            self.preview = nil
            layoutPreviewDots = nil
            isTuning = false
            phase = .idle
            setDraft(preview.parameters, saved: true)
            await reload(force: true)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Swaps the current and the previous map.
    public func restorePrevious() async {
        do {
            _ = try await service.restorePrevious()
            await reload(force: true)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Places samples added since the map was built. Call after indexing.
    public func placeNewSamples() async {
        do {
            let placed = try await service.placeNewSamples()
            if placed > 0 { await reload(force: true) } else { await reload() }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func setDraft(_ parameters: MapParameters, saved isSaved: Bool = false) {
        applyingDraft = true
        defer { applyingDraft = false }
        if isSaved { saved = parameters }
        draft = parameters
    }
}
