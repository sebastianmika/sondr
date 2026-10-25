import Foundation
import Observation

public enum SearchMode: String, CaseIterable, Sendable, Identifiable {
    /// Words in file name and folder names.
    case keyword
    /// Describe the sound; matched by the CLAP text model.
    case text

    public var id: String { rawValue }
}

/// What the sample table shows: a filtered, sorted, paged list; text-search results; or the
/// samples most similar to one sample.
@MainActor
@Observable
public final class BrowseModel {
    public static let pageSize = 200
    public static let searchResultCount = 100

    public enum Content: Equatable, Sendable {
        case browse
        case textSearch(String)
        case similar(to: Int64, name: String)
    }

    public var filter = SampleFilter() {
        didSet { if filter != oldValue { scheduleReload(delay: .zero) } }
    }
    public var sort = SampleSort() {
        didSet { if sort != oldValue, content == .browse { scheduleReload(delay: .zero) } }
    }
    public var mode = SearchMode.keyword {
        didSet { if mode != oldValue { applySearchText() } }
    }
    /// The search field. Applied after a short pause in typing.
    public var searchText = "" {
        didSet { if searchText != oldValue { scheduleSearch() } }
    }

    /// Shows each multisample group as one row (see ``SampleQuery/browse(_:filter:sort:offset:limit:collapseGroups:)``).
    public var collapseGroups = true {
        didSet { if collapseGroups != oldValue, content == .browse { scheduleReload(delay: .zero) } }
    }
    /// Groups whose members the list shows below the group's row.
    public private(set) var expandedGroups: Set<Int64> = []
    private var membersOfGroup: [Int64: [SampleRow]] = [:]

    /// Whether ``rows`` was loaded with groups collapsed. Unlike ``collapseGroups`` it changes together with the rows.
    public private(set) var showsGroups = true
    public private(set) var rows: [SampleRow] = []
    public private(set) var total = 0
    public private(set) var scores: [Int64: Float] = [:]
    public private(set) var content = Content.browse
    /// Samples to show as "the result" elsewhere (the map): the search results, or everything the
    /// filters let through. Nil when nothing is narrowed down, or when that is too many to list.
    public private(set) var highlight: Set<Int64>? { didSet { highlightRevision += 1 } }
    /// Changes whenever ``highlight`` is set, so a view knows when to draw again.
    public private(set) var highlightRevision = 0
    /// A sample that was selected without being on a loaded page (for example from the map).
    public private(set) var pinned: SampleRow?
    static let highlightLimit = 100_000
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?

    private let app: AppModel
    private var reloadTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var generation = 0

    public init(app: AppModel) {
        self.app = app
    }

    public var hasMore: Bool { content == .browse && rows.count < total }

    // MARK: Loading

    /// Loads the first page again (after a filter, sort or library change). Search results are
    /// searched again with the new filter.
    public func reload() async {
        reloadTask?.cancel()
        generation += 1
        await refreshContent(generation: generation)
    }

