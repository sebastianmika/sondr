import Accelerate
import Foundation

/// Log-mel features for the CLAP audio tower, matching Hugging Face's `ClapFeatureExtractor`
/// (`truncation="fusion"`, `padding="repeatpad"`, clip of at most one window).
///
/// Parameters come from `Tests/Fixtures/golden/preprocessor_config.json`
/// (laion/clap-htsat-fused). With `truncation="fusion"` the extractor uses the HTK mel scale
/// without normalisation (`mel_filters`), not the Slaney bank (`mel_filters_slaney`) that
/// `rand_trunc` (the unfused model) used. We take channel 0 only.
///
/// Math is done in Double like the reference; the FFT output is rounded to Float first
/// because the reference stores it as `complex64`.
public final class ClapMelExtractor: @unchecked Sendable {
    public static let sampleRate = 48_000
    /// `nb_max_samples`: the model's 10 s window.
    public static let windowSamples = 480_000
    /// `fft_window_size` / `n_fft`.
    public static let fftSize = 1024
    public static let hopLength = 480
    /// `feature_size`.
    public static let melBins = 64
    /// `nb_frequency_bins`.
    public static let freqBins = 513
    /// `nb_max_frames` + 1: frames from a centred STFT of `windowSamples`.
    public static let frameCount = 1 + windowSamples / hopLength
    static let minFrequency = 50.0
    static let maxFrequency = 14_000.0
    static let powerFloor = 1e-10

    private let window: [Double]
    private let filters: [Double]
    private let fft: FFTSetupD
    private static let log2n = vDSP_Length(10)

    public init() {
        let n = Self.fftSize
        // Periodic Hann, as `window_function(n, "hann")`.
        window = (0..<n).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n)) }
        filters = Self.htkFilterBank()
        guard let setup = vDSP_create_fftsetupD(Self.log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("cannot create FFT setup")
        }
        fft = setup
    }

    deinit { vDSP_destroy_fftsetupD(fft) }

    /// Computes log-mel features in dB.
    ///
    /// Audio shorter than the window is repeated and then zero padded; longer audio is cut
    /// to its first `windowSamples` (the reference crops randomly, which is not reproducible).
    ///
    /// - Parameter audio: Mono samples at 48 kHz.
    /// - Returns: `frameCount * melBins` values, time-major (`[frame][mel]`).
    public func features(for audio: [Float]) -> [Float] {
        let samples = Self.repeatPadded(audio)
        let padded = Self.reflectPadded(samples, by: Self.fftSize / 2)
        let power = powerSpectrogram(padded)
        return logMel(power)
    }

    // MARK: Preprocessing

    static func repeatPadded(_ audio: [Float]) -> [Double] {
        var out = audio.prefix(windowSamples).map(Double.init)
        guard !out.isEmpty, out.count < windowSamples else {
            return out + [Double](repeating: 0, count: windowSamples - out.count)
        }
        let tile = out
        for _ in 1..<(windowSamples / tile.count) { out += tile }
        return out + [Double](repeating: 0, count: windowSamples - out.count)
    }

    /// numpy `pad(mode="reflect")`: mirrors around the edge sample without repeating it.
    static func reflectPadded(_ x: [Double], by pad: Int) -> [Double] {
        let n = x.count
        var out = [Double](repeating: 0, count: n + 2 * pad)
        for i in 0..<pad {
            out[i] = x[pad - i]
            out[pad + n + i] = x[n - 2 - i]
        }
        out.replaceSubrange(pad..<(pad + n), with: x)
        return out
    }

    // MARK: STFT

    /// Squared magnitude per frame and bin, `frameCount * freqBins` row-major.
    private func powerSpectrogram(_ padded: [Double]) -> [Double] {
        let n = Self.fftSize
        let half = n / 2
        var power = [Double](repeating: 0, count: Self.frameCount * Self.freqBins)
        var frame = [Double](repeating: 0, count: n)
        var real = [Double](repeating: 0, count: half)
        var imag = [Double](repeating: 0, count: half)

        for t in 0..<Self.frameCount {
            let start = t * Self.hopLength
            padded.withUnsafeBufferPointer { src in
                vDSP_vmulD(src.baseAddress! + start, 1, window, 1, &frame, 1, vDSP_Length(n))
            }
            real.withUnsafeMutableBufferPointer { re in
                imag.withUnsafeMutableBufferPointer { im in
                    var split = DSPDoubleSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                    frame.withUnsafeBufferPointer { buf in
                        buf.baseAddress!.withMemoryRebound(to: DSPDoubleComplex.self, capacity: half) {
                            vDSP_ctozD($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zripD(fft, &split, 1, Self.log2n, FFTDirection(kFFTDirection_Forward))
                }
            }
            // zrip returns 2x the DFT, with DC in real[0] and Nyquist in imag[0].
            let row = t * Self.freqBins
            power[row] = Self.complex64Power(real[0] / 2, 0)
            power[row + half] = Self.complex64Power(imag[0] / 2, 0)
            for k in 1..<half {
                power[row + k] = Self.complex64Power(real[k] / 2, imag[k] / 2)
            }
        }
        return power
    }

    /// |z|^2 after rounding both parts to Float, like the reference's `complex64` storage.
    @inline(__always)
    private static func complex64Power(_ re: Double, _ im: Double) -> Double {
        let r = Double(Float(re))
        let i = Double(Float(im))
        return r * r + i * i
    }

    // MARK: Mel and dB

    private func logMel(_ power: [Double]) -> [Float] {
        let frames = Self.frameCount, bins = Self.freqBins, mels = Self.melBins
        var mel = [Double](repeating: 0, count: frames * mels)
        // (frames x bins) * (bins x mels)
        cblas_dgemm(
            CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(frames), Int32(mels), Int32(bins),
            1.0, power, Int32(bins), filters, Int32(mels), 0.0, &mel, Int32(mels))
        var floor = Self.powerFloor
        vDSP_vthrD(mel, 1, &floor, &mel, 1, vDSP_Length(mel.count))
        var count = Int32(mel.count)
        vvlog10(&mel, mel, &count)
        return mel.map { Float(10 * $0) }
    }

    // MARK: Filter bank

    /// HTK-scale, un-normalised triangular filters, `freqBins x melBins` row-major.
    /// Port of `transformers.audio_utils.mel_filter_bank(norm=None, mel_scale="htk")`.
    static func htkFilterBank() -> [Double] {
        let melMin = hertzToMel(minFrequency)
        let melMax = hertzToMel(maxFrequency)
        let points = melBins + 2
        let filterFreqs = (0..<points).map { i in
            melToHertz(melMin + (melMax - melMin) * Double(i) / Double(points - 1))
        }
        let nyquist = Double(sampleRate / 2)
        let fftFreqs = (0..<freqBins).map { nyquist * Double($0) / Double(freqBins - 1) }

        var bank = [Double](repeating: 0, count: freqBins * melBins)
        for m in 0..<melBins {
            let lower = filterFreqs[m], centre = filterFreqs[m + 1], upper = filterFreqs[m + 2]
            for (k, f) in fftFreqs.enumerated() {
                let down = (f - lower) / (centre - lower)
                let up = (upper - f) / (upper - centre)
                bank[k * melBins + m] = max(0, min(down, up))
            }
        }
        return bank
    }

    private static func hertzToMel(_ hz: Double) -> Double { 2595.0 * log10(1.0 + hz / 700.0) }

    private static func melToHertz(_ mel: Double) -> Double { 700.0 * (pow(10.0, mel / 2595.0) - 1.0) }
}
