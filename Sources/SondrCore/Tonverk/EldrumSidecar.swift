import Foundation

/// Which library sample went into which pad of an eldrum, stored next to the kit as `<kit>.sondr.json`.
public struct EldrumSidecar: Codable, Equatable, Sendable {
    public struct Slot: Codable, Equatable, Sendable {
        /// Pad index in `EldrumKit.pitches` order.
        public var pad: Int
        public var contentHash: String
        public var originalPath: String
        /// The WAV written into the kit folder.
        public var filename: String
    }

    public static let currentVersion = 1

    public var version = EldrumSidecar.currentVersion
    public var slots: [Slot]

    public init(slots: [Slot]) {
        self.slots = slots
    }

    /// The sidecar's file URL for an eldrum file, e.g. `Kit/Kit.eldrum` gives `Kit/Kit.sondr.json`.
    public static func url(forEldrum eldrum: URL) -> URL {
        eldrum.deletingPathExtension().appendingPathExtension("sondr.json")
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> EldrumSidecar {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let sidecar = try decoder.decode(EldrumSidecar.self, from: data)
        guard sidecar.version <= currentVersion else { throw EldrumSidecarError.newerVersion(sidecar.version) }
        return sidecar
    }
}

public enum EldrumSidecarError: Error, LocalizedError, Equatable {
    case newerVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .newerVersion(let version): return "This file was written by a newer Sondr (format \(version))."
        }
    }
}
