import Foundation
import GRDB
import Testing

@testable import SondrCore

/// A scratch library folder built from the audio fixtures.
private struct Tree {
    let root: URL

    init() throws {
        let made = FileManager.default.temporaryDirectory
            .appendingPathComponent("sondr-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        root = LibraryScanner.realURL(made)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }

    /// Copies fixture `name` to `relative`.
    func add(_ name: String, as relative: String) throws {
        let target = url(relative)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Fixtures.url("audio/\(name)"), to: target)
    }

    func move(_ from: String, to: String) throws {
        try FileManager.default.createDirectory(
            at: url(to).deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url(from), to: url(to))
    }

    func delete(_ relative: String) throws { try FileManager.default.removeItem(at: url(relative)) }

    /// kick x2 (one in a nested folder), snare, a 12 s loop, a corrupt wav, a text file, a hidden file.
    static func standard() throws -> Tree {
        let tree = try Tree()
        try tree.add("kick_short.wav", as: "drums/kick.wav")
        try tree.add("kick_short.wav", as: "drums/old/kick copy.wav")
        try tree.add("snare_basic.wav", as: "snare.wav")
        try tree.add("loop_12s.flac", as: "loops/loop.flac")
        try tree.add("corrupt/not_audio.wav", as: "bad.wav")
        try Data("notes".utf8).write(to: tree.url("readme.txt"))
        try Data("x".utf8).write(to: tree.url(".hidden.wav"))
        return tree
    }

    /// Path, size and mtime of every file under the root.
    func snapshot() throws -> [String: String] {
        var result: [String: String] = [:]
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        for case let file as URL in files where file.hasDirectoryPath == false {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let digest = try LibraryScanner.sha256(of: file)
            result[file.path] = "\(attributes[.size]!) \(attributes[.modificationDate]!) \(digest)"
        }
        return result
    }
}

private func scalar(_ database: LibraryDatabase, _ sql: String) async throws -> Int {
    try await database.writer.read { try Int.fetchOne($0, sql: sql) ?? -1 }
}

@Test func firstScanCountsNewDuplicateAndErrorsExactly() async throws {
    let tree = try Tree.standard()
    defer { tree.remove() }
    let database = try LibraryDatabase(inMemory: ())

    let summary = try await LibraryScanner(database: database).scan(root: tree.root)

    #expect(summary.new == 3)
    #expect(summary.duplicate == 1)
    #expect(summary.moved == 0)
    #expect(summary.skipped == 0)
    #expect(summary.filtered == 0)
    #expect(summary.errors == 1)
    #expect(summary.missing == 0)
    #expect(summary.hashed == 4)
    #expect(summary.failures.map(\.path) == [tree.url("bad.wav").path])

    #expect(try await scalar(database, "SELECT count(*) FROM samples") == 3)
    #expect(try await scalar(database, "SELECT count(*) FROM sample_paths") == 4)
    #expect(try await scalar(database, "SELECT count(*) FROM samples WHERE missing = 1") == 0)
}

@Test func scanRecordsMetadataAndRelativePaths() async throws {
    let tree = try Tree()
    defer { tree.remove() }
    try tree.add("snare_basic.wav", as: "kits/808/snare.wav")
    let database = try LibraryDatabase(inMemory: ())
    _ = try await LibraryScanner(database: database).scan(root: tree.root)

    let row = try await database.writer.read { db -> [String: String] in
        let row = try Row.fetchOne(db, sql: "SELECT * FROM samples")!
        return Dictionary(uniqueKeysWithValues: row.columnNames.map { ($0, String(describing: row[$0] as DatabaseValue)) })
    }
    #expect(row["filename"] == "TEXT \"snare.wav\"" || row["filename"]?.contains("snare.wav") == true)
    #expect(row["rel_path"]?.contains("kits/808/snare.wav") == true)
    #expect(row["canonical_path"]?.contains(tree.url("kits/808/snare.wav").path) == true)
    #expect(row["format"]?.contains("wav") == true)
    #expect(row["sample_rate"]?.contains("48000") == true)
    #expect(row["channels"]?.contains("1") == true)
    #expect(try await scalar(database, "SELECT duration > 0.05 FROM samples") == 1)
    #expect(try await scalar(database, "SELECT length(content_hash) FROM samples") == 64)
    #expect(row["embed_state"]?.contains("pending") == true)
    #expect(try await scalar(database, "SELECT count(*) FROM locations") == 1)
}

@Test func rescanDoesNotRehashUnchangedFiles() async throws {
    let tree = try Tree.standard()
    defer { tree.remove() }
    let database = try LibraryDatabase(inMemory: ())
    let scanner = try LibraryScanner(database: database)
    _ = try await scanner.scan(root: tree.root)

    let again = try await scanner.scan(root: tree.root)

    #expect(again.skipped == 4)
    #expect(again.hashed == 0)
    #expect(again.new == 0)
    #expect(again.duplicate == 0)
    #expect(again.errors == 1)  // the corrupt file is retried
    #expect(try await scalar(database, "SELECT count(*) FROM samples") == 3)
    #expect(try await scalar(database, "SELECT count(*) FROM sample_paths") == 4)
}

@Test func scanLeavesOriginalsUntouched() async throws {
    let tree = try Tree.standard()
    defer { tree.remove() }
    let before = try tree.snapshot()
    let database = try LibraryDatabase(inMemory: ())
    let scanner = try LibraryScanner(database: database)
    _ = try await scanner.scan(root: tree.root)
    _ = try await scanner.scan(root: tree.root)
    #expect(try tree.snapshot() == before)
}

@Test func movedFileKeepsItsSample() async throws {
    let tree = try Tree.standard()
    defer { tree.remove() }
    let database = try LibraryDatabase(inMemory: ())
    let scanner = try LibraryScanner(database: database)
    _ = try await scanner.scan(root: tree.root)
    let idBefore = try await database.writer.read {
        try Int64.fetchOne($0, sql: "SELECT id FROM samples WHERE filename = 'snare.wav'")
    }

    try tree.move("snare.wav", to: "kits/snare renamed.wav")
    let summary = try await scanner.scan(root: tree.root)

    #expect(summary.moved == 1)
    #expect(summary.new == 0)
    #expect(summary.duplicate == 0)
    #expect(summary.missing == 0)
    #expect(summary.skipped == 3)
    let idAfter = try await database.writer.read {
        try Int64.fetchOne($0, sql: "SELECT id FROM samples WHERE rel_path = 'kits/snare renamed.wav'")
    }
    #expect(idAfter == idBefore)
    #expect(idAfter != nil)
    #expect(try await scalar(database, "SELECT count(*) FROM samples") == 3)
    #expect(try await scalar(database, "SELECT count(*) FROM sample_paths") == 4)
}

@Test func deletedFileIsFlaggedMissingAndRestoredWhenItReturns() async throws {
    let tree = try Tree.standard()
    defer { tree.remove() }
    let database = try LibraryDatabase(inMemory: ())
    let scanner = try LibraryScanner(database: database)
    _ = try await scanner.scan(root: tree.root)

    try tree.delete("snare.wav")
    let gone = try await scanner.scan(root: tree.root)
    #expect(gone.missing == 1)
    #expect(try await scalar(database, "SELECT count(*) FROM samples WHERE missing = 1") == 1)
    #expect(try await scalar(database, "SELECT count(*) FROM samples") == 3)  // not deleted

    let again = try await scanner.scan(root: tree.root)
    #expect(again.missing == 0)  // only newly missing samples are counted

    try tree.add("snare_basic.wav", as: "snare.wav")
    let back = try await scanner.scan(root: tree.root)
    #expect(back.moved == 1)
    #expect(try await scalar(database, "SELECT count(*) FROM samples WHERE missing = 1") == 0)
}

@Test func deletingOneOfTwoDuplicatesDoesNotFlagMissing() async throws {
    let tree = try Tree.standard()
    defer { tree.remove() }
    let database = try LibraryDatabase(inMemory: ())
    let scanner = try LibraryScanner(database: database)
    _ = try await scanner.scan(root: tree.root)

    try tree.delete("drums/kick.wav")
    let summary = try await scanner.scan(root: tree.root)

    #expect(summary.missing == 0)
    #expect(try await scalar(database, "SELECT count(*) FROM sample_paths") == 3)
    let canonical = try await database.writer.read {
        try String.fetchOne($0, sql: "SELECT canonical_path FROM samples WHERE content_hash IN (SELECT content_hash FROM samples WHERE filename LIKE 'kick%')")
    }
    #expect(canonical == tree.url("drums/old/kick copy.wav").path)
}

@Test func modifiedFileBecomesANewSample() async throws {
    let tree = try Tree()
    defer { tree.remove() }
    try tree.add("kick_short.wav", as: "a.wav")
    let database = try LibraryDatabase(inMemory: ())
    let scanner = try LibraryScanner(database: database)
    _ = try await scanner.scan(root: tree.root)

    try FileManager.default.removeItem(at: tree.url("a.wav"))
    try tree.add("snare_basic.wav", as: "a.wav")
    let summary = try await scanner.scan(root: tree.root)

    #expect(summary.new == 1)
    #expect(summary.missing == 0)
    #expect(try await scalar(database, "SELECT count(*) FROM samples") == 1)
    #expect(try await scalar(database, "SELECT count(*) FROM sample_paths") == 1)
}

@Test func touchedFileIsHashedButNotDuplicated() async throws {
    let tree = try Tree()
    defer { tree.remove() }
    try tree.add("kick_short.wav", as: "a.wav")
    let database = try LibraryDatabase(inMemory: ())
    let scanner = try LibraryScanner(database: database)
    _ = try await scanner.scan(root: tree.root)

    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: tree.url("a.wav").path)
    let summary = try await scanner.scan(root: tree.root)

