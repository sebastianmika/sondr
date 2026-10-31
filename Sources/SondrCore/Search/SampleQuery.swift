import Foundation
import GRDB

/// Which samples a query is about. All set parts must match (AND).
public struct SampleFilter: Equatable, Sendable {
    public enum ClusterChoice: Equatable, Sendable {
        /// Assigned to this cluster with a score at or above ``ClusterAssigner/unsortedThreshold``.
        case cluster(Int)
        /// No cluster, or one that scores below the threshold.
        case unsorted
    }

    /// A sample must carry all of these tags.
    public var tags: [String] = []
    /// Every word must occur in the file name or the path below its location (case-insensitive).
    public var keyword = ""
    public var minDuration: Double?
    public var maxDuration: Double?
    public var cluster: ClusterChoice?
    public var locationID: Int64?
    public var embedState: String?
    /// Brushed ranges on the six audio dims, in the normalised 0...1 units of the parallel-coordinates
    /// view. A range reaching 0 (or 1) also takes everything below (above) the corpus percentile.
    /// Samples without dims never match a brushed dim.
    public var dimRanges: [Dim: ClosedRange<Double>] = [:]
    /// Only these samples, for example the ones inside an area picked on the 2D map. An empty set matches nothing.
    public var sampleIDs: Set<Int64>?
    /// Samples whose files vanished are hidden unless this is set.
    public var includeMissing = false

    public init() {}

    var isEmpty: Bool { self == SampleFilter() }

    /// `WHERE` conditions on the `samples` table (without the word WHERE) and their arguments. They are
    /// about single samples; a multisample group matches when any of its members does.
    func conditions(dimStats: [Dim: DimStats.Range] = [:]) -> (sql: String, arguments: StatementArguments) {
        var clauses: [String] = []
        var arguments = StatementArguments()
        if !includeMissing { clauses.append("samples.missing = 0") }
        if !tags.isEmpty {
            let unique = Array(Set(tags))
            let marks = Array(repeating: "?", count: unique.count).joined(separator: ", ")
            clauses.append(
                """
                samples.id IN (SELECT sample_id FROM sample_tags JOIN tags ON tags.id = tag_id
                    WHERE tags.name IN (\(marks)) GROUP BY sample_id HAVING count(*) = \(unique.count))
                """)
            arguments += StatementArguments(unique)
        }
        for word in keyword.split(whereSeparator: \.isWhitespace) {
            let pattern = "%" + word.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
            clauses.append("(COALESCE(samples.name, samples.filename) LIKE ? ESCAPE '\\' OR samples.rel_path LIKE ? ESCAPE '\\')")
            arguments += [pattern, pattern]
        }
        if let minDuration {
            clauses.append("samples.duration >= ?")
            arguments += [minDuration]
        }
        if let maxDuration {
            clauses.append("samples.duration <= ?")
            arguments += [maxDuration]
        }
        switch cluster {
        case .cluster(let id)?:
            clauses.append("samples.cluster_id = ? AND samples.cluster_score >= ?")
            arguments += [id, Double(ClusterAssigner.unsortedThreshold)]
        case .unsorted?:
            clauses.append("(samples.cluster_id IS NULL OR samples.cluster_score IS NULL OR samples.cluster_score < ?)")
            arguments += [Double(ClusterAssigner.unsortedThreshold)]
        case nil: break
        }
        if let locationID {
            clauses.append("samples.id IN (SELECT sample_id FROM sample_paths WHERE location_id = ?)")
            arguments += [locationID]
        }
        if let sampleIDs {
            // One JSON argument keeps the statement the same size whatever the number of ids.
            clauses.append("samples.id IN (SELECT value FROM json_each(?))")
            arguments += ["[" + sampleIDs.sorted().map(String.init).joined(separator: ",") + "]"]
        }
        if let embedState {
            clauses.append("samples.embed_state = ?")
            arguments += [embedState]
        }
        for dim in Dim.allCases {
            guard let brush = dimRanges[dim] else { continue }
            let column = "samples.\(dim.column)"
            guard let stats = dimStats[dim] else {
                clauses.append("0")
                continue
            }
            let span = stats.high - stats.low
            if span < AudioFeatures.epsilon {
                // Everything normalises to 0.5.
                clauses.append(brush.contains(0.5) ? "\(column) IS NOT NULL" : "0")
                continue
            }
            clauses.append("\(column) IS NOT NULL")
            if brush.lowerBound > 0 {
                clauses.append("\(column) >= ?")
                arguments += [stats.low + brush.lowerBound * span]
            }
            if brush.upperBound < 1 {
                clauses.append("\(column) <= ?")
                arguments += [stats.low + brush.upperBound * span]
            }
        }
        return (clauses.isEmpty ? "1" : clauses.joined(separator: " AND "), arguments)
    }
}

