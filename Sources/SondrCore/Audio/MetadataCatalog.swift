import Foundation

/// Which metadata fields are shown with a readable name (the main list) and which are left in the
/// extended list.
///
/// ``standard`` is hardcoded from a scan of 54,248 audio files (`~/Desktop/Synth/Samples`, 2026-10-24):
/// a field is main if it appears in at least 1% of them and has a meaning we can name. Vendor chunks
/// that are frequent but opaque (`riff.chunk.AFAn`, `LGWV`, `minf`, `umid`, `elm1`, `DGDA`) stay in the
/// extended list, because a name for them would be a guess. Build a ``MetadataCatalog`` from other
/// fields to make the list configurable.
public struct MetadataCatalog: Equatable, Sendable {
    public struct Field: Equatable, Sendable {
        public let key: String
        public let name: String
    }

    /// Main fields in display order.
    public let main: [Field]

    public init(main: [Field]) {
        self.main = main
    }

    /// Splits `items` into readable main lines (in catalog order) and the remaining extended items.
    public func split(_ items: [MetadataItem]) -> (main: [(name: String, value: String)], extended: [MetadataItem]) {
        let names = Dictionary(main.map { ($0.key, $0.name) }, uniquingKeysWith: { first, _ in first })
        let shown = main.flatMap { field in items.filter { $0.key == field.key }.map { (name: field.name, value: $0.value) } }
        return (shown, items.filter { names[$0.key] == nil })
    }

    public static let standard = MetadataCatalog(
        main: [
            ("file.codec", "Codec"),
            ("file.bitDepth", "Bit depth"),
            ("avf.caaf/info-approximate%20duration%20in%20seconds", "Approx. duration (s)"),
            ("file.size", "File size"),
            ("file.modified", "Modified"),
            ("riff.smpl.rootNote", "Root note (smpl)"),
            ("riff.smpl.fineTune", "Fine tune (smpl)"),
            ("riff.smpl.loops", "Loops"),
            ("riff.smpl.loop1", "First loop"),
            ("riff.inst.rootNote", "Root note (inst)"),
            ("riff.inst.fineTune", "Fine tune (inst)"),
            ("riff.inst.gain", "Gain"),
            ("riff.inst.noteRange", "Key range"),
            ("riff.inst.velocityRange", "Velocity range"),
            ("riff.bext.originator", "Originator"),
            ("riff.bext.originatorReference", "Originator reference"),
            ("riff.bext.originationDate", "Origination date"),
            ("riff.bext.originationTime", "Origination time"),
            ("riff.bext.timeReference", "Time reference"),
            ("riff.cue.count", "Cue points"),
            ("riff.adtl.labels", "Marker labels"),
        ].map { Field(key: $0.0, name: $0.1) })
}