    #expect(summary.hashed == 1)
    #expect(summary.skipped == 1)
    #expect(summary.new == 0 && summary.duplicate == 0)
    #expect(try await scalar(database, "SELECT count(*) FROM sample_paths") == 1)
    let rescan = try await scanner.scan(root: tree.root)
    #expect(rescan.hashed == 0)
}

@Test func maxLengthAndExtensionFiltersApply() async throws {
    let tree = try Tree.standard()
    defer { tree.remove() }
    let database = try LibraryDatabase(inMemory: ())
    let scanner = try LibraryScanner(database: database)

    let limited = try await scanner.scan(root: tree.root, maxLength: 5)
    #expect(limited.filtered == 1)
    #expect(limited.new == 2)
    #expect(try await scalar(database, "SELECT count(*) FROM samples WHERE filename = 'loop.flac'") == 0)
    #expect(try await scalar(database, "SELECT max_length FROM locations") == 5)

    let wavOnly = try await scanner.scan(root: tree.root, extensions: ["flac"])
    #expect(wavOnly.new == 1)
    #expect(wavOnly.errors == 0)
}

@Test func missingRootThrowsAndFlagsNothing() async throws {
    let tree = try Tree.standard()
    let database = try LibraryDatabase(inMemory: ())
    let scanner = try LibraryScanner(database: database)
    _ = try await scanner.scan(root: tree.root)
    tree.remove()

    await #expect(throws: ScanError.rootMissing(tree.root.path)) {
        try await scanner.scan(root: tree.root)
    }
    #expect(try await scalar(database, "SELECT count(*) FROM samples WHERE missing = 1") == 0)
}

