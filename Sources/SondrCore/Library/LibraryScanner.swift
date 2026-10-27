import AVFoundation
import CryptoKit
import Foundation
import GRDB

public enum ScanError: Error, Equatable, LocalizedError {
    case rootMissing(String)
    case rootEmpty(String)

    public var errorDescription: String? {
        switch self {
        case .rootMissing(let path): return "Folder not found (is the volume mounted?): \(path)"
        case .rootEmpty(let path):
            return "No audio files found, but the library knows files here (is the volume mounted?): \(path)"
        }
    }
}

public struct ScanProgress: Equatable, Sendable {
    /// Audio files found in the folder.
    public var found: Int
    /// Files dealt with so far (skipped, filtered, failed or recorded).
    public var processed: Int
}

public struct ScanFailure: Equatable, Sendable {
    public let path: String
    public let message: String
}

/// What a scan did. Every audio file found falls into exactly one of
/// `new`, `duplicate`, `moved`, `skipped`, `filtered`, `errors`.
public struct ScanSummary: Equatable, Sendable {
    /// Files with content not seen before.
    public var new = 0
    /// Extra paths for content that already exists at another, still present, path.
    public var duplicate = 0
    /// Known content that reappeared at a new path after its old paths were gone.
    public var moved = 0
    /// Unchanged since the last scan (same size and mtime): not read again.
    public var skipped = 0
    /// Excluded by the location's maximum length.
    public var filtered = 0
    /// Unreadable files; details in `failures`.
    public var errors = 0
    /// Samples that lost their last path in this scan and are now flagged missing.
    public var missing = 0
    /// Files whose content was hashed (a check that rescans do not re-read unchanged files).
    public var hashed = 0
    public var failures: [ScanFailure] = []

    public init() {}
}

