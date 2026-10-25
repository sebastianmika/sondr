import Foundation
import GRDB

/// Reads and writes the tag settings: extra tags and rules per location, global rules in `meta`.
/// A library without saved global rules starts with ``DefaultTagRules``.
public enum TaggingStore {
    static let globalKey = "tag_rules"

    public static func load(_ db: Database) throws -> TaggingSettings {
        // No saved row yet (a new library): the global rules start as ``DefaultTagRules``. Once saved, even
        // an empty list, they are plain user rules.
        let stored = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [globalKey])
        let global = stored == nil ? DefaultTagRules.rules : try TagRule.decode(stored)
        var locations: [Int64: LocationTagging] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT id, extra_tags, tag_rules FROM locations") {
            locations[row["id"]] = tagging(extraTags: row["extra_tags"], rules: row["tag_rules"])
        }
        return TaggingSettings(global: global, locations: locations)
    }

    /// - Throws: ``TagRuleError`` if a rule is invalid (nothing is saved).
    public static func saveGlobal(_ db: Database, _ rules: [TagRule]) throws {
        _ = try TagRuleSet(rules)
        try db.execute(
            sql: "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            arguments: [globalKey, TagRule.encode(rules)])
    }

    /// Saves a location's settings. Extra tags are trimmed, lower-cased and de-duplicated.
    /// - Throws: ``TagRuleError`` if a rule is invalid (nothing is saved).
    public static func save(_ db: Database, locationID: Int64, _ tagging: LocationTagging) throws {
        _ = try TagRuleSet(tagging.rules)
        let extras = normalised(tagging.extraTags)
        try db.execute(
            sql: "UPDATE locations SET extra_tags = ?, tag_rules = ? WHERE id = ?",
            arguments: [
                String(decoding: try JSONEncoder().encode(extras), as: UTF8.self),
                TagRule.encode(tagging.rules), locationID,
            ])
    }

    /// Trimmed, lower-cased, de-duplicated, empty ones dropped; first occurrence order kept.
    public static func normalised(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.compactMap { try? LibraryTags.normalised($0) }.filter { seen.insert($0).inserted }
    }

    static func tagging(extraTags: String?, rules: String?) -> LocationTagging {
        let extras = extraTags.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
        return LocationTagging(extraTags: extras, rules: (try? TagRule.decode(rules)) ?? [])
    }
}