@Test func emptyRootOfKnownLocationThrowsAndFlagsNothing() async throws {
    let tree = try Tree.standard()
    defer { tree.remove() }
    let database = try LibraryDatabase(inMemory: ())
    let scanner = try LibraryScanner(database: database)
    _ = try await scanner.scan(root: tree.root)
    for name in try FileManager.default.contentsOfDirectory(atPath: tree.root.path) { try tree.delete(name) }

    await #expect(throws: ScanError.rootEmpty(tree.root.path)) {
        try await scanner.scan(root: tree.root)
    }
    #expect(try await scalar(database, "SELECT count(*) FROM samples WHERE missing = 1") == 0)
}

@Test func secondConcurrentScanIsRejected() async throws {
    let tree = try Tree()
    defer { tree.remove() }
    for i in 0..<60 { try tree.add("kick_short.wav", as: "k\(i).wav") }
    let scanner = try LibraryScanner(database: LibraryDatabase(inMemory: ()))

    async let first: Result<ScanSummary, Error> = { do { return .success(try await scanner.scan(root: tree.root)) } catch { return .failure(error) } }()
    async let second: Result<ScanSummary, Error> = { do { return .success(try await scanner.scan(root: tree.root)) } catch { return .failure(error) } }()
    let results = await [first, second]

    let rejected = results.filter { if case .failure(let e) = $0, e as? JobError == .alreadyRunning(.scan) { true } else { false } }
    let succeeded = results.filter { if case .success = $0 { true } else { false } }
    #expect(rejected.count == 1)
    #expect(succeeded.count == 1)
}