    private func scheduleReload(delay: Duration) {
        reloadTask?.cancel()
        generation += 1
        let current = generation
        reloadTask = Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            if Task.isCancelled { return }
            await refreshContent(generation: current)
        }
    }

    private func refreshContent(generation current: Int) async {
        switch content {
        case .browse: await loadPage(first: true, generation: current)
        case .textSearch(let text): await showResults(.textSearch(text), generation: current) { try await $0.searchText(text, k: Self.searchResultCount, filter: $1) }
        case .similar(let id, let name): await showResults(.similar(to: id, name: name), generation: current) { try await $0.similar(to: id, k: Self.searchResultCount, filter: $1) }
        }
    }

    /// Call when a row near the end becomes visible; fetches the next page.
    public func loadMoreIfNeeded(at row: SampleRow) async {
        guard hasMore, !isLoading, rows.suffix(20).contains(where: { $0.id == row.id }) else { return }
        await loadPage(first: false, generation: generation)
    }

    private func loadPage(first: Bool, generation current: Int) async {
        guard let database = app.database else { return }
        isLoading = true
        defer { isLoading = false }
        let offset = first ? 0 : rows.count
        let filter = filter, sort = sort, collapse = collapseGroups
        let size = Self.pageSize
        do {
            let page = try await database.writer.read {
                try SampleQuery.browse($0, filter: filter, sort: sort, offset: offset, limit: size, collapseGroups: collapse)
            }
            guard current == generation else { return }  // a newer request superseded this one
            if first {
                forgetMembers()
                showsGroups = collapse
            }
            rows = first ? page.rows : rows + page.rows
            total = page.total
            scores = [:]
            errorMessage = nil
            if first { await updateHighlight(generation: current) }
        } catch {
            if current == generation { errorMessage = error.localizedDescription }
        }
    }

    /// The ids of the rows the list shows, top to bottom, including members of expanded groups.
    public var visibleIDs: [Int64] {
        rows.flatMap { row in [row.id] + children(of: row).map(\.id) }
    }

    /// The row `offset` places from the single selected one, clamped to the visible rows.
    /// With no usable selection, a step down starts at the first row and a step up at the last.
    public func rowID(moving offset: Int, from selection: Set<Int64>) -> Int64? {
        let ids = visibleIDs
        guard !ids.isEmpty else { return nil }
        guard selection.count == 1, let id = selection.first, let index = ids.firstIndex(of: id) else {
            return offset >= 0 ? ids.first : ids.last
        }
        return ids[min(max(index + offset, 0), ids.count - 1)]
    }

    /// The row of a sample on a loaded page, in an expanded group, or the pinned one.
    public func row(_ id: Int64) -> SampleRow? {
        rows.first { $0.id == id } ?? membersOfGroup.values.lazy.compactMap { $0.first { $0.id == id } }.first
            ?? (pinned?.id == id ? pinned : nil)
    }

    /// The rows of the given samples that the list knows, in list order.
    public func rows(for ids: Set<Int64>) -> [SampleRow] {
        visibleIDs.filter(ids.contains).compactMap(row)
    }

    // MARK: Multisample groups

    /// What the list shows below an expanded group row: the other members, in pitch order.
    /// Nothing for single samples, collapsed groups and when groups are not collapsed.
    public func children(of row: SampleRow) -> [SampleRow] {
        guard content == .browse, showsGroups, let group = row.multisample?.groupID, expandedGroups.contains(group)
        else { return [] }
        return (membersOfGroup[group] ?? []).filter { $0.id != row.id }
    }

    public func isExpanded(_ groupID: Int64) -> Bool { expandedGroups.contains(groupID) }

    public func setExpanded(_ groupID: Int64, _ expanded: Bool) async {
        guard expanded else {
            expandedGroups.remove(groupID)
            return
        }
        if membersOfGroup[groupID] == nil, let database = app.database {
            membersOfGroup[groupID] = try? await database.writer.read { try SampleQuery.members($0, groupID: groupID) }
        }
        if membersOfGroup[groupID] != nil { expandedGroups.insert(groupID) }
    }

    private func forgetMembers() {
        expandedGroups = []
        membersOfGroup = [:]
    }

    /// Makes sure ``row(_:)`` finds `id`, loading it if it is not on a loaded page. Replaces the previous pin.
    public func pin(_ id: Int64) async {
        if rows.contains(where: { $0.id == id }) {
            pinned = nil
            return
        }
        guard let database = app.database else { return }
        pinned = try? await database.writer.read { try SampleQuery.rows($0, ids: [id]).first }
    }

    private func updateHighlight(generation current: Int) async {
        switch content {
        case .textSearch, .similar:
            highlight = Set(rows.map(\.id))
        case .browse:
            guard !filter.isEmpty, total <= Self.highlightLimit, let database = app.database else {
                highlight = nil
                return
            }
            let filter = filter
            let ids = try? await database.writer.read { Set(try SampleQuery.ids($0, filter: filter)) }
            if current == generation { highlight = ids }
        }
    }

    /// Waits until typing and filter changes have been applied (for tests and scripted use).
    public func settle() async {
        await searchTask?.value
        await reloadTask?.value
    }

    // MARK: Search

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: mode == .keyword ? .milliseconds(150) : .milliseconds(400))
            if Task.isCancelled { return }
            await runSearch()
        }
    }

    private func applySearchText() {
        searchTask?.cancel()
        searchTask = Task { await runSearch() }
    }

    /// Runs the search field's current text in the current mode.
    public func runSearch() async {
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .keyword:
            if content != .browse {
                content = .browse
                if filter.keyword != text { filter.keyword = text } else { await reload() }
            } else if filter.keyword != text {
                filter.keyword = text  // reloads through the filter
            }
        case .text:
            if !filter.keyword.isEmpty { filter.keyword = "" }
            guard !text.isEmpty else {
                content = .browse
                await reload()
                return
            }
            reloadTask?.cancel()
            generation += 1
            await showResults(.textSearch(text), generation: generation) { try await $0.searchText(text, k: Self.searchResultCount, filter: $1) }
        }
    }

    /// Shows the samples most similar to `row`.
    public func showSimilar(to row: SampleRow) async {
        reloadTask?.cancel()
        generation += 1
        let id = row.id
        await showResults(.similar(to: id, name: row.name), generation: generation) {
            try await $0.similar(to: id, k: Self.searchResultCount, filter: $1)
        }
    }

    /// Leaves search results and goes back to the normal list.
    public func clearResults() async {
        guard content != .browse else { return }
        content = .browse
        if mode == .text { searchText = "" }
        await reload()
    }

    private func showResults(
        _ newContent: Content, generation current: Int,
        _ fetch: (SearchService, SampleFilter) async throws -> [SearchResult]
    ) async {
        guard let search = app.search else {
            errorMessage = "Search needs the Core ML models, which were not found."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let results = try await fetch(search, filter)
            guard current == generation else { return }
            content = newContent
            rows = results.map(\.row)
            scores = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0.score) })
            total = results.count
            errorMessage = nil
            await updateHighlight(generation: current)
        } catch {
            if current == generation { errorMessage = error.localizedDescription }
        }
    }
}
