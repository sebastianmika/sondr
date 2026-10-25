import Accelerate
import CoreML
import Foundation

public enum EmbeddingError: Error, Equatable, LocalizedError {
    case modelMissing(URL)
    case compileFailed(String)
    case predictionFailed(String)
    case unexpectedOutput(String)

    public var errorDescription: String? {
        switch self {
        case .modelMissing(let url):
            return "Model not found at \(url.path). Build it with tools/convert_clap/convert.py."
        case .compileFailed(let why): return "Cannot compile Core ML model: \(why)"
        case .predictionFailed(let why): return "Core ML prediction failed: \(why)"
        case .unexpectedOutput(let why): return "Unexpected model output: \(why)"
        }
    }
}

/// Runs the CLAP audio and text towers (Core ML) and returns L2-normalised 512-d vectors.
///
/// Models are compiled and loaded lazily on first use and kept for the life of the service.
/// Compiled models are cached on disk, keyed by `model_version.txt` and the package's
/// modification time. Audio goes through ``ClapMelExtractor`` first; the audio model has a fixed
/// batch of ``audioBatchSize`` and the last batch is padded, which does not change the results.
public actor EmbeddingService {
    public static let audioBatchSize = 16
    public static let embeddingSize = 512

    /// Which hardware may run the models. `.cpuAndGPU` is fastest for the audio tower; the Neural
    /// Engine does not help (see docs/BENCHMARKS.md).
    public enum ComputeUnits: String, Sendable, CaseIterable {
        case all, cpuAndGPU, cpuOnly

        var mlUnits: MLComputeUnits {
            switch self {
            case .all: return .all
            case .cpuAndGPU: return .cpuAndGPU
            case .cpuOnly: return .cpuOnly
            }
        }
    }

    private let modelsDirectory: URL
    private let cacheDirectory: URL
    private let computeUnits: ComputeUnits
    private let mel = ClapMelExtractor()
    private var audioModel: MLModel?
    private var textModel: MLModel?
    private var tokenizer: ClapTokenizer?

    /// - Parameters:
    ///   - modelsDirectory: Folder with `ClapAudio.mlpackage`, `ClapText.mlpackage`, `model_version.txt`.
    ///   - computeUnits: Hardware preference.
    ///   - cacheDirectory: Where compiled models are kept. Default `~/Library/Caches/Sondr/CompiledModels`,
    ///     overridable with the `SONDR_MODEL_CACHE` environment variable.
    public init(
        modelsDirectory: URL,
        computeUnits: ComputeUnits = .cpuAndGPU,
        cacheDirectory: URL? = nil
    ) {
        self.modelsDirectory = modelsDirectory
        self.computeUnits = computeUnits
        if let cacheDirectory {
            self.cacheDirectory = cacheDirectory
        } else if let path = ProcessInfo.processInfo.environment["SONDR_MODEL_CACHE"] {
            self.cacheDirectory = URL(fileURLWithPath: path)
        } else {
            self.cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Sondr/CompiledModels")
        }
    }

    /// Version string of the converted models, to be stored with every embedding.
    public func modelVersion() throws -> String {
        let url = modelsDirectory.appendingPathComponent("model_version.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw EmbeddingError.modelMissing(url)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Embeds audio clips.
    ///
    /// - Parameter clips: Mono 48 kHz clips as produced by ``AudioLoader`` (any length up to 10 s;
    ///   longer ones are cut by the mel extractor).
    /// - Returns: One unit-length 512-d vector per clip, in order.
    public func embed(audio clips: [[Float]]) async throws -> [[Float]] {
        guard !clips.isEmpty else { return [] }
        let model = try await loadedAudioModel()
        var result: [[Float]] = []
        result.reserveCapacity(clips.count)
        let size = Self.audioBatchSize
        for start in stride(from: 0, to: clips.count, by: size) {
            let batch = Array(clips[start..<min(start + size, clips.count)])
            let features = await melFeatures(batch)
            result += try predictAudio(model, features: features)
        }
        return result
    }

    /// Embeds a text query.
    ///
    /// - Returns: A unit-length 512-d vector.
    public func embed(text: String) async throws -> [Float] {
        let model = try await loadedTextModel()
        if tokenizer == nil { tokenizer = try ClapTokenizer.bundled() }
        return try predictText(model, ids: tokenizer!.encode(text))
    }

    private func predictText(_ model: MLModel, ids: [Int32]) throws -> [Float] {
        let shape = [1, NSNumber(value: ids.count)]
        do {
            let idArray = try MLMultiArray(shape: shape, dataType: .int32)
            let maskArray = try MLMultiArray(shape: shape, dataType: .int32)
            for (i, id) in ids.enumerated() {
                idArray[i] = NSNumber(value: id)
                maskArray[i] = 1
            }
            let input = try MLDictionaryFeatureProvider(dictionary: [
                "input_ids": MLFeatureValue(multiArray: idArray),
                "attention_mask": MLFeatureValue(multiArray: maskArray),
            ])
            let output = try model.prediction(from: input)
            return try Self.vectors(from: output, rows: 1)[0]
        } catch let error as EmbeddingError {
            throw error
        } catch {
            throw EmbeddingError.predictionFailed(error.localizedDescription)
        }
    }

    // MARK: Audio

    private func melFeatures(_ clips: [[Float]]) async -> [[Float]] {
        let extractor = mel
        return await withTaskGroup(of: (Int, [Float]).self) { group in
            for (i, clip) in clips.enumerated() {
                group.addTask { (i, extractor.features(for: clip)) }
            }
            var out = [[Float]](repeating: [], count: clips.count)
            for await (i, features) in group { out[i] = features }
            return out
        }
    }

    private func predictAudio(_ model: MLModel, features: [[Float]]) throws -> [[Float]] {
        let perClip = ClapMelExtractor.frameCount * ClapMelExtractor.melBins
        do {
            let input = try MLMultiArray(
                shape: [
                    NSNumber(value: Self.audioBatchSize), 1,
                    NSNumber(value: ClapMelExtractor.frameCount),
                    NSNumber(value: ClapMelExtractor.melBins),
                ], dataType: .float32)
            let pointer = input.dataPointer.assumingMemoryBound(to: Float.self)
            pointer.update(repeating: 0, count: Self.audioBatchSize * perClip)
            for (row, clip) in features.enumerated() {
                clip.withUnsafeBufferPointer { (pointer + row * perClip).update(from: $0.baseAddress!, count: perClip) }
            }
            let output = try model.prediction(
                from: MLDictionaryFeatureProvider(dictionary: [
                    "input_features": MLFeatureValue(multiArray: input)
                ]))
            return try Self.vectors(from: output, rows: features.count)
        } catch let error as EmbeddingError {
            throw error
        } catch {
            throw EmbeddingError.predictionFailed(error.localizedDescription)
        }
    }

    /// Reads the first `rows` rows of `embedding` and re-normalises them (fp16 outputs are 1 +- 1e-3).
    private static func vectors(from output: MLFeatureProvider, rows: Int) throws -> [[Float]] {
        guard let array = output.featureValue(for: "embedding")?.multiArrayValue else {
            throw EmbeddingError.unexpectedOutput("no 'embedding' output")
        }
        let shape = array.shape.map(\.intValue)
        guard shape.count == 2, shape[1] == embeddingSize, shape[0] >= rows else {
            throw EmbeddingError.unexpectedOutput("shape \(shape), expected [>= \(rows), \(embeddingSize)]")
        }
        let strides = array.strides.map(\.intValue)
        var result: [[Float]] = []
        for row in 0..<rows {
            var vector = [Float](repeating: 0, count: embeddingSize)
            for column in 0..<embeddingSize {
                let index = row * strides[0] + column * strides[1]
                switch array.dataType {
                case .float32: vector[column] = array.dataPointer.assumingMemoryBound(to: Float.self)[index]
                case .float16: vector[column] = Float(array.dataPointer.assumingMemoryBound(to: Float16.self)[index])
                case .double: vector[column] = Float(array.dataPointer.assumingMemoryBound(to: Double.self)[index])
                default: throw EmbeddingError.unexpectedOutput("data type \(array.dataType.rawValue)")
                }
            }
            let length = vDSP.rootMeanSquare(vector) * Float(embeddingSize).squareRoot()
            guard length.isFinite, length > 0 else {
                throw EmbeddingError.unexpectedOutput("row \(row) has norm \(length)")
            }
            result.append(vDSP.divide(vector, length))
        }
        return result
    }

    // MARK: Model loading

    private func loadedAudioModel() async throws -> MLModel {
        if let audioModel { return audioModel }
        let model = try await load(named: "ClapAudio")
        audioModel = model
        return model
    }

    private func loadedTextModel() async throws -> MLModel {
        if let textModel { return textModel }
        let model = try await load(named: "ClapText")
        textModel = model
        return model
    }

    private func load(named name: String) async throws -> MLModel {
        let package = modelsDirectory.appendingPathComponent("\(name).mlpackage")
        guard FileManager.default.fileExists(atPath: package.path) else {
            throw EmbeddingError.modelMissing(package)
        }
        let compiled = try await compiledURL(for: package, name: name)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits.mlUnits
        do {
            return try MLModel(contentsOf: compiled, configuration: configuration)
        } catch {
            throw EmbeddingError.compileFailed(error.localizedDescription)
        }
    }

    /// Compiled `.mlmodelc` for `package`, compiling and caching it on first use.
    private func compiledURL(for package: URL, name: String) async throws -> URL {
        let manifest = package.appendingPathComponent("Manifest.json")
        let modified = (try? manifest.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        let version = (try? modelVersion()) ?? "unversioned"
        let key = version.replacingOccurrences(of: "/", with: "_") + "-\(Int(modified))"
        let target = cacheDirectory.appendingPathComponent(key).appendingPathComponent("\(name).mlmodelc")
        if FileManager.default.fileExists(atPath: target.path) { return target }
        do {
            let temporary = try await MLModel.compileModel(at: package)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: temporary, to: target)
            return target
        } catch {
            throw EmbeddingError.compileFailed(error.localizedDescription)
        }
    }
}
