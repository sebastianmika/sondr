import Foundation
import Observation

/// The Tonverk drum kit being built: eight pads filled from library samples, exported or loaded through the
/// eldrum services. Failures go to ``AppModel/message``.
@MainActor
@Observable
public final class EldrumKitModel {
    public struct Pad: Equatable, Sendable {
        public var source: EldrumExport.Source
        public var title: String
        public var note: String?
        /// The library sample behind the pad, nil when the library does not know it.
        public var sampleID: Int64?
    }

    public var name = "My Kit" {
        didSet { if name.count > EldrumKit.maxNameLength { name = String(name.prefix(EldrumKit.maxNameLength)) } }
    }
    public private(set) var pads = [Pad?](repeating: nil, count: EldrumKit.pitches.count)
    /// True when the opened kit had layers or round robin that exporting would drop.
    public private(set) var lossy = false

    private let app: AppModel

    public init(app: AppModel) {
        self.app = app
    }

    public var canExport: Bool { !name.isEmpty && pads.contains { $0 != nil } }

    public func clear(pad: Int) {
        pads[pad] = nil
    }

    /// Puts the library sample with this file path on the pad; a path the library does not hold is reported.
    public func assign(path: String, to pad: Int) async {
        do {
            let found = try await app.database?.writer.read { db -> (EldrumExport.Source, Int64?)? in
                guard let source = try EldrumLoad.source(db, path: path) else { return nil }
                return (source, try EldrumLoad.sampleID(db, hash: source.contentHash))
            }
            guard let (source, sampleID) = found else {
                app.message = "\(URL(fileURLWithPath: path).lastPathComponent) is not in the library. Add its folder as a location first."
                return
            }
            pads[pad] = Pad(source: source, title: URL(fileURLWithPath: path).lastPathComponent, sampleID: sampleID)
        } catch { app.message = error.localizedDescription }
    }

    public func open(_ eldrum: URL) async {
        do {
            guard let loaded = try await app.database?.writer.read({ try EldrumLoad.load(eldrum: eldrum, db: $0) }) else { return }
            name = loaded.kit.name
            lossy = loaded.kit.lossy
            pads = zip(loaded.pads, loaded.sources).map { pad, source in
                guard let pad, let source else { return nil }
                switch pad.link {
                case .linked(let sampleID, let path, _):
                    return Pad(source: source, title: URL(fileURLWithPath: path).lastPathComponent, sampleID: sampleID)
                case .notInLibrary(let originalPath, _):
                    let was = URL(fileURLWithPath: originalPath).lastPathComponent
                    return Pad(source: source, title: pad.filename, note: "Not in library (was \(was))")
                case .unknown:
                    return Pad(source: source, title: pad.filename, note: "Origin unknown")
                }
            }
        } catch { app.message = error.localizedDescription }
    }

    /// Writes the kit folder into `parent`, which must be outside the library locations.
    public func export(into parent: URL) async {
        if app.locations.contains(where: { parent.path.hasPrefix($0.path) }) {
            app.message = "Pick a folder outside your library locations."
            return
        }
        let name = name
        let sources = pads.map { $0?.source }
        do {
            let eldrum = try await Task.detached { try EldrumExport.write(name: name, sources: sources, into: parent) }.value
            app.message = "Exported \(eldrum.deletingLastPathComponent().path)"
        } catch { app.message = error.localizedDescription }
    }
}