@Test func largeBatchesAreSplitIntoSeveralTransactions() async throws {
    let tree = try Tree()
    defer { tree.remove() }
    let total = LibraryScanner.batchSize + 20
    for i in 0..<total { try tree.add("kick_short.wav", as: "k\(i).wav") }
    let database = try LibraryDatabase(inMemory: ())
    let summary = try await LibraryScanner(database: database).scan(root: tree.root)
    #expect(summary.new == 1)
    #expect(summary.duplicate == total - 1)
    #expect(try await scalar(database, "SELECT count(*) FROM sample_paths") == total)
}

@Test func scanTagsSamplesFromFolderNamesAndKeepsUserRemovals() async throws {
    let tree = try Tree()
    defer { tree.remove() }
    try tree.add("kick_short.wav", as: "Drums/Kicks/Kick_Hard.wav")
    let database = try LibraryDatabase(inMemory: ())
    let scanner = try LibraryScanner(database: database)
    _ = try await scanner.scan(root: tree.root)

    let (id, tags) = try await database.writer.read { db -> (Int64, [String]) in
        let id = try Int64.fetchOne(db, sql: "SELECT id FROM samples")!
        return (id, try LibraryTags.names(db, sampleID: id))
    }
    #expect(["drum", "hard", "kick"].allSatisfy(tags.contains))
    #expect(tags.contains { $0.hasPrefix("sondr-scan") })  // the location's own folder name is tagged ...
    #expect(!tags.contains("var") && !tags.contains("private"))  // ... but not its parents

    try await database.writer.write { try LibraryTags.remove($0, sampleID: id, name: "drum") }
    // A second copy under another "Drums" folder is a new path of the same sample.
    try tree.add("kick_short.wav", as: "More Drums/Drums/dup.wav")
    let summary = try await scanner.scan(root: tree.root)
    #expect(summary.duplicate == 1)

    let after = try await database.writer.read { try LibraryTags.names($0, sampleID: id) }
    #expect(!after.contains("drum"))
    #expect(after.contains("dup"))
    #expect(after.contains("kick"))
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ScanProgress] = []
    func add(_ p: ScanProgress) { lock.withLock { items.append(p) } }
    var all: [ScanProgress] { lock.withLock { items } }
}

@Test func scanReportsProgressUpToTheNumberOfFilesFound() async throws {
    let tree = try Tree()
    defer { tree.remove() }
    for i in 0..<250 { try tree.add("kick_short.wav", as: "k\(i).wav") }
    let log = ProgressLog()
    let scanner = try LibraryScanner(database: LibraryDatabase(inMemory: ()))
    _ = try await scanner.scan(root: tree.root, progress: { log.add($0) })

    let events = log.all
    #expect(events.first == ScanProgress(found: 250, processed: 0))
    #expect(events.last == ScanProgress(found: 250, processed: 250))
    #expect(zip(events, events.dropFirst()).allSatisfy { $0.processed <= $1.processed })
}

