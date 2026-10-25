import Accelerate
import Foundation

/// The six audio-feature dimensions shown in the parallel-coordinates view.
public enum Dim: String, CaseIterable, Sendable {
    case brightness, percussiveness, energy, tonality, noisiness, duration

    /// Column in `samples`.
    public var column: String { "dim_\(rawValue)" }
}

/// Raw (not yet corpus-normalised) values of the six dims for one clip.
public struct RawDims: Equatable, Sendable {
    public var values: [Dim: Double]

    public subscript(dim: Dim) -> Double { values[dim] ?? 0 }
}

/// Computes the six raw dims, following legacy `core/features.py`: 1024-point FFT, hop 512,
/// Hann window, no padding of the signal beyond one frame.
public enum AudioFeatures {
    static let fftSize = 1024
    static let hop = 512
    static let durationCap = 8.0
    static let epsilon = 1e-9
    private static let log2n = vDSP_Length(10)

    /// - Parameters:
    ///   - audio: Mono samples, as produced by ``AudioLoader``.
    ///   - sampleRate: Sample rate of `audio`.
    ///   - duration: Length of the *file* in seconds (the loader may have cropped or padded `audio`).
    public static func rawDims(audio: [Float], sampleRate: Double, duration: Double) -> RawDims {
        guard !audio.isEmpty else { return RawDims(values: Dictionary(uniqueKeysWithValues: Dim.allCases.map { ($0, 0) })) }
        let count = audio.count

        let energy = (audio.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(count)).squareRoot()

        var crossings = 0.0
        if count > 1 {
            var previous: Float = audio[0] >= 0 ? 1 : -1  // sign(0) counts as +1
            for sample in audio.dropFirst() {
                let sign: Float = sample >= 0 ? 1 : -1
                if sign != previous { crossings += 1 }
                previous = sign
            }
        }
        let noisiness = count > 1 ? crossings / Double(count - 1) : 0

        let spectrum = magnitudes(audio)
        let bins = fftSize / 2 + 1
        let frames = spectrum.count / bins

        let nyquist = sampleRate / 2
        var centroidSum = 0.0
        var magSum = 0.0
        var logSum = 0.0
        for t in 0..<frames {
            var weighted = 0.0
            var total = 0.0
            for k in 0..<bins {
                let m = Double(spectrum[t * bins + k])
                weighted += m * Double(Float(k) * Float(sampleRate / Double(fftSize)))
                total += m
                logSum += log(m + epsilon)
            }
            magSum += total
            centroidSum += log1p(weighted / (total + epsilon))
        }
        let brightness = min(max(centroidSum / Double(frames) / log1p(nyquist), 0), 1)

        var percussiveness = 0.0
        if frames > 1 {
            var flux = 0.0
            for i in bins..<(frames * bins) {
                flux += max(0, Double(spectrum[i]) - Double(spectrum[i - bins]))
            }
            percussiveness = (flux / Double(frames - 1)) / (magSum / Double(spectrum.count) + epsilon)
        }

        let meanMag = magSum / Double(spectrum.count)
        let flatness = exp(logSum / Double(spectrum.count)) / (meanMag + epsilon)
        let tonality = min(max(1 - flatness, 0), 1)

        return RawDims(values: [
            .brightness: brightness, .percussiveness: percussiveness, .energy: energy,
            .tonality: tonality, .noisiness: noisiness, .duration: min(max(duration / durationCap, 0), 1),
        ])
    }

    /// Magnitude spectrogram, `frames * 513` row-major, rounded to Float like the reference.
    static func magnitudes(_ input: [Float]) -> [Float] {
        var audio = input
        if audio.count < fftSize { audio += [Float](repeating: 0, count: fftSize - audio.count) }
        let frames = max(1, (audio.count - fftSize) / hop + 1)
        let half = fftSize / 2
        let bins = half + 1
        let window = (0..<fftSize).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(fftSize - 1)) }
        guard let setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("cannot create FFT setup")
        }
        defer { vDSP_destroy_fftsetupD(setup) }

        var result = [Float](repeating: 0, count: frames * bins)
        var frame = [Double](repeating: 0, count: fftSize)
        var real = [Double](repeating: 0, count: half)
        var imag = [Double](repeating: 0, count: half)
        for t in 0..<frames {
            for i in 0..<fftSize { frame[i] = Double(audio[t * hop + i]) * window[i] }
            real.withUnsafeMutableBufferPointer { re in
                imag.withUnsafeMutableBufferPointer { im in
                    var split = DSPDoubleSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                    frame.withUnsafeBufferPointer { buf in
                        buf.baseAddress!.withMemoryRebound(to: DSPDoubleComplex.self, capacity: half) {
                            vDSP_ctozD($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zripD(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                }
            }
            // zrip returns 2x the DFT, with DC in real[0] and Nyquist in imag[0].
            let row = t * bins
            result[row] = Float(abs(real[0] / 2))
            result[row + half] = Float(abs(imag[0] / 2))
            for k in 1..<half {
                result[row + k] = Float((real[k] * real[k] + imag[k] * imag[k]).squareRoot() / 2)
            }
        }
        return result
    }
}
