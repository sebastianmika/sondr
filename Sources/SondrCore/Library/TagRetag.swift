import Foundation
import GRDB

/// Tag settings of one location.
public struct LocationTagging: Equatable, Codable, Sendable {
    /// Tags added to every sample in the location. Never filtered by rules.
    public var extraTags: [String]
    /// Blacklist for the tags derived from paths in this location.
    public var rules: [TagRule]

    public init(extraTags: [String] = [], rules: [TagRule] = []) {
        self.extraTags = extraTags
        self.rules = rules
    }
}

/// Everything that decides which auto tags a sample gets, besides the bundled aliases and stopwords.
public struct TaggingSettings: Equatable, Codable, Sendable {
    /// Blacklist for all locations.
    public var global: [TagRule]
    public var locations: [Int64: LocationTagging]

    public init(global: [TagRule] = [], locations: [Int64: LocationTagging] = [:]) {
        self.global = global
        self.locations = locations
    }

    func location(_ id: Int64) -> LocationTagging { locations[id] ?? LocationTagging() }
}

/// Computes the auto tags of a path under a set of ``TaggingSettings``.
///
/// Tags are the tagger's output for `<location folder name>/<path below it>`, minus the built-in default rules,
/// the global and the location's rules, plus the location's extra tags.
public struct TagComputer: Sendable {
    private let tagger: Tagger
    private let global: TagRuleSet
    private let perLocation: [Int64: (extras: Set<String>, rules: TagRuleSet)]

    /// - Throws: ``TagRuleError`` for a rule that cannot be compiled.
    public init(tagger: Tagger, settings: TaggingSettings) throws {
        self.tagger = tagger
        global = try TagRuleSet(settings.global)
        var perLocation: [Int64: (extras: Set<String>, rules: TagRuleSet)] = [:]
        for (id, item) in settings.locations {
            let extras = Set(
                item.extraTags.compactMap { try? LibraryTags.normalised($0) })
            perLocation[id] = (extras, try TagRuleSet(item.rules))
        }
        self.perLocation = perLocation
    }

    /// Tags for the file at `path` inside the location `locationID` rooted at `rootPath`.
    public func tags(locationID: Int64, rootPath: String, path: String) -> Set<String> {
        let relative = path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)).trimmingPrefix("/") : path[...]
        let rootName = (rootPath as NSString).lastPathComponent
        let own = perLocation[locationID]
        var result = tagger.tags(for: rootName + "/" + relative).filter { tag in
            !global.blocks(tag) && !(own?.rules.blocks(tag) ?? false)
        }
        if let own { result.formUnion(own.extras) }
        return result
    }
}

/// Changing tag settings after the fact: recomputes the auto tags of the samples that are affected.
///
/// A retag works on the **difference** between what the old and the new settings produce for a
/// sample. Only auto tags in that difference are removed or added. Manual tags, tags created by
/// renaming or merging, and tags the user removed (`removed_auto_tags`) are never touched.
public enum TagRetag {
    struct PathEntry {
        let locationID: Int64
        let rootPath: String
        let path: String
    }

    /// Samples whose tags can differ between the two settings: those with a path in a location whose
    /// settings changed, or all samples with a location if the global rules changed.
    public static func affectedSampleIDs(
        _ db: Database, old: TaggingSettings, new: TaggingSettings
    ) throws -> [Int64] {
        if old.global != new.global {
            return try Int64.fetchAll(
                db, sql: "SELECT DISTINCT sample_id FROM sample_paths WHERE location_id IS NOT NULL ORDER BY sample_id")
        }
        let changed = Set(old.locations.keys).union(new.locations.keys)
            .filter { old.location($0) != new.location($0) }
        guard !changed.isEmpty else { return [] }
        let json = String(decoding: try JSONEncoder().encode(changed.sorted()), as: UTF8.self)
        return try Int64.fetchAll(
            db,
            sql: """
                SELECT DISTINCT sample_id FROM sample_paths
                WHERE location_id IN (SELECT value FROM json_each(?)) ORDER BY sample_id
                """, arguments: [json])
    }

    /// The auto tags of one sample under `computer`: the union over its paths.
    public static func tags(_ db: Database, sampleID: Int64, computer: TagComputer) throws -> Set<String> {
        let entries = try entries(db, sampleIDs: [sampleID])[sampleID] ?? []
        return union(entries, computer)
    }

    /// Brings the auto tags of `sampleIDs` from what `old` produced to what `new` produces.
    /// Runs in the caller's transaction; call it per chunk of samples.
    public static func retag(_ db: Database, sampleIDs: [Int64], old: TagComputer, new: TagComputer) throws {
        let entries = try entries(db, sampleIDs: sampleIDs)
        for id in sampleIDs {
            let paths = entries[id] ?? []
            try apply(db, sampleID: id, old: union(paths, old), new: union(paths, new))
        }
        try LibraryTags.pruneUnused(db)
    }

    /// Removes auto rows for tags in `old` but not in `new`, then adds `new` (sticky removals win).
    /// Also used when the paths themselves changed, for instance when a location is removed.
    public static func apply(_ db: Database, sampleID: Int64, old: Set<String>, new: Set<String>) throws {
        let gone = old.subtracting(new)
        if !gone.isEmpty {
            let json = String(decoding: try JSONEncoder().encode(gone.sorted()), as: UTF8.self)
            try db.execute(
                sql: """
                    DELETE FROM sample_tags WHERE sample_id = ? AND source = 'auto'
                        AND tag_id IN (SELECT id FROM tags WHERE name IN (SELECT value FROM json_each(?)))
                    """, arguments: [sampleID, json])
        }
        try LibraryTags.applyAuto(db, sampleID: sampleID, tags: new)
    }

    // MARK: Helpers

    static func union(_ entries: [PathEntry], _ computer: TagComputer) -> Set<String> {
        var result = Set<String>()
        for entry in entries {
            result.formUnion(computer.tags(locationID: entry.locationID, rootPath: entry.rootPath, path: entry.path))
        }
        return result
    }

    static func entries(_ db: Database, sampleIDs: [Int64]) throws -> [Int64: [PathEntry]] {
        var result: [Int64: [PathEntry]] = [:]
        for ids in sampleIDs.chunked(LibraryTags.chunk) {
            let json = String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
            let rows = try Row.fetchCursor(
                db,
                sql: """
                    SELECT sample_paths.sample_id, sample_paths.path, locations.id AS location_id, locations.path AS root
                    FROM sample_paths JOIN locations ON locations.id = sample_paths.location_id
                    WHERE sample_paths.sample_id IN (SELECT value FROM json_each(?))
                    """, arguments: [json])
            while let row = try rows.next() {
                result[row["sample_id"], default: []].append(
                    PathEntry(locationID: row["location_id"], rootPath: row["root"], path: row["path"]))
            }
        }
        return result
    }
}