@Test func scanAppliesExtraTagsAndRulesAndStoresThem() async throws {
    let tree = try Tree()
    defer { tree.remove() }
    try tree.add("kick_short.wav", as: "Drums/Kicks/Kick_Hard.wav")
    let database = try LibraryDatabase(inMemory: ())
    let scanner = try LibraryScanner(database: database)
    let tagging = LocationTagging(extraTags: ["Drumhaus"], rules: [TagRule(kind: .glob, pattern: "h*")])
    _ = try await scanner.scan(root: tree.root, tagging: tagging)

    let tags = try await database.writer.read { try LibraryTags.names($0, sampleID: 1) }
    #expect(tags.contains("drumhaus") && tags.contains("kick") && tags.contains("drum"))
    #expect(!tags.contains("hard"))
    let stored = try await database.writer.read { try TaggingStore.load($0) }
    #expect(stored.locations.values.first == LocationTagging(extraTags: ["drumhaus"], rules: tagging.rules))

    // A rescan without settings keeps the stored ones and applies them to new files.
    try tree.add("snare_basic.wav", as: "Drums/Snares/Hard_Snare.wav")
    _ = try await scanner.scan(root: tree.root)
    let second = try await database.writer.read { try LibraryTags.names($0, sampleID: 2) }
    #expect(second.contains("drumhaus") && second.contains("snare") && !second.contains("hard"))
}

@Test func trackNumberTagsNeverReachASampleButExtraAndManualTagsStay() async throws {
    let tree = try Tree()
    defer { tree.remove() }
    try tree.add("kick_short.wav", as: "Drums/01 Kick.wav")
    let database = try LibraryDatabase(inMemory: ())
    let scanner = try LibraryScanner(database: database)
    let extras = LocationTagging(extraTags: ["07"])
    _ = try await scanner.scan(root: tree.root, tagging: extras)
    try await database.writer.write { try LibraryTags.add($0, sampleID: 1, name: "02") }

    let tags = try await database.writer.read { try LibraryTags.names($0, sampleID: 1) }
    #expect(tags.contains("kick") && tags.contains("07") && tags.contains("02"))
    #expect(!tags.contains("01"))  // the track number

    // A retag that blocks "kick" removes it but keeps the extra tag and the manual tag.
    let defaults = DefaultTagRules.rules
    let old = try TagComputer(tagger: Tagger.bundled(), settings: TaggingSettings(global: defaults, locations: [1: extras]))
    let new = try TagComputer(
        tagger: Tagger.bundled(),
        settings: TaggingSettings(global: defaults + [TagRule(kind: .text, pattern: "kick")], locations: [1: extras]))
    try await database.writer.write { try TagRetag.retag($0, sampleIDs: [1], old: old, new: new) }
    let after = try await database.writer.read { try LibraryTags.names($0, sampleID: 1) }
    #expect(!after.contains("kick") && !after.contains("01") && after.contains("07") && after.contains("02"))
}

@Test func scanRejectsInvalidRulesBeforeTouchingTheLibrary() async throws {
    let tree = try Tree()
    defer { tree.remove() }
    try tree.add("kick_short.wav", as: "kick.wav")
    let database = try LibraryDatabase(inMemory: ())
    let scanner = try LibraryScanner(database: database)
    await #expect(throws: TagRuleError.self) {
        _ = try await scanner.scan(root: tree.root, tagging: LocationTagging(rules: [TagRule(kind: .regex, pattern: "(")]))
    }
    let count = try await scalar(database, "SELECT count(*) FROM locations")
    #expect(count == 0)
    #expect(!database.jobs.isRunning(.scan))
}