public enum SampleSortKey: String, CaseIterable, Sendable {
    case filename, path, duration, added, clusterScore
    case brightness, percussiveness, energy, tonality, noisiness

    /// The ORDER BY terms. NULLs (not indexed yet) go last in either direction; the id keeps paging stable.
    /// Columns that are never NULL skip the NULL term, so that an index on the expression can serve the order.
    func orderBy(ascending: Bool, grouped: Bool = false) -> String {
        let order = orderExpression(grouped: grouped)
        let direction = ascending ? "ASC" : "DESC"
        switch self {
        case .filename, .path, .duration, .added: return "\(order) \(direction), samples.id"
        default: return "(\(order) IS NULL), \(order) \(direction), samples.id"
        }
    }

    /// With `grouped`, the statement joins `sample_groups` and a group row sorts by the group's name.
    func orderExpression(grouped: Bool = false) -> String {
        switch self {
        case .filename: return "\(grouped ? "COALESCE(sample_groups.name, samples.name, samples.filename)" : "COALESCE(samples.name, samples.filename)") COLLATE NOCASE"
        case .path: return "samples.rel_path COLLATE NOCASE"
        case .duration: return "samples.duration"
        case .added: return "samples.scanned_at"
        case .clusterScore: return "samples.cluster_score"
        case .brightness: return "samples.dim_brightness"
        case .percussiveness: return "samples.dim_percussiveness"
        case .energy: return "samples.dim_energy"
        case .tonality: return "samples.dim_tonality"
        case .noisiness: return "samples.dim_noisiness"
        }
    }
}

public struct SampleSort: Equatable, Sendable {
    public var key: SampleSortKey
    public var ascending: Bool

    public init(_ key: SampleSortKey = .filename, ascending: Bool = true) {
        self.key = key
        self.ascending = ascending
    }
}

/// One line of the sample table.
public struct SampleRow: Equatable, Sendable, Identifiable {
    public let id: Int64
    public let filename: String
    /// What the app shows: the file name without a leading track number, see `LibraryScanner.internalName`.
    public let name: String
    public let relPath: String
    public let canonicalPath: String
    public let duration: Double
    public let sampleRate: Double
    public let channels: Int
    public let format: String
    public let missing: Bool
    public let embedState: String
    /// Why indexing failed, for `failed` samples.
    public let embedError: String?
    public let clusterID: Int?
    public let clusterScore: Double?
    public let tags: [String]
    /// Raw dims in ``Dim/allCases`` order; nil until the sample is indexed.
    public let dims: [Double]?
    public let waveThumb: Data?
    /// Set when the sample belongs to a multisample group.
    public var multisample: MultisampleInfo?
}

/// A sample's place in a multisample group (one instrument sampled at several pitches).
public struct MultisampleInfo: Equatable, Sendable {
    public let groupID: Int64
    /// The group's name; the file stem of its representative unless the owner renamed it.
    public let groupName: String
    /// Members of the whole group, not only those matching the current filter.
    public let size: Int
    /// The lowest and highest note of the group, as the file names write them; empty when members have no pitch.
    public let lowLabel: String
    public let highLabel: String
    /// MIDI pitch (C4 = 60) of this sample, and its note as the file name writes it; nil when unknown.
    public let pitch: Int?
    public let pitchLabel: String?
    /// Distinct tags over all members, sorted.
    public let tags: [String]
    /// Distinct sorted (score at or above the threshold) cluster ids over all members, ascending.
    public let clusters: [Int]
    /// For a member listed by ``SampleQuery/members(_:groupID:filter:)``: whether it matches the filter.
    public var matches = true
}

public struct SamplePage: Equatable, Sendable {
    public let rows: [SampleRow]
    /// Number of samples matching the filter, over all pages.
    public let total: Int
}

