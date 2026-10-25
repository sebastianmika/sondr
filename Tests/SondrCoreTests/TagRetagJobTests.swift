import Foundation
import GRDB
import Testing

@testable import SondrCore

/// `count` samples in location 1, one path each.
private func makeLibrary(count: Int = 6) throws -> LibraryDatabase {
    let database = try LibraryDatabase(inMemory: ())
    try database.writer.write { db in
        try db.execute(sql: "INSERT INTO locations (id, path, added_at) VALUES (1, '/lib/Drums', 0)")
        for id in 1...count {
            try db.execute(
                sql: """
                    INSERT INTO samples (id, content_hash, canonical_path, filename, rel_path, duration,
                        sample_rate, channels, format, file_size, file_mtime, scanned_at)
                    VALUES (?, ?, '/lib/Drums/Kicks/hard_kick.wav', 'x.wav', 'x.wav', 1, 48000, 1, 'wav', 1, 0, 0)
                    """, arguments: [id, "h\(id)"])
            try db.execute(
                sql: "INSERT INTO sample_paths (sample_id, path, location_id) VALUES (?, ?, 1)",
                arguments: [id, "/lib/Drums/Kicks/hard_kick_\(id).wav"])
        }
    }
    return database
}

private func tagAll(_ database: LibraryDatabase, _ settings: TaggingSettings) throws {
    let computer = try TagComputer(tagger: Tagger.bundled(), settings: settings)
    try database.writer.write { db in
        for id in try Int64.fetchAll(db, sql: "SELECT id FROM samples") {
            try LibraryTags.applyAuto(db, sampleID: id, tags: TagRetag.tags(db, sampleID: id, computer: computer))
        }
    }
}

private func names(_ database: LibraryDatabase, _ id: Int64) throws -> [String] {
    try database.writer.read { try LibraryTags.names($0, sampleID: id) }
}

private let withExtra = TaggingSettings(locations: [1: LocationTagging(extraTags: ["live"])])

@Test func commitSavesTheNewSettingsAndTheJobAppliesThem() async throws {
    let database = try makeLibrary()
    try tagAll(database, TaggingSettings(locations: [1: LocationTagging()]))
    let old = try await database.writer.read { try TaggingStore.load($0) }
    try await database.writer.write { try TagRetagJob.commit($0, old: old, new: withExtra) }
    #expect(try await database.writer.read { try TagRetagJob.hasPending($0) })
    #expect(try await database.writer.read { try TaggingStore.load($0) } == withExtra)

    let run = try TagRetagJob.start(database: database, tagger: Tagger.bundled(), chunkSize: 2)
    let summary = try await run.result()
    #expect(summary == RetagSummary(samples: 6, cancelled: false))
    #expect(try (1...6).allSatisfy { try names(database, Int64($0)).contains("live") })
    #expect(try await database.writer.read { try !TagRetagJob.hasPending($0) })
}

@Test func anInterruptedRetagFinishesWhenStartedAgain() async throws {
    let database = try makeLibrary(count: 300)
    try tagAll(database, TaggingSettings(locations: [1: LocationTagging()]))
    let old = try await database.writer.read { try TaggingStore.load($0) }
    try await database.writer.write { try TagRetagJob.commit($0, old: old, new: withExtra) }

    let first = try TagRetagJob.start(database: database, tagger: Tagger.bundled(), chunkSize: 1)
    for await progress in first.progress where progress.done >= 1 { first.cancel() }
    let partial = try await first.result()
    #expect(partial.cancelled && partial.samples < 300)
    #expect(try await database.writer.read { try TagRetagJob.hasPending($0) })

    let second = try TagRetagJob.start(database: database, tagger: Tagger.bundled(), chunkSize: 1)
    #expect(try await second.result().cancelled == false)
    #expect(try (1...300).allSatisfy { try names(database, Int64($0)).contains("live") })
    #expect(try await database.writer.read { try !TagRetagJob.hasPending($0) })
}

@Test func nothingPendingMeansNothingToDo() async throws {
    let database = try makeLibrary()
    let run = try TagRetagJob.start(database: database, tagger: Tagger.bundled())
    #expect(try await run.result() == RetagSummary(samples: 0, cancelled: false))
}

@Test func aSecondChangeCannotBeCommittedWhileOneIsPending() async throws {
    let database = try makeLibrary()
    try await database.writer.write { try TagRetagJob.commit($0, old: TaggingSettings(), new: withExtra) }
    #expect(throws: TagRetagError.pending) {
        try database.writer.write { try TagRetagJob.commit($0, old: withExtra, new: TaggingSettings()) }
    }
}

@Test func invalidRulesAreRejectedAndNothingIsSaved() async throws {
    let database = try makeLibrary()
    let bad = TaggingSettings(global: [TagRule(kind: .regex, pattern: "(")])
    #expect(throws: TagRuleError.self) {
        try database.writer.write { try TagRetagJob.commit($0, old: TaggingSettings(), new: bad) }
    }
    #expect(try await database.writer.read { try !TagRetagJob.hasPending($0) })
}

@Test func retagAndScanExcludeEachOther() throws {
    let database = try makeLibrary()
    try database.jobs.begin(.scan)
    #expect(throws: JobError.self) { try TagRetagJob.start(database: database, tagger: Tagger.bundled()) }
    #expect(!database.jobs.isRunning(.retag))
    database.jobs.end(.scan)
    _ = try TagRetagJob.start(database: database, tagger: Tagger.bundled())
}

@Test func removingALocationRecomputesTagsOfSamplesThatSurvive() throws {
    let database = try LibraryDatabase(inMemory: ())
    try database.writer.write { db in
        for (id, path) in [(1, "/lib/A"), (2, "/lib/B")] {
            try db.execute(sql: "INSERT INTO locations (id, path, added_at) VALUES (?, ?, 0)", arguments: [id, path])
        }
        try db.execute(
            sql: """
                INSERT INTO samples (id, content_hash, canonical_path, filename, rel_path, duration,
                    sample_rate, channels, format, file_size, file_mtime, scanned_at)
                VALUES (1, 'h', '/lib/A/kick.wav', 'x.wav', 'x.wav', 1, 48000, 1, 'wav', 1, 0, 0)
                """)
        for (path, location) in [("/lib/A/kick.wav", 1), ("/lib/B/kick.wav", 2)] {
            try db.execute(
                sql: "INSERT INTO sample_paths (sample_id, path, location_id) VALUES (1, ?, ?)", arguments: [path, location])
        }
        try TaggingStore.save(db, locationID: 1, LocationTagging(extraTags: ["from-a"]))
        try TaggingStore.save(db, locationID: 2, LocationTagging(extraTags: ["from-b"]))
    }
    try tagAll(database, database.writer.read { try TaggingStore.load($0) })
    #expect(try names(database, 1).contains("from-a") && names(database, 1).contains("from-b"))

    _ = try database.writer.write { try LibraryInfo.removeLocation($0, id: 1) }
    let after = try names(database, 1)
    #expect(!after.contains("from-a"))
    #expect(after.contains("from-b") && after.contains("kick"))
}
