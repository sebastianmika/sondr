import Foundation

/// Reads the root note (MIDI) a sampler should play a file at, from its header chunks, without decoding audio.
///
/// WAV: `smpl` (MIDIUnityNote), then `acid` (root note, when flagged valid), then `inst` (unshifted note).
/// AIFF/AIFC: `INST` (baseNote). Returns nil for other formats and for files without such a chunk.
public enum AudioRootNote {
    private static let maxChunks = 64

    public static func read(from url: URL) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 12), header.count == 12 else { return nil }
        let form = String(decoding: header.prefix(4), as: UTF8.self)
        let kind = String(decoding: header[8..<12], as: UTF8.self)
        switch (form, kind) {
        case ("RIFF", "WAVE"): return wavRootNote(handle)
        case ("FORM", "AIFF"), ("FORM", "AIFC"): return aiffRootNote(handle)
        default: return nil
        }
    }

    /// Every note number a WAV file's header chunks mention: the root notes of `smpl`, `acid` and `inst`,
    /// and the low and high note of the `inst` key range. Empty for other formats and files without such chunks.
    ///
    /// Sample packs often put one of these in the file name (`45 Lead C2.wav`, with 45 the low note), so it
    /// is not part of the instrument's name.
    public static func pitchNumbers(from url: URL) -> Set<Int> {
        guard let handle = try? FileHandle(forReadingFrom: url),
            let header = try? handle.read(upToCount: 12), header.count == 12,
            header.prefix(4) == Data("RIFF".utf8), header[8..<12] == Data("WAVE".utf8)
        else { return [] }
        defer { try? handle.close() }
        var numbers = Set<Int>()
        forEachChunk(handle, bigEndian: false) { id, size, data in
            switch id {
            case "smpl": if size >= 16, let bytes = data(16) { numbers.insert(Int(le32(bytes, at: 12))) }
            case "acid": if size >= 6, let bytes = data(6) { numbers.insert(Int(le16(bytes, at: 4))) }
            case "inst":
                if size >= 5, let bytes = data(5) {
                    numbers.formUnion([0, 3, 4].map { Int(bytes[bytes.startIndex + $0]) })
                }
            default: break
            }
        }
        return numbers
    }

    private static func wavRootNote(_ handle: FileHandle) -> Int? {
        var smpl: Int?, acid: Int?, inst: Int?
        forEachChunk(handle, bigEndian: false) { id, size, data in
            switch id {
            case "smpl":
                if size >= 16, let bytes = data(16) { smpl = Int(le32(bytes, at: 12)) }
            case "acid":
                if size >= 6, let bytes = data(6), le32(bytes, at: 0) & 0x02 != 0 { acid = Int(le16(bytes, at: 4)) }
            case "inst":
                if size >= 1, let bytes = data(1) { inst = Int(bytes[bytes.startIndex]) }
            default: break
            }
        }
        return [smpl, acid, inst].compactMap { $0 }.first { (0...127).contains($0) }
    }

    private static func aiffRootNote(_ handle: FileHandle) -> Int? {
        var base: Int?
        forEachChunk(handle, bigEndian: true) { id, size, data in
            if id == "INST", size >= 1, let bytes = data(1) { base = Int(bytes[bytes.startIndex]) }
        }
        return base.flatMap { (0...127).contains($0) ? $0 : nil }
    }

    /// Walks the chunks after the 12-byte header; `data(n)` reads the first `n` bytes of the current chunk.
    private static func forEachChunk(
        _ handle: FileHandle, bigEndian: Bool, _ body: (String, Int, (Int) -> Data?) -> Void
    ) {
        for _ in 0..<maxChunks {
            guard let header = try? handle.read(upToCount: 8), header.count == 8 else { return }
            // A non-printable id means a damaged file: stop instead of walking garbage.
            guard header.prefix(4).allSatisfy({ (0x20...0x7E).contains($0) }) else { return }
            let id = String(decoding: header.prefix(4), as: UTF8.self)
            let size = Int(bigEndian ? be32(header, at: 4) : le32(header, at: 4))
            guard let start = try? handle.offset() else { return }
            body(id, size) { count in
                defer { try? handle.seek(toOffset: start) }
                return try? handle.read(upToCount: count)
            }
            let next = start + UInt64(size + size % 2)
            guard (try? handle.seek(toOffset: next)) != nil else { return }
        }
    }

    private static func le16(_ data: Data, at offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) | UInt16(data[base + 1]) << 8
    }

    private static func le32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(le16(data, at: offset)) | UInt32(le16(data, at: offset + 2)) << 16
    }

    private static func be32(_ data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return data[base...].prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }
}
