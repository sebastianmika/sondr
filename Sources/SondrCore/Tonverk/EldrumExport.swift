import Foundation

/// Writes an eldrum kit folder: the mapping, one WAV per pad and the sidecar naming the source samples.
public enum EldrumExport {
    public struct Source: Equatable, Sendable {
        public var contentHash: String
        public var path: String

        public init(contentHash: String, path: String) {
            self.contentHash = contentHash
            self.path = path
        }
    }

    /// Creates `<parent>/<name>/` with `<name>.eldrum`, `<name>.sondr.json` and the pad WAVs. Returns the eldrum URL.
    ///
    /// - Parameters:
    ///   - sources: One optional source per pad, in `EldrumKit.pitches` order.
    ///   - comment: Whether to add a `#` line pointing at the sidecar (untested on the device, see the plan).
    /// - Throws: `EldrumExportError.exists` rather than overwrite a folder; the folder is removed again on failure.
    @discardableResult
    public static func write(name: String, sources: [Source?], into parent: URL, comment: Bool = true) throws -> URL {
        let folder = parent.appendingPathComponent(fileSafe(name), isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folder.path) else { throw EldrumExportError.exists(folder) }

        var kit = EldrumKit(name: name)
        var slots: [EldrumSidecar.Slot] = []
        for (pad, source) in sources.enumerated() {
            guard let source else { continue }
            let filename = "\(pad + 1)_\(fileSafe(URL(fileURLWithPath: source.path).deletingPathExtension().lastPathComponent)).wav"
            kit.slots[pad] = filename
            slots.append(.init(pad: pad, contentHash: source.contentHash, originalPath: source.path, filename: filename))
        }
        let mapping = try kit.render(comment: comment ? "sondr: sources in \(fileSafe(name)).sondr.json" : nil)

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            for slot in slots {
                try TonverkWav.prepare(source: URL(fileURLWithPath: slot.originalPath), destination: folder.appendingPathComponent(slot.filename))
            }
            let eldrum = folder.appendingPathComponent("\(fileSafe(name)).eldrum")
            try mapping.write(to: eldrum, atomically: true, encoding: .utf8)
            try EldrumSidecar(slots: slots).json().write(to: EldrumSidecar.url(forEldrum: eldrum), options: .atomic)
            return eldrum
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// ASCII letters, digits, space, `_`, `-` and `.` only, as the factory library uses.
    static func fileSafe(_ text: String) -> String {
        String(text.map { $0.isASCII && ($0.isLetter || $0.isNumber || " _-.".contains($0)) ? $0 : "_" })
    }
}

public enum EldrumExportError: Error, LocalizedError {
    case exists(URL)

    public var errorDescription: String? {
        switch self {
        case .exists(let url): return "\(url.lastPathComponent) already exists in that folder."
        }
    }
}