/// SQL for browsing. These are plain functions of an open database connection so tests can count
/// the statements they run.
public enum SampleQuery {
    static let tagSeparator = "\u{1F}"

    static func columns(grouped: Bool = false) -> String {
        """
        samples.id, samples.filename, \(grouped ? "COALESCE(sample_groups.name, samples.name, samples.filename)" : "COALESCE(samples.name, samples.filename)") AS name, samples.rel_path, samples.canonical_path, samples.duration,
        samples.sample_rate, samples.channels, samples.format, samples.missing, samples.embed_state,
        samples.cluster_id, samples.cluster_score, samples.embed_error,
        samples.dim_brightness, samples.dim_percussiveness, samples.dim_energy, samples.dim_tonality,
        samples.dim_noisiness, samples.dim_duration, samples.wave_thumb,
        (SELECT group_concat(tags.name, char(31)) FROM sample_tags JOIN tags ON tags.id = sample_tags.tag_id
            WHERE sample_tags.sample_id = samples.id) AS tag_names,
        samples.group_id, samples.pitch, samples.pitch_label,
        (SELECT count(*) FROM samples member WHERE member.group_id = samples.group_id) AS group_size,
        (SELECT member.pitch_label FROM samples member WHERE member.group_id = samples.group_id AND member.pitch IS NOT NULL
            ORDER BY member.pitch, member.id LIMIT 1) AS group_low,
        (SELECT member.pitch_label FROM samples member WHERE member.group_id = samples.group_id AND member.pitch IS NOT NULL
            ORDER BY member.pitch DESC, member.id LIMIT 1) AS group_high,
        (SELECT sample_groups.name FROM sample_groups WHERE sample_groups.id = samples.group_id) AS group_name,
        (SELECT group_concat(name, char(31)) FROM (SELECT DISTINCT tags.name AS name FROM samples member
            JOIN sample_tags ON sample_tags.sample_id = member.id JOIN tags ON tags.id = sample_tags.tag_id
            WHERE member.group_id = samples.group_id)) AS group_tags,
        (SELECT group_concat(cluster_id) FROM (SELECT DISTINCT member.cluster_id AS cluster_id FROM samples member
            WHERE member.group_id = samples.group_id AND member.cluster_id IS NOT NULL
                AND member.cluster_score >= \(ClusterAssigner.unsortedThreshold) ORDER BY member.cluster_id)) AS group_clusters
        """
    }

    /// One page of samples plus the total count: two statements, whatever the page size.
    ///
    /// With `collapseGroups`, each multisample group shows as one row: its representative, or the first
    /// member (by pitch) matching the filter when the representative does not match. The total counts
    /// those rows.
    public static func browse(
        _ db: Database, filter: SampleFilter, sort: SampleSort = SampleSort(), offset: Int = 0, limit: Int = 100,
        collapseGroups: Bool = false, withTotal: Bool = true
    ) throws -> SamplePage {
        let (conditions, arguments) = filter.conditions(dimStats: try dimStats(db, filter))
        let selected = collapseGroups ? "samples.id IN (SELECT id FROM first_of_group WHERE position = 1)" : conditions
        let withClause = collapseGroups ? "WITH \(firstOfGroup(conditions)) " : ""
        let sql = """
            \(withClause)SELECT \(columns(grouped: collapseGroups)) FROM samples
            \(collapseGroups ? "LEFT JOIN sample_groups ON sample_groups.id = samples.group_id" : "") WHERE \(selected)
            ORDER BY \(sort.key.orderBy(ascending: sort.ascending, grouped: collapseGroups))
            LIMIT ? OFFSET ?
            """
        let rows = try Row.fetchAll(db, sql: sql, arguments: arguments + [limit, offset]).map(makeRow)
        guard withTotal else { return SamplePage(rows: rows, total: 0) }
        let total = try Int.fetchOne(
            db,
            sql: collapseGroups
                ? "\(withClause)SELECT count(*) FROM first_of_group WHERE position = 1"
                : "SELECT count(*) FROM samples WHERE \(conditions)",
            arguments: arguments)!
        return SamplePage(rows: rows, total: total)
    }

