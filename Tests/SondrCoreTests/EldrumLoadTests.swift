import Foundation
import GRDB
import Testing

@testable import SondrCore

@Suite struct EldrumLoadTests {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eldrumload-\(UUID().uuidString)")

    private func library(hashes: [String: String]) throws -> LibraryDatabase {
        let database = try LibraryDatabase(inMemory: ())
        try database.writer.write { db in
            try db.execute(sql: "INSERT INTO locations (id, path, added_at) VALUES (1, '/lib', 0)")
            for (hash, path) in hashes {
                try db.execute(
                    sql: """
                        INSERT INTO samples (content_hash, canonical_path, filename, rel_path, duration, sample_rate,
                            channels, format, file_size, file_mtime, scanned_at)
                        VALUES (?, ?, 'f.wav', 'f.wav', 1, 48000, 1, 'wav', 1, 0, 0)
                        """, arguments: [hash, path])
                try db.execute(
                    sql: "INSERT INTO sample_paths (sample_id, path, location_id) VALUES (?, ?, 1)",
                    arguments: [db.lastInsertedRowID, path])
            }
        }
        return database
    }

    private func writeKit(sidecar: EldrumSidecar?, files: [String: String] = [:]) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var kit = EldrumKit(name: "K")
        kit.slots[0] = "a.wav"
        kit.slots[1] = "b.wav"
        let eldrum = dir.appendingPathComponent("K.eldrum")
        try kit.render().write(to: eldrum, atomically: true, encoding: .utf8)
        if let sidecar { try sidecar.json().write(to: EldrumSidecar.url(forEldrum: eldrum)) }
        for (name, content) in files { try Data(content.utf8).write(to: dir.appendingPathComponent(name)) }
        return eldrum
    }

    @Test func sidecarLinksByHashAndReportsMissingSources() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let database = try library(hashes: ["h1": "/lib/moved/kick.aif"])
        let sidecar = EldrumSidecar(slots: [
            .init(pad: 0, contentHash: "h1", originalPath: "/lib/kick.aif", filename: "a.wav"),
            .init(pad: 1, contentHash: "gone", originalPath: "/old/snare.aif", filename: "b.wav"),
        ])
        let eldrum = try writeKit(sidecar: sidecar)
        let loaded = try database.writer.read { try EldrumLoad.load(eldrum: eldrum, db: $0) }
        #expect(loaded.pads[0]?.link == .linked(sampleID: 1, path: "/lib/moved/kick.aif"))
        #expect(loaded.pads[1]?.link == .notInLibrary(originalPath: "/old/snare.aif"))
        #expect(loaded.pads[2] == nil)
    }

    @Test func withoutSidecarMatchesUnconvertedCopiesByFileHash() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let eldrum = try writeKit(sidecar: nil, files: ["a.wav": "same", "b.wav": "other"])
        let hash = try LibraryScanner.sha256(of: dir.appendingPathComponent("a.wav"))
        let database = try library(hashes: [hash: "/lib/a.wav"])
        let loaded = try database.writer.read { try EldrumLoad.load(eldrum: eldrum, db: $0) }
        #expect(loaded.pads[0]?.link == .linked(sampleID: 1, path: "/lib/a.wav"))
        #expect(loaded.pads[1]?.link == .unknown)
    }

    @Test func sidecarEntryForAnotherFilenameIsIgnored() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let database = try library(hashes: ["h1": "/lib/k.aif"])
        let sidecar = EldrumSidecar(slots: [.init(pad: 0, contentHash: "h1", originalPath: "/lib/k.aif", filename: "renamed.wav")])
        let eldrum = try writeKit(sidecar: sidecar)
        let loaded = try database.writer.read { try EldrumLoad.load(eldrum: eldrum, db: $0) }
        #expect(loaded.pads[0]?.link == .unknown)
    }
}
