import Accelerate
import Foundation
import Testing

@testable import SondrCore

/// Parity tests need the converted models: set `SONDR_MODELS` (or build `<repo>/Models`).
private let modelsDirectory = ModelLocator.find() ?? URL(fileURLWithPath: "/nonexistent/Models")
private let modelsBuilt = ModelLocator.isComplete(modelsDirectory)

private let benchmarkEnabled = ProcessInfo.processInfo.environment["SONDR_BENCH"] != nil

private struct Manifest: Decodable {
    struct Entry: Decodable { let name: String }
    let audio: [Entry]
}

private func cosine(_ a: [Float], _ b: [Float]) -> Float {
    var dot: Float = 0
    vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
    return dot / (vDSP.rootMeanSquare(a) * vDSP.rootMeanSquare(b) * Float(a.count))
}

private func norm(_ a: [Float]) -> Float { vDSP.rootMeanSquare(a) * Float(a.count).squareRoot() }

private func goldenRows(_ file: String) throws -> [[Float]] {
    let npy = try Fixtures.npy("golden/\(file)")
    let width = npy.shape[1]
    let floats = npy.floats
    return (0..<npy.shape[0]).map { Array(floats[($0 * width)..<(($0 + 1) * width)]) }
}

private func makeService(_ units: EmbeddingService.ComputeUnits = .cpuAndGPU) -> EmbeddingService {
    EmbeddingService(modelsDirectory: modelsDirectory, computeUnits: units)
}

@Test(
    .enabled(if: modelsBuilt, "models not found: set SONDR_MODELS"),
    arguments: EmbeddingService.ComputeUnits.allCases)
func audioEmbeddingsMatchPyTorchOnAllFixtures(units: EmbeddingService.ComputeUnits) async throws {
    let manifest = try JSONDecoder().decode(
        Manifest.self, from: Data(contentsOf: Fixtures.url("golden/manifest.json")))
    let reference = try goldenRows("emb_10s.npy")
    #expect(reference.count == manifest.audio.count)

    let clips = try manifest.audio.map { try AudioLoader.load(url: Fixtures.url("audio/\($0.name)")) }
    let ours = try await makeService(units).embed(audio: clips)
    #expect(ours.count == clips.count)

    let scores = zip(ours, reference).map { cosine($0, $1) }
    let worst = scores.enumerated().min { $0.element < $1.element }!
    print(
        "audio parity \(units): n=\(scores.count) min \(worst.element) (\(manifest.audio[worst.offset].name)) "
            + "mean \(scores.reduce(0, +) / Float(scores.count))")
    #expect(worst.element >= 0.998, "min cosine \(worst.element) (\(manifest.audio[worst.offset].name))")
    #expect(scores.reduce(0, +) / Float(scores.count) >= 0.9999)
    for row in ours { #expect(abs(norm(row) - 1) < 1e-4) }
}

@Test(
    .enabled(if: modelsBuilt, "models not found: set SONDR_MODELS"),
    arguments: EmbeddingService.ComputeUnits.allCases)
func textEmbeddingsMatchPyTorchOnAllQueries(units: EmbeddingService.ComputeUnits) async throws {
    struct Golden: Decodable {
        struct Query: Decodable { let query: String }
        let queries: [Query]
    }
    let golden = try JSONDecoder().decode(
        Golden.self, from: Data(contentsOf: Fixtures.url("golden/text.json")))
    let reference = try goldenRows("text_embeddings.npy")
    #expect(reference.count == golden.queries.count)

    let service = makeService(units)
    var worst: (Float, String) = (1, "")
    for (query, expected) in zip(golden.queries, reference) {
        let score = cosine(try await service.embed(text: query.query), expected)
        if score < worst.0 { worst = (score, query.query) }
        #expect(score >= 0.9999, "\"\(query.query.prefix(30))\": cosine \(score)")
    }
    print("text parity \(units): n=\(reference.count) min \(worst.0) (\"\(worst.1.prefix(30))\")")
}

@Test(.enabled(if: modelsBuilt, "models not found: set SONDR_MODELS"))
func textEmbeddingIsFastOnceWarm() async throws {
    let service = makeService()
    _ = try await service.embed(text: "warm up")
    let clock = ContinuousClock()
    var times: [Duration] = []
    for query in ["kick", "punchy 808 kick drum", "snare with long reverb tail", "warm analog pad"] {
        var vector: [Float] = []
        times.append(try await clock.measure { vector = try await service.embed(text: query) })
        #expect(vector.count == 512)
    }
    print("text latency warm: \(times.map { $0 / .milliseconds(1) }) ms")
    #expect(times.allSatisfy { $0 < .milliseconds(300) })
}

@Test(.enabled(if: modelsBuilt, "models not found: set SONDR_MODELS"))
func audioBatchResultsDoNotDependOnBatchComposition() async throws {
    let names = ["kick_short.wav", "snare_basic.wav", "pad_slow_attack.wav"]
    let clips = try names.map { try AudioLoader.load(url: Fixtures.url("audio/\($0)")) }
    let service = makeService()
    let together = try await service.embed(audio: clips)
    for (i, clip) in clips.enumerated() {
        let alone = try await service.embed(audio: [clip])
        #expect(cosine(together[i], alone[0]) > 0.999, "\(names[i])")
    }
    #expect(try await service.embed(audio: []).isEmpty)
}

@Test(.enabled(if: modelsBuilt, "models not found: set SONDR_MODELS"))
func audioBatchLargerThanOneModelBatchIsSplit() async throws {
    let clip = try AudioLoader.load(url: Fixtures.url("audio/kick_short.wav"))
    let result = try await makeService().embed(audio: Array(repeating: clip, count: 37))
    #expect(result.count == 37)
    #expect(result.allSatisfy { cosine($0, result[0]) > 0.999 })
}

@Test func embeddingServiceReportsMissingModels() async {
    let service = EmbeddingService(modelsDirectory: URL(fileURLWithPath: "/nonexistent/Models"))
    await #expect(throws: EmbeddingError.self) { try await service.embed(text: "kick") }
    await #expect(throws: EmbeddingError.self) { try await service.embed(audio: [[0, 0]]) }
}

/// `SONDR_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter embeddingBenchmark`
@Test(
    .enabled(if: modelsBuilt && benchmarkEnabled, "set SONDR_BENCH=1 and build Models/"),
    arguments: [EmbeddingService.ComputeUnits.all, .cpuAndGPU, .cpuOnly])
func embeddingBenchmark(units: EmbeddingService.ComputeUnits) async throws {
    let manifest = try JSONDecoder().decode(
        Manifest.self, from: Data(contentsOf: Fixtures.url("golden/manifest.json")))
    let clock = ContinuousClock()
    var clips: [[Float]] = []
    let decode = try clock.measure {
        clips = try manifest.audio.map { try AudioLoader.load(url: Fixtures.url("audio/\($0.name)")) }
    }
    let thousand = (0..<1000).map { clips[$0 % clips.count] }
    let service = makeService(units)
    _ = try await service.embed(audio: Array(thousand.prefix(16)))
    let elapsed = try await clock.measure { _ = try await service.embed(audio: thousand) }
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
    let decodeSeconds = Double(decode.components.seconds) + Double(decode.components.attoseconds) * 1e-18
    print(
        "benchmark \(units): 1000 clips (mel + model) in \(seconds) s = \(1000 / seconds) emb/s; "
            + "decoding \(clips.count) files took \(decodeSeconds) s = \(Double(clips.count) / decodeSeconds) files/s")
}
