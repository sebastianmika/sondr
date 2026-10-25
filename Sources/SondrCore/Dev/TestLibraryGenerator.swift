import Foundation

/// Writes a synthetic sample library of tiny WAV files, for benchmarks and UI spikes.
///
/// Files are 8-bit mono 8 kHz, 50 ms (about 450 bytes). Every file has different content, so a
/// scan sees `count` distinct samples. Folders and names look like a real library
/// (`Pack 007/Drums/Kicks/Kick_Hard_00042.wav`), so tags and clusters have something to find.
/// Output is a pure function of `count` and `seed`.
public enum TestLibraryGenerator {
    static let categories: [(folder: String, words: [String])] = [
        ("Drums/Kicks", ["Kick", "BD", "808 Kick"]),
        ("Drums/Snares", ["Snare", "SD", "Rim"]),
        ("Drums/Hats", ["Hat", "HiHat", "OH", "CH"]),
        ("Drums/Percussion", ["Perc", "Shaker", "Tom", "Clap"]),
        ("Bass", ["Bass", "Sub", "808 Bass"]),
        ("Synth/Pads", ["Pad", "Warm Pad", "Atmosphere"]),
        ("Synth/Leads", ["Lead", "Pluck", "Arp"]),
        ("Vocals", ["Vox", "Vocal Chop", "Ah"]),
        ("FX", ["Riser", "Impact", "SFX", "Downlifter"]),
    ]
    static let adjectives = [
        "Hard", "Soft", "Dark", "Bright", "Warm", "Punchy", "Dry", "Wet", "Long", "Short", "Clean",
        "Distorted",
    ]
    static let sampleRate = 8000
    static let frames = 400
    static let filesPerPack = 500

    /// Creates `count` files under `root` (created if needed). Returns the number written.
    @discardableResult
    public static func generate(count: Int, into root: URL, seed: UInt64 = 1) throws -> Int {
        let fileManager = FileManager.default
        var made = Set<String>()
        for index in 0..<count {
            let relative = relativePath(index: index, seed: seed)
            let url = root.appendingPathComponent(relative)
            let folder = url.deletingLastPathComponent().path
            if made.insert(folder).inserted {
                try fileManager.createDirectory(atPath: folder, withIntermediateDirectories: true)
            }
            try wav(index: index, seed: seed).write(to: url)
        }
        return count
    }

    /// Path of file `index` relative to the library root.
    public static func relativePath(index: Int, seed: UInt64 = 1) -> String {
        var random = SplitMix(state: seed &+ UInt64(index) &* 0x9E37_79B9_7F4A_7C15)
        let category = categories[Int(random.next() % UInt64(categories.count))]
        let word = category.words[Int(random.next() % UInt64(category.words.count))]
        let adjective = adjectives[Int(random.next() % UInt64(adjectives.count))]
        let pack = String(format: "Pack %03d", index / filesPerPack)
        let name = "\(word.replacingOccurrences(of: " ", with: "_"))_\(adjective)_\(String(format: "%05d", index))"
        return "\(pack)/\(category.folder)/\(name).wav"
    }

    /// A complete WAV file: PCM, 8 bit, mono. The samples are noise seeded per file, so every
    /// file hashes differently.
    static func wav(index: Int, seed: UInt64) -> Data {
        var random = SplitMix(state: (seed << 32) ^ UInt64(index) ^ 0xA5A5_A5A5)
        var bytes = Data(capacity: 44 + frames)
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) } }
        bytes.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + frames))
        bytes.append(contentsOf: Array("WAVE".utf8))
        bytes.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate)); u16(1); u16(8)
        bytes.append(contentsOf: Array("data".utf8)); u32(UInt32(frames))
        for _ in 0..<frames { bytes.append(UInt8(truncatingIfNeeded: random.next() >> 56)) }
        return bytes
    }

    private struct SplitMix {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