    /// The zero-based position `browse` lists the sample at (its group's row when groups are collapsed),
    /// or nil when the filter hides it.
    public static func position(
        _ db: Database, of id: Int64, filter: SampleFilter, sort: SampleSort = SampleSort(), collapseGroups: Bool = false
    ) throws -> Int? {
        let (conditions, arguments) = filter.conditions(dimStats: try dimStats(db, filter))
        let selected = collapseGroups ? "samples.id IN (SELECT id FROM first_of_group WHERE position = 1)" : conditions
        let withClause = collapseGroups ? "WITH \(firstOfGroup(conditions)) " : ""
        let sql = """
            \(withClause)SELECT position FROM (
                SELECT samples.id AS sid, samples.group_id AS gid,
                    ROW_NUMBER() OVER (ORDER BY \(sort.key.orderBy(ascending: sort.ascending, grouped: collapseGroups))) - 1 AS position
                FROM samples
                \(collapseGroups ? "LEFT JOIN sample_groups ON sample_groups.id = samples.group_id" : "") WHERE \(selected))
            WHERE sid = ?\(collapseGroups ? " OR (gid IS NOT NULL AND gid = (SELECT group_id FROM samples WHERE id = ?))" : "")
            """
        return try Int.fetchOne(db, sql: sql, arguments: arguments + (collapseGroups ? [id, id] : [id]))
    }

    /// The members of a group in pitch order, whatever the filter. Each carries whether it matches `filter`
    /// (``MultisampleInfo/matches``), judged on the member alone.
    public static func members(_ db: Database, groupID: Int64, filter: SampleFilter = SampleFilter()) throws -> [SampleRow] {
        let (conditions, arguments) = filter.conditions(dimStats: try dimStats(db, filter))
        return try Row.fetchAll(
            db,
            sql: """
                SELECT \(columns()), (\(conditions)) AS matches FROM samples WHERE samples.group_id = ?
                ORDER BY samples.pitch, samples.rel_path, samples.id
                """,
            arguments: arguments + [groupID]
        ).map(makeRow)
    }

    /// Samples of a location that belong to no group and whose name contains `text`, by name.
    public static func ungrouped(_ db: Database, locationID: Int64, matching text: String = "", limit: Int = 300) throws -> [SampleRow] {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return try Row.fetchAll(
            db,
            sql: """
                SELECT \(columns()) FROM samples WHERE samples.group_id IS NULL AND samples.missing = 0
                AND samples.id IN (SELECT sample_id FROM sample_paths WHERE location_id = ?)
                AND COALESCE(samples.name, samples.filename) LIKE ? ESCAPE '\\'
                ORDER BY COALESCE(samples.name, samples.filename) COLLATE NOCASE, samples.id LIMIT ?
                """,
            arguments: [locationID, "%" + escaped + "%", limit]
        ).map(makeRow)
    }

    /// A CTE numbering the matching samples of each group (representative first, then by pitch); samples
    /// outside any group get position 1.
    private static func firstOfGroup(_ conditions: String) -> String {
        """
        first_of_group AS (
            SELECT samples.id AS id,
                CASE WHEN samples.group_id IS NULL THEN 1 ELSE row_number() OVER (
                    PARTITION BY samples.group_id
                    ORDER BY (samples.id IS sample_groups.representative_id) DESC, samples.pitch, samples.id) END AS position
            FROM samples LEFT JOIN sample_groups ON sample_groups.id = samples.group_id
            WHERE \(conditions))
        """
    }

    /// Rows for the given ids, in that order (ids that no longer exist are skipped). One statement.
    public static func rows(_ db: Database, ids: [Int64]) throws -> [SampleRow] {
        guard !ids.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let found = try Row.fetchAll(
            db, sql: "SELECT \(columns()) FROM samples WHERE samples.id IN (\(marks))", arguments: StatementArguments(ids)
        ).map(makeRow)
        let byID = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }

    /// Ids of all samples matching `filter` (at most `limit` of them).
    public static func ids(_ db: Database, filter: SampleFilter, limit: Int = -1) throws -> [Int64] {
        let (conditions, arguments) = filter.conditions(dimStats: try dimStats(db, filter))
        return try Int64.fetchAll(db, sql: "SELECT id FROM samples WHERE \(conditions) LIMIT ?", arguments: arguments + [limit])
    }

