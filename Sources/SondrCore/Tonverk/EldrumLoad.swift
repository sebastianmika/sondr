import Foundation
import GRDB

/// Opens an eldrum and links each pad back to the library sample it came from.
public enum EldrumLoad {
    public struct Pad: Equatable, Sendable {
        public enum Link: Equatable, Sendable {
            /// Found in the library by content hash; `path` is one of its current paths.
            case linked(sampleID: Int64, path: String, contentHash: String)
            /// The sidecar names a source that the library no longer holds.
            case notInLibrary(originalPath: String, contentHash: String)
            /// No sidecar entry and the WAV matches nothing in the library.
            case unknown
        }

        public var filename: String
        public var link: Link
    }

    public struct Loaded: Equatable, Sendable {
        public var kit: EldrumKit
        /// One entry per pad, nil for an empty pad.
        public var pads: [Pad?]
        /// What to export to write the kit again: the library sample where linked, else the kit's own WAV.
        public var sources: [EldrumExport.Source?]
    }

    /// - Throws: `EldrumError` for a file that is not an eldrum, `EldrumSidecarError` for a too-new sidecar.
    public static func load(eldrum: URL, db: Database) throws -> Loaded {
        let kit = try EldrumKit.parse(String(contentsOf: eldrum, encoding: .utf8))
        let sidecarURL = EldrumSidecar.url(forEldrum: eldrum)
        let sidecar = try FileManager.default.fileExists(atPath: sidecarURL.path)
            ? EldrumSidecar.decode(Data(contentsOf: sidecarURL)) : nil
        let folder = eldrum.deletingLastPathComponent()

        var sources = [EldrumExport.Source?](repeating: nil, count: kit.slots.count)
        let pads = try kit.slots.enumerated().map { pad, filename -> Pad? in
            guard let filename else { return nil }
            let wav = folder.appendingPathComponent(filename)
            // A sidecar entry only counts while it names the WAV the mapping uses; the kit may have been edited by hand.
            if let slot = sidecar?.slots.first(where: { $0.pad == pad && $0.filename == filename }) {
                let found = try sample(db, hash: slot.contentHash)
                let link: Pad.Link =
                    found.map { .linked(sampleID: $0.id, path: $0.path, contentHash: slot.contentHash) }
                    ?? .notInLibrary(originalPath: slot.originalPath, contentHash: slot.contentHash)
                sources[pad] = .init(contentHash: slot.contentHash, path: found?.path ?? wav.path)
                return Pad(filename: filename, link: link)
            }
            // Without a sidecar entry this only matches WAVs that were copied unconverted from the library.
            let hash = try? LibraryScanner.sha256(of: wav)
            let found = try hash.flatMap { try sample(db, hash: $0) }
            if let hash { sources[pad] = .init(contentHash: hash, path: found?.path ?? wav.path) }
            guard let found, let hash else { return Pad(filename: filename, link: .unknown) }
            return Pad(filename: filename, link: .linked(sampleID: found.id, path: found.path, contentHash: hash))
        }
        return Loaded(kit: kit, pads: pads, sources: sources)
    }

    private static func sample(_ db: Database, hash: String) throws -> (id: Int64, path: String)? {
        guard let id = try Int64.fetchOne(db, sql: "SELECT id FROM samples WHERE content_hash = ?", arguments: [hash]) else {
            return nil
        }
        let path = try LibraryInfo.paths(db, sampleID: id).first
        return (id, path ?? "")
    }
}

extension EldrumLoad {
    /// The library sample that has this file path, as an export source. Nil when the path is not in the library.
    public static func source(_ db: Database, path: String) throws -> EldrumExport.Source? {
        try String.fetchOne(
            db,
            sql: "SELECT s.content_hash FROM sample_paths p JOIN samples s ON s.id = p.sample_id WHERE p.path = ?",
            arguments: [path]
        ).map { EldrumExport.Source(contentHash: $0, path: path) }
    }
}
