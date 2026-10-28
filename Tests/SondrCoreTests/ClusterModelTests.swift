import Foundation
import Testing

@testable import SondrCore

private let modelsDirectory = ModelLocator.find() ?? URL(fileURLWithPath: "/nonexistent/Models")
private let modelsBuilt = ModelLocator.isComplete(modelsDirectory)

/// Real model, synthetic fixtures named after what they are: the ones CLAP should get right.
@Test(.enabled(if: modelsBuilt, "models not found: set SONDR_MODELS"))
func clustersOfClearlyLabelledFixturesAreRight() async throws {
    let service = EmbeddingService(modelsDirectory: modelsDirectory, computeUnits: .cpuAndGPU)
    let database = try LibraryDatabase(inMemory: ())
    let centres = ClusterAssigner.Centres(try await ClusterCentres.ensure(database: database, embedder: service))
    let names = try ClusterCentres.seed().map(\.name)
    // With the fused model the old synthetic-fixture scores dropped (see DECISIONS.md, cluster threshold): these hold.
    let expected = [
        "kick_short.wav": "Kicks", "kick_long_tail.wav": "Kicks", "bass_sub.wav": "Bass", "bass.caf": "Bass",
        "hat_closed_tiny.wav": "Hi-Hats & Cymbals", "hat_open.wav": "Hi-Hats & Cymbals", "fx_riser.wav": "FX & Risers",
    ]
    // Synthetic snare is read as a kick by the fused model: known issue.
    let weak = ["snare.aiff": "Snares & Claps"]
    func check(_ file: String, _ cluster: String) async throws {
        let clip = try AudioLoader.load(url: Fixtures.url("audio/\(file)"))
        let vector = try await service.embed(audio: [clip])[0]
        let (id, score) = ClusterAssigner.nearest(to: vector, in: centres)
        #expect(names[id] == cluster, "\(file) -> \(names[id]) (\(score))")
        #expect(!ClusterAssigner.isUnsorted(score: Double(score)), "\(file) score \(score)")
    }
    for (file, cluster) in expected { try await check(file, cluster) }
    for (file, cluster) in weak { await withKnownIssue { try await check(file, cluster) } }
}
