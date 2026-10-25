import Accelerate
import Foundation
import GRDB

/// Small spectrogram for display: ``columns`` points in time by ``bands`` log-spaced frequency
/// bands (50 Hz to 14 kHz, like the model's mel range), one byte each, stored in
/// `samples.spectrogram_thumb`. Time-major (`[column][band]`, band 0 is the lowest).
///
/// Values are dB relative to the loudest cell of the clip, from -70 dB (0) to 0 dB (255), so
/// the picture does not depend on how loud the file is. This is for looking at, not for the model.
public enum SpectrogramThumbnail {
    public static let columns = 64
    public static let bands = 32
    static let fftSize = 1024
    static let minFrequency = 50.0
    static let maxFrequency = 14_000.0
    static let rangeDB: Float = 70

    /// The band that covers `hz`, clamped to the available bands.
    public static func band(forFrequency hz: Double) -> Int {
        min(Int(axisPosition(forFrequency: hz) * Double(bands)), bands - 1)
    }

    /// Where `hz` sits on the frequency axis, 0 at the bottom (50 Hz) to 1 at the top (14 kHz).
    public static func axisPosition(forFrequency hz: Double) -> Double {
        min(max(log(hz / minFrequency) / log(maxFrequency / minFrequency), 0), 1)
    }

    /// RGBA pixels (premultiplied, top row first, so the highest band is at the top) in which a
    /// cell's level sets the opacity of `accent`: silent cells are transparent and show whatever
    /// is behind the picture. Nil if `thumb` is missing or has the wrong size.
    public static func pixels(from thumb: Data?, accent: (red: UInt8, green: UInt8, blue: UInt8)) -> [UInt8]? {
        guard let thumb, thumb.count == columns * bands else { return nil }
        var pixels = [UInt8](repeating: 0, count: columns * bands * 4)
        for column in 0..<columns {
            for band in 0..<bands {
                let alpha = (pow(Double(thumb[thumb.startIndex + column * bands + band]) / 255, 0.85) * 255).rounded()
                let p = ((bands - 1 - band) * columns + column) * 4
                func premultiplied(_ channel: UInt8) -> UInt8 { UInt8((Double(channel) * alpha / 255).rounded()) }
                pixels[p] = premultiplied(accent.red)
                pixels[p + 1] = premultiplied(accent.green)
                pixels[p + 2] = premultiplied(accent.blue)
                pixels[p + 3] = UInt8(alpha)
            }
        }
        return pixels
    }

    /// FFT bins `lo..<hi` that make up each band; every band has at least one.
    private static let bandBins: [(lo: Int, hi: Int)] = {
        let binHz = Double(ClapMelExtractor.sampleRate) / Double(fftSize)
        func bin(_ band: Int) -> Int {
            Int(minFrequency * pow(maxFrequency / minFrequency, Double(band) / Double(bands)) / binHz)
        }
        return (0..<bands).map { band in
            let lo = max(bin(band), 1)
            return (lo, min(max(bin(band + 1), lo + 1), fftSize / 2))
        }
    }()

    private static let window: [Float] = (0..<fftSize).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(fftSize))) }

    /// Always returns `columns * bands` bytes. Silence and empty clips give all zeros.
    /// Only the first 10 s are looked at, as for the embedding.
    public static func make(audio full: [Float]) -> [UInt8] {
        let audio = full.prefix(ClapMelExtractor.windowSamples)
        let size = columns * bands
        guard !audio.isEmpty, let setup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2)) else {
            return [UInt8](repeating: 0, count: size)
        }
        defer { vDSP_destroy_fftsetup(setup) }

        var power = [Float](repeating: 0, count: size)
        var frame = [Float](repeating: 0, count: fftSize)
        var real = [Float](repeating: 0, count: fftSize / 2)
        var imaginary = [Float](repeating: 0, count: fftSize / 2)
        let samples = Array(audio)
        for column in 0..<columns {
            let start = (2 * column + 1) * samples.count / (2 * columns) - fftSize / 2
            for i in 0..<fftSize {
                let index = start + i
                frame[i] = index >= 0 && index < samples.count ? samples[index] * window[i] : 0
            }
            real.withUnsafeMutableBufferPointer { re in
                imaginary.withUnsafeMutableBufferPointer { im in
                    var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                    frame.withUnsafeBufferPointer { input in
                        input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize / 2))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, 10, FFTDirection(kFFTDirection_Forward))
                }
            }
            for (band, range) in bandBins.enumerated() {
                var sum: Float = 0
                for k in range.lo..<range.hi { sum += real[k] * real[k] + imaginary[k] * imaginary[k] }
                power[column * bands + band] = sum / Float(range.hi - range.lo)
            }
        }

        let loudest = power.max() ?? 0
        guard loudest > 1e-9 else { return [UInt8](repeating: 0, count: size) }
        return power.map { value in
            let db = 10 * log10(max(value / loudest, 1e-7))
            return UInt8(((max(db, -rangeDB) + rangeDB) / rangeDB * 255).rounded())
        }
    }

    public static func store(_ db: Database, sampleID: Int64, thumbnail: [UInt8]) throws {
        try db.execute(
            sql: "UPDATE samples SET spectrogram_thumb = ? WHERE id = ?", arguments: [Data(thumbnail), sampleID])
    }

    /// The stored thumbnail, or nil if the sample has none yet.
    public static func load(_ db: Database, sampleID: Int64) throws -> Data? {
        try Data.fetchOne(db, sql: "SELECT spectrogram_thumb FROM samples WHERE id = ?", arguments: [sampleID])
    }
}
