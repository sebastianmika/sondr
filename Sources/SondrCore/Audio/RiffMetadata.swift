import Foundation

/// Metadata in the header chunks of a WAV file, which AVFoundation does not report: sampler
/// settings (`smpl`, `inst`), broadcast info (`bext`), markers (`cue `, `LIST/adtl`) and `LIST/INFO` tags.
///
/// Keys look like `riff.smpl.rootNote`. Chunks that carry data this reader does not decode (vendor
/// blobs such as `AFAn` or `LGWV`) come back as `riff.chunk.<id>` with their size, so the full list of
/// what a file holds is visible. Reads headers only, never the audio.
enum RiffMetadata {
    private static let maxChunks = 256
    /// Chunks that only structure or pad the file.
    private static let structural: Set<String> = ["fmt ", "data", "RIFF", "JUNK", "FLLR", "PAD ", "fact"]
    /// Largest chunk body that is read into memory.
    private static let maxBody = 1 << 16

    static func read(from url: URL) -> [MetadataItem] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 12), header.count == 12,
            header.prefix(4) == Data("RIFF".utf8), header[8..<12] == Data("WAVE".utf8)
        else { return [] }
        var items: [MetadataItem] = []
        for _ in 0..<maxChunks {
            guard let head = try? handle.read(upToCount: 8), head.count == 8, let start = try? handle.offset() else { break }
            // A chunk id is four printable ASCII bytes; anything else means the walk lost its place.
            guard head.prefix(4).allSatisfy({ (0x20...0x7E).contains($0) }) else { break }
            let id = String(decoding: head.prefix(4), as: UTF8.self)
            let size = Int(le32(head, 4))
            let body = structural.contains(id) || id == "data" ? nil : (try? handle.read(upToCount: min(size, maxBody)))
            items += decode(id: id, size: size, body: body ?? Data())
            guard (try? handle.seek(toOffset: start + UInt64(size + size % 2))) != nil else { break }
        }
        return items
    }

    private static func decode(id: String, size: Int, body: Data) -> [MetadataItem] {
        switch id {
        case "smpl": return smpl(body)
        case "inst": return inst(body)
        case "bext": return bext(body)
        case "cue ": return body.count >= 4 ? [item("cue.count", "\(le32(body, 0))")] : []
        case "LIST": return list(body)
        default:
            return structural.contains(id) ? [] : [item("chunk.\(id.trimmingCharacters(in: .whitespaces))", "\(size) bytes")]
        }
    }

    private static func smpl(_ b: Data) -> [MetadataItem] {
        guard b.count >= 36 else { return [] }
        var items: [MetadataItem] = []
        let note = Int(le32(b, 12))
        items.append(item("smpl.rootNote", noteText(note)))
        items.append(item("smpl.fineTune", "\(Int((Double(le32(b, 16)) / 4_294_967_296 * 100).rounded())) cents"))
        let loops = Int(le32(b, 28))
        items.append(item("smpl.loops", "\(loops)"))
        if loops > 0, b.count >= 36 + 24 {
            items.append(item("smpl.loop1", "\(le32(b, 44)) – \(le32(b, 48)) frames"))
        }
        return items
    }

    private static func inst(_ b: Data) -> [MetadataItem] {
        guard b.count >= 7 else { return [] }
        let at = { (i: Int) in b[b.startIndex + i] }
        return [
            item("inst.rootNote", noteText(Int(at(0)))),
            item("inst.fineTune", "\(Int(Int8(bitPattern: at(1)))) cents"),
            item("inst.gain", "\(Int(Int8(bitPattern: at(2)))) dB"),
            item("inst.noteRange", "\(noteText(Int(at(3)))) – \(noteText(Int(at(4))))"),
            item("inst.velocityRange", "\(at(5)) – \(at(6))"),
        ]
    }

    private static func bext(_ b: Data) -> [MetadataItem] {
        func text(_ from: Int, _ length: Int) -> String {
            guard b.count >= from + length else { return "" }
            let bytes = b[(b.startIndex + from)..<(b.startIndex + from + length)].prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let fields = [
            ("bext.description", text(0, 256)), ("bext.originator", text(256, 32)),
            ("bext.originatorReference", text(288, 32)), ("bext.originationDate", text(320, 10)),
            ("bext.originationTime", text(330, 8)),
        ]
        var items = fields.filter { !$0.1.isEmpty }.map { item($0.0, $0.1) }
        if b.count >= 346 {
            let reference = UInt64(le32(b, 338)) | UInt64(le32(b, 342)) << 32
            if reference != 0 { items.append(item("bext.timeReference", "\(reference) samples")) }
        }
        if b.count > 602 {
            let history = text(602, b.count - 602)
            if !history.isEmpty { items.append(item("bext.codingHistory", history)) }
        }
        return items
    }

    /// `LIST` holds either `INFO` text tags or `adtl` labels for cue points.
    private static func list(_ b: Data) -> [MetadataItem] {
        guard b.count >= 4 else { return [] }
        let kind = String(decoding: b.prefix(4), as: UTF8.self)
        var items: [MetadataItem] = []
        var labels: [String] = []
        var position = 4
        while position + 8 <= b.count {
            let id = String(decoding: b[(b.startIndex + position)..<(b.startIndex + position + 4)], as: UTF8.self)
            let size = Int(le32(b, position + 4))
            let end = min(position + 8 + size, b.count)
            let skip = kind == "adtl" ? 4 : 0
            let bytes = b[(b.startIndex + min(position + 8 + skip, end))..<(b.startIndex + end)].prefix { $0 != 0 }
            let value = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                if kind == "INFO" { items.append(item("info.\(id)", value)) } else if kind == "adtl", id == "labl" || id == "note" { labels.append(value) }
            }
            position += 8 + size + size % 2
        }
        if kind == "adtl" { items.append(item("adtl.labels", labels.joined(separator: ", "))) }
        return kind == "adtl" && labels.isEmpty ? [] : items
    }

    private static func item(_ key: String, _ value: String) -> MetadataItem { MetadataItem(key: "riff.\(key)", value: value) }

    private static func noteText(_ midi: Int) -> String {
        (0...127).contains(midi) ? "\(MultisampleNames.noteLabel(midi)) (\(midi))" : "\(midi)"
    }

    private static func le32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return (0..<4).reduce(0) { $0 | UInt32(data[base + $1]) << (8 * UInt32($1)) }
    }
}
