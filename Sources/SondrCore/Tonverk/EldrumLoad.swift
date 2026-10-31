import Foundation
import GRDB

/// Opens an eldrum and links each pad back to the library sample it came from.
public enum EldrumLoad {
    public struct Pad: Equatable, Sendable {
        public enum Link: Equatable, Sendable {
            /// Found in the library by content hash; `path` is one of its current paths.
            case linked(sampleID: Int64, path: String)
            /// The sidecar names a source that the library no longer holds.
            case notInLibrary(originalPath: String)
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
    }

    /// - Throws: `EldrumError` for a file that is not an eldrum, `EldrumSidecarError` for a too-new sidecar.
    public static func load(eldrum: URL, db: Database) throws -> Loaded {
        let kit = try EldrumKit.parse(String(contentsOf: eldrum, encoding: .utf8))
        let sidecarURL = EldrumSidecar.url(forEldrum: eldrum)
        let sidecar = try FileManager.default.fileExists(atPath: sidecarURL.path)
            ? EldrumSidecar.decode(Data(contentsOf: sidecarURL)) : nil
        let folder = eldrum.deletingLastPathComponent()

        let pads = try kit.slots.enumerated().map { pad, filename -> Pad? in
            guard let filename else { return nil }
            // A sidecar entry only counts while it names the WAV the mapping uses; the kit may have been edited by hand.
            if let slot = sidecar?.slots.first(where: { $0.pad == pad && $0.filename == filename }) {
                let found = try sample(db, hash: slot.contentHash)
                let link: Pad.Link =
                    found.map { .linked(sampleID: $0.id, path: $0.path) } ?? .notInLibrary(originalPath: slot.originalPath)
                return Pad(filename: filename, link: link)
            }
            // Without a sidecar entry this only matches WAVs that were copied unconverted from the library.
            let hash = try? LibraryScanner.sha256(of: folder.appendingPathComponent(filename))
            let found = try hash.flatMap { try sample(db, hash: $0) }
            return Pad(filename: filename, link: found.map { .linked(sampleID: $0.id, path: $0.path) } ?? .unknown)
        }
        return Loaded(kit: kit, pads: pads)
    }

    private static func sample(_ db: Database, hash: String) throws -> (id: Int64, path: String)? {
        guard let id = try Int64.fetchOne(db, sql: "SELECT id FROM samples WHERE content_hash = ?", arguments: [hash]) else {
            return nil
        }
        let path = try LibraryInfo.paths(db, sampleID: id).first
        return (id, path ?? "")
    }
}
