import Foundation

/// The tags a folder would get, before anything is imported.
///
/// ``scan(root:extensions:tagger:)`` walks the folder once and looks at file names only (no hashing,
/// no decoding). Rules are applied afterwards by ``rows(global:location:)`` on the collected counts,
/// so editing a blacklist never touches the disk again. The preview counts files, not samples:
/// duplicates are only found when the content is hashed during the real import.
public struct TagPreview: Sendable {
    public struct Row: Equatable, Sendable, Identifiable {
        public var id: String { tag }
        public let tag: String
        /// Files that would get this tag.
        public let count: Int
        /// One path (below the folder) that produces it.
        public let example: String
        /// The first rule that hides the tag, if any.
        public let blockedBy: TagRule?
        /// True if ``blockedBy`` is one of the global rules.
        public let isGlobal: Bool
    }

    private struct Raw: Sendable {
        var count: Int
        var example: String
    }

    public let fileCount: Int
    private let raw: [String: Raw]

    /// - Throws: ``ScanError/rootMissing(_:)`` or `CancellationError`.
    public static func scan(root: URL, extensions: Set<String>? = nil, tagger: Tagger) async throws -> TagPreview {
        let root = LibraryScanner.realURL(root)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw ScanError.rootMissing(root.path) }
        let allowed = extensions ?? LibraryScanner.defaultExtensions

        // The walk is synchronous and can take seconds on a large folder: keep it off the caller's actor.
        let work = Task.detached(priority: .userInitiated) { () -> TagPreview in
            let files = LibraryScanner.walk(root: root, extensions: allowed)
            let computer = try TagComputer(tagger: tagger, settings: TaggingSettings())
            var raw: [String: Raw] = [:]
            for (index, file) in files.enumerated() {
                if index % 1000 == 0 { try Task.checkCancellation() }
                let relative = String(file.path.dropFirst(root.path.count)).trimmingPrefix("/")
                for tag in computer.tags(locationID: 0, rootPath: root.path, path: file.path) {
                    if raw[tag] == nil { raw[tag] = Raw(count: 1, example: String(relative)) } else { raw[tag]!.count += 1 }
                }
            }
            try Task.checkCancellation()
            return TagPreview(fileCount: files.count, raw: raw)
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    /// The tags with their counts, most common first, each marked with the rule that hides it.
    /// - Throws: ``TagRuleError`` for an invalid rule.
    public func rows(global: [TagRule] = [], location: [TagRule] = []) throws -> [Row] {
        let globalSet = try TagRuleSet(global)
        let locationSet = try TagRuleSet(location)
        return raw.map { tag, item in
            let byGlobal = globalSet.firstMatch(for: tag)
            let blocker = byGlobal ?? locationSet.firstMatch(for: tag)
            return Row(
                tag: tag, count: item.count, example: item.example, blockedBy: blocker, isGlobal: byGlobal != nil)
        }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }
    }

    /// How many distinct tags `rule` would hide, to show before it is added.
    public func matchCount(of rule: TagRule) throws -> Int {
        let set = try TagRuleSet([rule])
        return raw.keys.filter { set.blocks($0) }.count
    }
}
