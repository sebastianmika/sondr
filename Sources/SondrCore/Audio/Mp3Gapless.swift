import Foundation

/// Samples to drop from a decoded mp3 so that it is gapless, from the LAME/Xing header.
///
/// AVFoundation returns every decoded frame, including the encoder delay at the start and the
/// padding at the end; libsndfile (and so librosa) trims them. Without trimming, a short clip that
/// `ClapMelExtractor` repeats to fill its window gets a gap at every seam.
///
/// Apple's decoder already compensates the 529 samples of decoder delay, so only the values from
/// the tag are dropped (measured: onset of lead.mp3 at 588 untrimmed vs 12 in the gapless reference,
/// and `length = delay + original + padding` holds exactly for both mp3 fixtures).
struct Mp3Gapless: Equatable {
    /// Samples to drop at the start: the encoder delay.
    let startSkip: Int
    /// Samples to drop at the end: the encoder padding.
    let endTrim: Int

    /// Reads the tag from a file, or `nil` if it is not an mp3 or carries no LAME tag.
    static func read(from url: URL) -> Mp3Gapless? {
        guard url.pathExtension.lowercased() == "mp3", let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 10) else { return nil }
        var offset: UInt64 = 0
        if header.count == 10, header.prefix(3) == Data("ID3".utf8) {
            // Syncsafe 28-bit size of the ID3v2 tag that precedes the audio.
            let size = header[6...9].reduce(0) { ($0 << 7) | Int($1 & 0x7F) }
            offset = UInt64(10 + size)
        }
        guard (try? handle.seek(toOffset: offset)) != nil,
            let head = try? handle.read(upToCount: 4096), !head.isEmpty
        else { return nil }
        return parse(Array(head))
    }

    /// Parses the first frame found in `bytes` (the start of the audio data).
    static func parse(_ bytes: [UInt8]) -> Mp3Gapless? {
        guard let p = (0..<max(bytes.count - 4, 0)).first(where: { bytes[$0] == 0xFF && bytes[$0 + 1] & 0xE0 == 0xE0 })
        else { return nil }
        let version = Int(bytes[p + 1] >> 3) & 3  // 3 = MPEG-1, 2 = MPEG-2, 0 = MPEG-2.5
        let layer = Int(bytes[p + 1] >> 1) & 3  // 1 = Layer III
        guard layer == 1, version != 1 else { return nil }
        let crc = bytes[p + 1] & 1 == 0 ? 2 : 0
        let mono = (bytes[p + 3] >> 6) & 3 == 3
        let sideInfo = version == 3 ? (mono ? 17 : 32) : (mono ? 9 : 17)
        let tag = p + 4 + crc + sideInfo
        guard tag + 12 <= bytes.count else { return nil }
        let name = String(decoding: bytes[tag..<(tag + 4)], as: UTF8.self)
        guard name == "Xing" || name == "Info" else { return nil }

        let flags = bytes[(tag + 4)..<(tag + 8)].reduce(0) { ($0 << 8) | Int($1) }
        var position = tag + 8
        if flags & 1 != 0 { position += 4 }  // frame count
        if flags & 2 != 0 { position += 4 }  // byte count
        if flags & 4 != 0 { position += 100 }  // table of contents
        if flags & 8 != 0 { position += 4 }  // quality
        // 9 bytes encoder string, then 12 bytes of tag revision, lowpass, replay gain and flags.
        let delayAt = position + 21
        guard delayAt + 3 <= bytes.count else { return nil }
        let delay = Int(bytes[delayAt]) << 4 | Int(bytes[delayAt + 1]) >> 4
        let padding = Int(bytes[delayAt + 1] & 0x0F) << 8 | Int(bytes[delayAt + 2])
        guard delay < 2880, padding < 4608 else { return nil }  // implausible: not a LAME tag
        return Mp3Gapless(startSkip: delay, endTrim: padding)
    }
}
