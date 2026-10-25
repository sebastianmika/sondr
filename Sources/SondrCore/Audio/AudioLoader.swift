import AVFoundation
import Accelerate
import Foundation

/// Why an audio file could not be turned into model input.
public enum AudioLoadError: Error, Equatable, LocalizedError {
    /// The file is missing, not audio, or corrupt.
    case unreadable(URL, reason: String)
    /// The file decodes but contains no samples.
    case empty(URL)
    /// Mixing down or resampling failed.
    case conversionFailed(URL, reason: String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url, let reason):
            return "Cannot read \(url.lastPathComponent): \(reason)"
        case .empty(let url):
            return "\(url.lastPathComponent) contains no audio"
        case .conversionFailed(let url, let reason):
            return "Cannot convert \(url.lastPathComponent): \(reason)"
        }
    }
}

/// Decodes an audio file into CLAP input: mono, 48 kHz, at most 10 s, at least 1 s, peak 1.0.
///
/// Mirrors `tools/golden/generate.py` (`librosa.load(sr=48000, mono=True, duration=10)`, zero
/// pad to 1 s, peak normalise). Never writes to disk. Failures throw; they are never turned
/// into silence.
public enum AudioLoader {
    public static let sampleRate = Double(ClapMelExtractor.sampleRate)
    public static let maxSamples = ClapMelExtractor.windowSamples
    public static let minSamples = ClapMelExtractor.sampleRate

    /// Loads and normalises one file.
    ///
    /// - Parameter url: Audio file readable by AVFoundation (wav, aiff, flac, mp3, caf, m4a).
    /// - Returns: Between `minSamples` and `maxSamples` mono samples at 48 kHz, peak 1.0
    ///   (all zeros for digital silence).
    /// - Throws: ``AudioLoadError``.
    public static func load(url: URL) throws -> [Float] {
        let mono = try readMono(url: url)
        var samples = try resample(mono.samples, from: mono.sampleRate, url: url)
        if samples.count > maxSamples { samples.removeSubrange(maxSamples...) }
        if samples.count < minSamples {
            samples += [Float](repeating: 0, count: minSamples - samples.count)
        }
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        if peak > 0 {
            var divisor = peak
            vDSP_vsdiv(samples, 1, &divisor, &samples, 1, vDSP_Length(samples.count))
        }
        return samples
    }

    /// Reads the first ~10 s of the file at its own rate, averaging channels.
    private static func readMono(url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw AudioLoadError.unreadable(url, reason: error.localizedDescription)
        }
        let format = file.processingFormat
        // A little extra so the resampler's filter tail does not shorten the 10 s window.
        let wanted = Int64((format.sampleRate * 10).rounded(.up)) + 2048
        let frames = AVAudioFrameCount(min(file.length, wanted))
        guard frames > 0 else { throw AudioLoadError.empty(url) }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw AudioLoadError.conversionFailed(url, reason: "cannot allocate \(frames) frames")
        }
        do {
            try file.read(into: buffer, frameCount: frames)
        } catch {
            throw AudioLoadError.unreadable(url, reason: error.localizedDescription)
        }
        let count = Int(buffer.frameLength)
        guard count > 0, let channels = buffer.floatChannelData else { throw AudioLoadError.empty(url) }

        var mono = Array(UnsafeBufferPointer(start: channels[0], count: count))
        let channelCount = Int(format.channelCount)
        for c in 1..<max(channelCount, 1) {
            vDSP_vadd(mono, 1, channels[c], 1, &mono, 1, vDSP_Length(count))
        }
        if channelCount > 1 {
            var divisor = Float(channelCount)
            vDSP_vsdiv(mono, 1, &divisor, &mono, 1, vDSP_Length(count))
        }
        if let gapless = Mp3Gapless.read(from: url) {
            let wholeFile = Int64(count) >= file.length
            let end = max(mono.count - (wholeFile ? gapless.endTrim : 0), 0)
            guard gapless.startSkip < end else { throw AudioLoadError.empty(url) }
            mono = Array(mono[gapless.startSkip..<end])
        }
        return (mono, format.sampleRate)
    }

    private static func resample(_ samples: [Float], from rate: Double, url: URL) throws -> [Float] {
        guard rate != sampleRate else { return samples }
        guard
            let inFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
            let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: inFormat, to: outFormat),
            let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw AudioLoadError.conversionFailed(url, reason: "cannot create resampler for \(rate) Hz") }

        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }

        let capacity = AVAudioFrameCount((Double(samples.count) * sampleRate / rate).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
            throw AudioLoadError.conversionFailed(url, reason: "cannot allocate output")
        }
        var supplied = false
        var convertError: NSError?
        let status = converter.convert(to: output, error: &convertError) { _, outStatus in
            if supplied {
                outStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0 else {
            throw AudioLoadError.conversionFailed(
                url, reason: convertError?.localizedDescription ?? "resampling produced no samples")
        }
        var resampled = Array(
            UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
        // Same length rule, in the same order of operations, as librosa: ceil(n * (target / source)).
        // The order matters: it decides whether float error rounds an exact 96000 up to 96001.
        let expected = Int((Double(samples.count) * (sampleRate / rate)).rounded(.up))
        if resampled.count > expected {
            resampled.removeSubrange(expected...)
        } else if resampled.count < expected {
            resampled += [Float](repeating: 0, count: expected - resampled.count)
        }
        return resampled
    }
}