@Test func scanStoresMultisampleRulesAndKeepsThemOnRescan() async throws {
    let tree = try Tree()
    defer { tree.remove() }
    try tree.add("kick_short.wav", as: "Keys/Piano_C3.wav")
    let database = try LibraryDatabase(inMemory: ())
    let scanner = try LibraryScanner(database: database)
    let rules = MultisampleRules(groupByDefault: false, overrides: [.init(folder: "Keys", group: true)])
    _ = try await scanner.scan(root: tree.root, multisampleRules: rules)
    _ = try await scanner.scan(root: tree.root)

    let stored = try await database.writer.read { try LibraryInfo.locations($0) }
    #expect(stored.map(\.multisampleRules) == [rules])
}

private func names(_ database: LibraryDatabase) async throws -> [String] {
    try await database.writer.read { try String.fetchAll($0, sql: "SELECT name FROM samples ORDER BY name") }
}

@Test func nameDropsLeadingTrackNumber() async throws {
    let tree = try Tree()
    defer { tree.remove() }
    try tree.add("kick_short.wav", as: "01 - Kick.wav")
    try tree.add("snare_basic.wav", as: "808.wav")
    let database = try LibraryDatabase(inMemory: ())
    _ = try await LibraryScanner(database: database).scan(root: tree.root)

    #expect(try await names(database) == ["808.wav", "Kick.wav"])
}

@Test func nameKeepsNumberWhenSameNameClashesInOneFolder() async throws {
    let tree = try Tree()
    defer { tree.remove() }
    try tree.add("kick_short.wav", as: "01 Kick.wav")
    try tree.add("snare_basic.wav", as: "02 Kick.wav")
    let database = try LibraryDatabase(inMemory: ())
    _ = try await LibraryScanner(database: database).scan(root: tree.root)

    let result = try await names(database)
    #expect(result.count == 2 && result.contains("Kick.wav"))
    #expect(result.contains { $0 == "Kick 01.wav" || $0 == "Kick 02.wav" })
}

@Test func nameDoesNotClashAcrossFolders() async throws {
    let tree = try Tree()
    defer { tree.remove() }
    try tree.add("kick_short.wav", as: "a/01 Kick.wav")
    try tree.add("snare_basic.wav", as: "b/02 Kick.wav")
    let database = try LibraryDatabase(inMemory: ())
    _ = try await LibraryScanner(database: database).scan(root: tree.root)

    #expect(try await names(database) == ["Kick.wav", "Kick.wav"])
}

@Test func nameAppendsPitchLabelWhenSameNameClashes() async throws {
    let tree = try Tree()
    defer { tree.remove() }
    try tree.add("kick_short.wav", as: "01 Kick.wav")
    try tree.add("snare_basic.wav", as: "02 Kick.wav")
    let database = try LibraryDatabase(inMemory: ())
    let scanner = try LibraryScanner(database: database, pitchLabel: { _, _ in "C3" })
    _ = try await scanner.scan(root: tree.root)

    #expect(try await names(database) == ["Kick C3.wav", "Kick.wav"])
}

@Test func nameKeepsDigitsThatAreNotATrackNumber() async throws {
    let tree = try Tree()
    defer { tree.remove() }
    try tree.add("kick_short.wav", as: "3D Pad.wav")
    try tree.add("snare_basic.wav", as: "2.5s Riser.wav")
    let database = try LibraryDatabase(inMemory: ())
    _ = try await LibraryScanner(database: database).scan(root: tree.root)

    #expect(try await names(database) == ["2.5s Riser.wav", "3D Pad.wav"])
}

@Test func renamedFileGetsItsNewName() async throws {
    let tree = try Tree()
    defer { tree.remove() }
    try tree.add("kick_short.wav", as: "01 Kick.wav")
    let database = try LibraryDatabase(inMemory: ())
    let scanner = try LibraryScanner(database: database)
    _ = try await scanner.scan(root: tree.root)
    try tree.move("01 Kick.wav", to: "05 Snare.wav")
    _ = try await scanner.scan(root: tree.root)

    #expect(try await names(database) == ["Snare.wav"])
}
