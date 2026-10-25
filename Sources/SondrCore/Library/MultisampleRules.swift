import Foundation
import GRDB

/// Which folders of a location may form multisample groups: a default and per-folder overrides.
/// The nearest ancestor with an override wins, so "everything except `Keys/Drums`" is a default of
/// `true` plus one override.
public struct MultisampleRules: Codable, Equatable, Sendable {
    public struct Override: Codable, Equatable, Sendable {
        /// Relative to the location root, no leading or trailing slash.
        public var folder: String
        public var group: Bool

        public init(folder: String, group: Bool) {
            self.folder = folder
            self.group = group
        }
    }

    public var groupByDefault: Bool
    public var overrides: [Override]

    public init(groupByDefault: Bool = true, overrides: [Override] = []) {
        self.groupByDefault = groupByDefault
        self.overrides = overrides
    }

    /// Whether files directly in `folder` (relative to the location root; empty for the root) may be grouped.
    public func allows(folder: String) -> Bool {
        var best: Override?
        for item in overrides where Self.contains(item.folder, folder) {
            if best == nil || item.folder.count > best!.folder.count { best = item }
        }
        return best?.group ?? groupByDefault
    }

    private static func contains(_ ancestor: String, _ folder: String) -> Bool {
        ancestor.isEmpty || folder == ancestor || folder.hasPrefix(ancestor + "/")
    }
}

/// Reads and writes a location's ``MultisampleRules``, kept as JSON in `locations.group_rules`.
public enum MultisampleStore {
    public static func load(_ db: Database, locationID: Int64) throws -> MultisampleRules {
        decode(try String.fetchOne(db, sql: "SELECT group_rules FROM locations WHERE id = ?", arguments: [locationID]))
    }

    /// The rules in a stored `group_rules` value; the defaults when it is empty or unreadable.
    public static func decode(_ text: String?) -> MultisampleRules {
        text.flatMap { try? JSONDecoder().decode(MultisampleRules.self, from: Data($0.utf8)) } ?? MultisampleRules()
    }

    public static func save(_ db: Database, locationID: Int64, _ rules: MultisampleRules) throws {
        let data = try JSONEncoder().encode(rules)
        try db.execute(
            sql: "UPDATE locations SET group_rules = ? WHERE id = ?",
            arguments: [String(decoding: data, as: UTF8.self), locationID])
    }
}
