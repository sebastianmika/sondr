import Foundation

/// The settings of the library's locations as a JSON file, enough to add them again on another library or machine.
public struct LocationExport: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var path: String
        public var name: String
        public var typeFilter: String?
        public var maxLength: Double?
        public var tagging: LocationTagging
        public var multisampleRules: MultisampleRules
    }

    public static let currentVersion = 1

    public var version = LocationExport.currentVersion
    public var locations: [Entry]

    public init(locations: [LocationInfo]) {
        self.locations = locations.map {
            Entry(
                path: $0.path, name: $0.name, typeFilter: $0.typeFilter, maxLength: $0.maxLength, tagging: $0.tagging,
                multisampleRules: $0.multisampleRules)
        }
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> LocationExport {
        let export = try JSONDecoder().decode(LocationExport.self, from: data)
        guard export.version <= currentVersion else { throw LocationExportError.newerVersion(export.version) }
        return export
    }
}

public enum LocationExportError: Error, LocalizedError {
    case newerVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .newerVersion(let version): return "This file was written by a newer Sondr (format \(version))."
        }
    }
}