/// Walks a folder and records its audio files in the library database.
///
/// Files are only read, never written. A sample is identified by the SHA-256 of its bytes; every
/// path with that content is kept in `sample_paths`. Rescans skip files whose size and mtime are
/// unchanged. Paths that vanished are removed, and samples left without a path are flagged
/// `missing` (their tags and embeddings are kept in case the file comes back).
public actor LibraryScanner {
    public static let defaultExtensions: Set<String> = [
        "wav", "wave", "aif", "aiff", "flac", "mp3", "m4a", "aac", "caf",
    ]
    static let batchSize = 500

    private let database: LibraryDatabase
    private let tagger: Tagger
    private let pitchLabel: PitchLabel?

    /// - Parameters:
    ///   - tagger: Source of auto tags; defaults to the bundled aliases and stopwords.
    ///   - pitchLabel: Tells a file's root note for display-name disambiguation, see ``SampleName``.
    public init(database: LibraryDatabase, tagger: Tagger? = nil, pitchLabel: PitchLabel? = nil) throws {
        self.database = database
        self.pitchLabel = pitchLabel
        self.tagger = try tagger ?? Tagger.bundled()
    }

    /// Scans `root` and updates the database.
    ///
    /// - Parameters:
    ///   - root: Folder to walk recursively. Must exist.
    ///   - extensions: Lower-case extensions to include; `nil` means ``defaultExtensions``. Stored on the location.
    ///   - maxLength: Skip files longer than this many seconds; `nil` for no limit. Stored on the location.
    ///   - tagging: Extra tags and blacklist for this location; stored on it. `nil` keeps what is stored.
    ///   - multisampleRules: Which folders may form multisample groups; stored on the location. `nil` keeps what is stored.
    ///   - name: Display name for the location; `nil` keeps the stored name (a new location then shows its folder name).
    ///   - dropRareTagsUpTo: When set, the location's auto tags used by this many samples or fewer, or by under 1% of
    ///     them, are removed after the scan (see ``LibraryTags/dropRare(_:locationID:upTo:keeping:)``). For adding a location.
    ///   - progress: Called after the file walk and after every batch.
    /// - Throws: ``ScanError``, ``JobError/alreadyRunning(_:)``, ``TagRuleError`` or a database error.
    public func scan(
        root: URL, extensions: Set<String>? = nil, maxLength: Double? = nil, tagging: LocationTagging? = nil,
        multisampleRules: MultisampleRules? = nil, dropRareTagsUpTo: Int? = nil, name: String? = nil,
        progress: (@Sendable (ScanProgress) -> Void)? = nil
    ) async throws -> ScanSummary
    {
        try database.jobs.begin(.scan)
        defer { database.jobs.end(.scan) }
        if let tagging { _ = try TagRuleSet(tagging.rules) }

        let root = Self.realURL(root)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw ScanError.rootMissing(root.path) }

        let allowed = extensions ?? Self.defaultExtensions
        let locationID = try await database.writer.write { db -> Int64 in
            try db.execute(
                sql: """
                    INSERT INTO locations (path, name, type_filter, max_length, added_at) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(path) DO UPDATE SET type_filter = excluded.type_filter,
                        max_length = excluded.max_length, name = coalesce(excluded.name, name)
                    """,
                arguments: [
                    root.path, name, extensions.map { $0.sorted().joined(separator: ",") }, maxLength,
                    Date().timeIntervalSince1970,
                ])
            let id = try Int64.fetchOne(db, sql: "SELECT id FROM locations WHERE path = ?", arguments: [root.path])!
            if let tagging { try TaggingStore.save(db, locationID: id, tagging) }
            if let multisampleRules { try MultisampleStore.save(db, locationID: id, multisampleRules) }
            return id
        }
        let computer = try TagComputer(
            tagger: tagger, settings: try await database.writer.read { try TaggingStore.load($0) })

        let found = Self.walk(root: root, extensions: allowed)
        let knownStat = try await database.writer.read { db -> [String: FileStat] in
            var stats: [String: FileStat] = [:]
            let rows = try Row.fetchCursor(
                db, sql: "SELECT path, file_size, file_mtime FROM sample_paths WHERE location_id = ?",
                arguments: [locationID])
            while let row = try rows.next() {
                if let size: Int64 = row["file_size"], let mtime: Double = row["file_mtime"] {
                    stats[row["path"]] = FileStat(size: size, mtime: mtime)
                }
            }
            return stats
        }

        // An unmounted volume can leave an empty folder behind; scanning it would flag everything missing.
        if found.isEmpty, !knownStat.isEmpty { throw ScanError.rootEmpty(root.path) }

        var summary = ScanSummary()
        var toRead: [FoundFile] = []
        for file in found {
            if knownStat[file.path] == file.stat { summary.skipped += 1 } else { toRead.append(file) }
        }

        var handled = summary.skipped
        progress?(ScanProgress(found: found.count, processed: handled))
        var batch: [Candidate] = []
        for try await outcome in Self.read(toRead, maxLength: maxLength) {
            handled += 1
            if handled % 100 == 0 { progress?(ScanProgress(found: found.count, processed: handled)) }
            switch outcome {
            case .candidate(let candidate):
                summary.hashed += 1
                batch.append(candidate)
                if batch.count >= Self.batchSize {
                    try await flush(&batch, root: root, locationID: locationID, computer: computer, into: &summary)
                }
            case .filtered: summary.filtered += 1
            case .failed(let failure):
                summary.errors += 1
                summary.failures.append(failure)
            }
        }
        try await flush(&batch, root: root, locationID: locationID, computer: computer, into: &summary)
        progress?(ScanProgress(found: found.count, processed: found.count))

        let seen = Set(found.map(\.path))
        summary.missing = try await database.writer.write { db in
            try Self.removeVanishedPaths(db, locationID: locationID, seen: seen)
        }
        if let dropRareTagsUpTo {
            let keeping = TaggingStore.normalised(tagging?.extraTags ?? [])
            _ = try await database.writer.write {
                try LibraryTags.dropRare($0, locationID: locationID, upTo: dropRareTagsUpTo, keeping: keeping)
            }
        }
        summary.failures.sort { $0.path < $1.path }
        return summary
    }

    // MARK: Walking and reading files (no database)

    /// `realpath` of `url`. Unlike `resolvingSymlinksInPath`, it keeps `/private/var`, which is
    /// what `FileManager.enumerator` reports for files under `/var`.
    static func realURL(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    struct FileStat: Equatable, Sendable {
        let size: Int64
        let mtime: Double
    }

    struct FoundFile: Sendable {
        let path: String
        let stat: FileStat
    }

    struct Candidate: Sendable {
        let file: FoundFile
        let hash: String
        let duration: Double
        let sampleRate: Double
        let channels: Int
    }

    enum Outcome: Sendable {
        case candidate(Candidate)
        case filtered
        case failed(ScanFailure)
    }

    static func walk(root: URL, extensions: Set<String>) -> [FoundFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var files: [FoundFile] = []
        for case let url as URL in enumerator {
            guard extensions.contains(url.pathExtension.lowercased()),
                let values = try? url.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true, let size = values.fileSize,
                let modified = values.contentModificationDate
            else { continue }
            files.append(
                FoundFile(
                    path: url.path,
                    stat: FileStat(size: Int64(size), mtime: modified.timeIntervalSince1970)))
        }
        files.sort { $0.path < $1.path }
        return files
    }

    /// Reads metadata and hashes files on all cores, a bounded number at a time.
    private static func read(_ files: [FoundFile], maxLength: Double?) -> AsyncThrowingStream<Outcome, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await withTaskGroup(of: Outcome.self) { group in
                    var iterator = files.makeIterator()
                    for _ in 0..<ProcessInfo.processInfo.activeProcessorCount {
                        guard let file = iterator.next() else { break }
                        group.addTask { inspect(file, maxLength: maxLength) }
                    }
                    while let outcome = await group.next() {
                        continuation.yield(outcome)
                        if Task.isCancelled { group.cancelAll(); continue }
                        if let file = iterator.next() {
                            group.addTask { inspect(file, maxLength: maxLength) }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Opens the file for its metadata first (cheap, and rejects corrupt files and over-long ones
    /// before reading all the bytes), then hashes it.
    private static func inspect(_ file: FoundFile, maxLength: Double?) -> Outcome {
        let url = URL(fileURLWithPath: file.path)
        let duration: Double
        let format: AVAudioFormat
        do {
            let audio = try AVAudioFile(forReading: url)
            format = audio.processingFormat
            guard format.sampleRate > 0, audio.length > 0 else {
                return .failed(ScanFailure(path: file.path, message: "no audio frames"))
            }
            duration = Double(audio.length) / format.sampleRate
        } catch {
            return .failed(ScanFailure(path: file.path, message: error.localizedDescription))
        }
        if let maxLength, duration > maxLength { return .filtered }
        do {
            return .candidate(
                Candidate(
                    file: file, hash: try sha256(of: url), duration: duration,
                    sampleRate: format.sampleRate, channels: Int(format.channelCount)))
        } catch {
            return .failed(ScanFailure(path: file.path, message: error.localizedDescription))
        }
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Database updates

    private func flush(
        _ batch: inout [Candidate], root: URL, locationID: Int64, computer: TagComputer,
        into summary: inout ScanSummary
    ) async throws {
        guard !batch.isEmpty else { return }
        // shortcut: sorted per batch only, so a name clash split across two batches (>500 files) can still resolve either way; upgrade by sorting the walk before reading.
        let candidates = batch.sorted { $0.file.path < $1.file.path }
        batch.removeAll(keepingCapacity: true)
        let pitchLabel = pitchLabel
        let counts = try await database.writer.write { db in
            var counts = ScanSummary()
            let now = Date().timeIntervalSince1970
            for candidate in candidates {
                switch try Self.record(db, candidate, root: root, locationID: locationID, now: now, computer: computer, pitchLabel: pitchLabel) {
                case .new: counts.new += 1
                case .duplicate: counts.duplicate += 1
                case .moved: counts.moved += 1
                case .unchanged: counts.skipped += 1
                }
            }
            return counts
        }
        summary.new += counts.new
        summary.duplicate += counts.duplicate
        summary.moved += counts.moved
        summary.skipped += counts.skipped
    }

    private enum Recorded { case new, duplicate, moved, unchanged }

    private static func record(
        _ db: Database, _ candidate: Candidate, root: URL, locationID: Int64, now: Double, computer: TagComputer,
        pitchLabel: PitchLabel?
    ) throws -> Recorded {
        let file = candidate.file
        let existingPath = try Row.fetchOne(
            db, sql: "SELECT id, sample_id FROM sample_paths WHERE path = ?", arguments: [file.path])
        let existingSample = try Int64.fetchOne(
            db, sql: "SELECT id FROM samples WHERE content_hash = ?", arguments: [candidate.hash])

        if let existingPath {
            let pathID: Int64 = existingPath["id"]
            let oldSample: Int64 = existingPath["sample_id"]
            if oldSample == existingSample {
                try db.execute(
                    sql: "UPDATE sample_paths SET file_size = ?, file_mtime = ? WHERE id = ?",
                    arguments: [file.stat.size, file.stat.mtime, pathID])
                return .unchanged
            }
            // The file's content changed: it is a different sample now.
            try db.execute(sql: "DELETE FROM sample_paths WHERE id = ?", arguments: [pathID])
            try db.execute(
                sql: "DELETE FROM samples WHERE id = ? AND NOT EXISTS (SELECT 1 FROM sample_paths WHERE sample_id = ?)",
                arguments: [oldSample, oldSample])
        }

        let relative = String(file.path.dropFirst(root.path.count)).trimmingPrefix("/")
        let filename = (file.path as NSString).lastPathComponent
        let format = (filename as NSString).pathExtension.lowercased()

        let sampleID: Int64
        let result: Recorded
        if let existingSample {
            sampleID = existingSample
            let alive = try String.fetchAll(
                db, sql: "SELECT path FROM sample_paths WHERE sample_id = ?", arguments: [sampleID]
            ).contains { FileManager.default.fileExists(atPath: $0) }
            if alive {
                result = .duplicate
            } else {
                result = .moved
                try db.execute(
                    sql: "UPDATE samples SET canonical_path = ?, filename = ?, rel_path = ? WHERE id = ?",
                    arguments: [file.path, filename, String(relative), sampleID])
                try db.execute(
                    sql: "UPDATE samples SET name = ? WHERE id = ?",
                    arguments: [try SampleName.display(db, path: file.path, excluding: sampleID, pitchLabel: pitchLabel), sampleID])
            }
            try db.execute(sql: "UPDATE samples SET missing = 0 WHERE id = ?", arguments: [sampleID])
        } else {
            try db.execute(
                sql: """
                    INSERT INTO samples (content_hash, canonical_path, filename, name, rel_path, duration,
                        sample_rate, channels, format, file_size, file_mtime, scanned_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    candidate.hash, file.path, filename, try SampleName.display(db, path: file.path, pitchLabel: pitchLabel), String(relative),
                    candidate.duration,
                    candidate.sampleRate, candidate.channels, format, file.stat.size, file.stat.mtime, now,
                ])
            sampleID = db.lastInsertedRowID
            result = .new
        }
        try db.execute(
            sql: "INSERT INTO sample_paths (sample_id, path, location_id, file_size, file_mtime) VALUES (?, ?, ?, ?, ?)",
            arguments: [sampleID, file.path, locationID, file.stat.size, file.stat.mtime])
        // Tags come from the location's folder name plus the path below it, not the absolute path
        // ("Users", "Music" would become tags), then the location's rules and extra tags.
        try LibraryTags.applyAuto(
            db, sampleID: sampleID,
            tags: computer.tags(locationID: locationID, rootPath: root.path, path: file.path))
        return result
    }

    /// Deletes path rows of this location whose file is gone, repairs `canonical_path`, and flags
    /// samples without any path as missing. Returns how many samples were newly flagged.
    private static func removeVanishedPaths(_ db: Database, locationID: Int64, seen: Set<String>) throws -> Int {
        let rows = try Row.fetchAll(
            db, sql: "SELECT id, sample_id, path FROM sample_paths WHERE location_id = ?", arguments: [locationID])
        for row in rows {
            let path: String = row["path"]
            guard !seen.contains(path), !FileManager.default.fileExists(atPath: path) else { continue }
            let sampleID: Int64 = row["sample_id"]
            try db.execute(sql: "DELETE FROM sample_paths WHERE id = ?", arguments: [row["id"] as Int64])
            try db.execute(
                sql: """
                    UPDATE samples SET canonical_path = COALESCE(
                        (SELECT path FROM sample_paths WHERE sample_id = samples.id ORDER BY id LIMIT 1),
                        canonical_path)
                    WHERE id = ? AND canonical_path = ?
                    """, arguments: [sampleID, path])
        }
        try db.execute(
            sql: """
                UPDATE samples SET missing = 1
                WHERE missing = 0 AND NOT EXISTS (SELECT 1 FROM sample_paths WHERE sample_id = samples.id)
                """)
        return db.changesCount
    }
}
