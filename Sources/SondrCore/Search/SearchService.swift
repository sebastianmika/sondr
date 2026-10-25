import Foundation
import GRDB

public struct SearchResult: Equatable, Sendable, Identifiable {
    public let row: SampleRow
    /// Cosine similarity with the query.
    public let score: Float

    public var id: Int64 { row.id }
}

public enum SearchError: Error, Equatable, LocalizedError {
    case notIndexed(Int64)
    case emptyQuery

    public var errorDescription: String? {
        switch self {
        case .notIndexed(let id): return "Sample \(id) has no embedding yet."
        case .emptyQuery: return "Type something to search for."
        }
    }
}

/// Text search, find-similar and browsing over the library.
public actor SearchService {
    private let database: LibraryDatabase
    private let index: VectorIndex
    private let embedder: any Embedder

    public init(database: LibraryDatabase, index: VectorIndex, embedder: any Embedder) {
        self.database = database
        self.index = index
        self.embedder = embedder
    }

    /// Samples whose audio is closest to the text, best first.
    ///
    /// - Parameter filter: If not empty, only samples matching it can appear.
    public func searchText(_ query: String, k: Int = 50, filter: SampleFilter = SampleFilter()) async throws -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SearchError.emptyQuery }
        let vector = try await embedder.embed(text: trimmed)
        return try await nearest(to: vector, k: k, filter: filter, excluding: nil)
    }

    /// Samples that sound like `id`, best first, not including `id` itself.
    public func similar(to id: Int64, k: Int = 50, filter: SampleFilter = SampleFilter()) async throws -> [SearchResult] {
        guard let vector = await index.vector(for: id) else { throw SearchError.notIndexed(id) }
        return try await nearest(to: vector, k: k, filter: filter, excluding: id)
    }

    public func browse(
        filter: SampleFilter = SampleFilter(), sort: SampleSort = SampleSort(), offset: Int = 0, limit: Int = 100,
        collapseGroups: Bool = false
    ) async throws -> SamplePage {
        try await database.writer.read {
            try SampleQuery.browse($0, filter: filter, sort: sort, offset: offset, limit: limit, collapseGroups: collapseGroups)
        }
    }

    public func tagCounts(filter: SampleFilter = SampleFilter(), limit: Int = 200) async throws -> [TagCount] {
        try await database.writer.read { try SampleQuery.tagCounts($0, filter: filter, limit: limit) }
    }

    private func nearest(to vector: [Float], k: Int, filter: SampleFilter, excluding: Int64?) async throws
        -> [SearchResult]
    {
        var allowed: Set<Int64>?
        if !filter.isEmpty {
            allowed = Set(try await database.writer.read { try SampleQuery.ids($0, filter: filter) })
        }
        let hits = try await index.topK(vector, k: k, allowed: allowed, excluding: excluding)
        let rows = try await database.writer.read { try SampleQuery.rows($0, ids: hits.map(\.id)) }
        let scores = Dictionary(uniqueKeysWithValues: hits.map { ($0.id, $0.score) })
        return rows.compactMap { row in scores[row.id].map { SearchResult(row: row, score: $0) } }
    }
}