    /// Most used tags among the samples matching `filter`, with their counts.
    public static func tagCounts(_ db: Database, filter: SampleFilter = SampleFilter(), limit: Int = 200) throws
        -> [TagCount]
    {
        let (conditions, arguments) = filter.conditions(dimStats: try dimStats(db, filter))
        let sql = """
            SELECT tags.name AS name, count(*) AS uses FROM sample_tags JOIN tags ON tags.id = sample_tags.tag_id
            WHERE sample_tags.sample_id IN (SELECT id FROM samples WHERE \(conditions))
            GROUP BY tags.id ORDER BY uses DESC, tags.name LIMIT ?
            """
        return try Row.fetchAll(db, sql: sql, arguments: arguments + [limit]).map { TagCount(name: $0["name"], count: $0["uses"]) }
    }

    /// Ranges needed to turn brushed (normalised) dims into SQL; only loaded when something is brushed.
    private static func dimStats(_ db: Database, _ filter: SampleFilter) throws -> [Dim: DimStats.Range] {
        filter.dimRanges.isEmpty ? [:] : try DimStats.ranges(db)
    }

    /// Normalised dims of a bounded, repeatable pseudo-random sample of the samples matching `filter`,
    /// for drawing the parallel-coordinates view. `total` counts all matching samples that have dims.
    public static func dimSample(_ db: Database, filter: SampleFilter, limit: Int = 2000) throws -> DimSample {
        let ranges = try DimStats.ranges(db)
        let (conditions, arguments) = filter.conditions(dimStats: ranges)
        let columns = Dim.allCases.map { "samples.\($0.column)" }
        let matching = "\(conditions) AND samples.dim_brightness IS NOT NULL"
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(columns.joined(separator: ", ")) FROM samples WHERE \(matching)
                ORDER BY (samples.id * 2654435761) % 4294967291 LIMIT ?
                """, arguments: arguments + [limit])
        let lines = rows.map { row in
            Dim.allCases.enumerated().map { index, dim -> Double in
                let raw: Double = row[index] ?? 0
                return ranges[dim]?.normalise(raw) ?? 0.5
            }
        }
        let total = try Int.fetchOne(db, sql: "SELECT count(*) FROM samples WHERE \(matching)", arguments: arguments)!
        return DimSample(lines: lines, total: total)
    }

    private static func multisample(_ row: Row) -> MultisampleInfo? {
        guard let groupID: Int64 = row["group_id"] else { return nil }
        let low: String? = row["group_low"], high: String? = row["group_high"]
        let tags: String? = row["group_tags"], clusters: String? = row["group_clusters"]
        return MultisampleInfo(
            groupID: groupID, groupName: row["group_name"], size: row["group_size"], lowLabel: low ?? "", highLabel: high ?? "",
            pitch: row["pitch"], pitchLabel: row["pitch_label"],
            tags: tags?.components(separatedBy: tagSeparator).sorted() ?? [],
            clusters: clusters?.split(separator: ",").compactMap { Int($0) } ?? [],
            matches: row.hasColumn("matches") ? (row["matches"] as Int) != 0 : true)
    }

    private static func makeRow(_ row: Row) -> SampleRow {
        let dims: [Double]? = row["dim_brightness"] == nil ? nil : [
            "dim_brightness", "dim_percussiveness", "dim_energy", "dim_tonality", "dim_noisiness", "dim_duration",
        ].map { row[$0] ?? 0 }
        let names: String? = row["tag_names"]
        return SampleRow(
            id: row["id"], filename: row["filename"], name: row["name"], relPath: row["rel_path"], canonicalPath: row["canonical_path"],
            duration: row["duration"], sampleRate: row["sample_rate"], channels: row["channels"],
            format: row["format"], missing: (row["missing"] as Int) != 0, embedState: row["embed_state"], embedError: row["embed_error"],
            clusterID: row["cluster_id"], clusterScore: row["cluster_score"],
            tags: names?.components(separatedBy: tagSeparator).sorted() ?? [], dims: dims, waveThumb: row["wave_thumb"],
            multisample: multisample(row))
    }
}

public struct TagCount: Equatable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let count: Int
}

public struct DimSample: Equatable, Sendable {
    /// One line per sample: its six normalised dims in ``Dim/allCases`` order.
    public let lines: [[Double]]
    public let total: Int
}
