import Accelerate
import GRDB

/// Fixed-size waveform overview: the peak (maximum absolute sample) of each of ``bins`` equal
/// slices of the clip, scaled so that 1.0 is 255. Stored in `samples.wave_thumb`.
public enum WaveformThumbnail {
    public static let bins = 128

    /// Always returns exactly ``bins`` bytes. An empty clip gives all zeros. Clips shorter than
    /// ``bins`` samples repeat samples across neighbouring bins.
    public static func make(audio: [Float]) -> [UInt8] {
        let count = audio.count
        guard count > 0 else { return [UInt8](repeating: 0, count: bins) }
        return (0..<bins).map { bin in
            let start = bin * count / bins
            let end = max((bin + 1) * count / bins, start + 1)
            let peak = audio.withUnsafeBufferPointer { buffer in
                vDSP.maximumMagnitude(buffer[start..<min(end, count)])
            }
            return UInt8((min(peak, 1) * 255).rounded())
        }
    }

    public static func store(_ db: Database, sampleID: Int64, thumbnail: [UInt8]) throws {
        try db.execute(
            sql: "UPDATE samples SET wave_thumb = ? WHERE id = ?", arguments: [Data(thumbnail), sampleID])
    }
}
