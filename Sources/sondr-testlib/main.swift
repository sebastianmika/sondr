import Foundation
import SondrCore

// Usage: sondr-testlib <count> <folder> [seed] [--db <file> --fake [--clustered] [--map]]
// Writes <count> tiny WAV files into <folder>. Output depends only on count and seed.
// --db        also scans and indexes them into that library file (never your real library)
// --fake      index with made-up 512-d vectors instead of the Core ML models (needed with --db)
// --clustered the made-up vectors fall into 8 groups instead of being unrelated
// --map       also build and keep the 2D map (the settings are not saved anywhere)

/// Stand-in for the Core ML model: a vector per clip, near one of 8 cluster centres if `clustered`.
struct FakeEmbedder: Embedder {
    var clustered: Bool

    // The real version string, so the vectors look current to the app.
    func modelVersion() async throws -> String { "laion/clap-htsat-fused@365dea6e-afp16-tfp32-v1" }
    func embed(text: String) async throws -> [Float] { vector(seed: UInt64(text.utf8.count) + 1, cluster: nil) }

    func embed(audio clips: [[Float]]) async throws -> [[Float]] {
        clips.map { clip in
            let seed = clip.prefix(4000).enumerated().reduce(UInt64(7)) {
                $0 &* 31 &+ UInt64(Int(min(abs($1.element), 1) * 1000) + $1.offset)
            }
            return vector(seed: seed, cluster: clustered ? Int((seed >> 8) % 8) : nil)
        }
    }

    private func vector(seed: UInt64, cluster: Int?) -> [Float] {
        func next(_ state: inout UInt64) -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state >> 11) % 2000 - 1000) / 1000
        }
        var centre = (UInt64(cluster ?? 0) + 1) &* 0x9E37_79B9_7F4A_7C15 | 1
        var noise = seed | 1
        let v = (0..<512).map { _ in (cluster == nil ? 0 : next(&centre) * 3) + next(&noise) * (cluster == nil ? 1 : 0.35) }
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return v.map { $0 / norm }
    }
}

var arguments = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String, _ arguments: inout [String]) -> Bool {
    guard let i = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: i)
    return true
}
func option(_ name: String, _ arguments: inout [String]) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    defer { arguments.removeSubrange(i...(i + 1)) }
    return arguments[i + 1]
}
let dbPath = option("--db", &arguments)
let fake = flag("--fake", &arguments), clustered = flag("--clustered", &arguments), buildMap = flag("--map", &arguments)

guard (2...3).contains(arguments.count), let count = Int(arguments[0]), count > 0,
    let seed = arguments.count == 3 ? UInt64(arguments[2]) : 1, dbPath != nil || !(fake || clustered || buildMap),
    dbPath == nil || fake
else {
    FileHandle.standardError.write(
        Data("usage: sondr-testlib <count> <folder> [seed] [--db <file> --fake [--clustered] [--map]]\n".utf8))
    exit(2)
}
let folder = URL(fileURLWithPath: arguments[1])
let elapsed = try ContinuousClock().measure {
    try TestLibraryGenerator.generate(count: count, into: folder, seed: seed)
}
print("wrote \(count) files to \(folder.path) in \(elapsed)")

if let dbPath {
    let app = await AppModel(
        databaseURL: URL(fileURLWithPath: dbPath), modelsDirectory: nil, embedder: FakeEmbedder(clustered: clustered),
        mapSettings: MapSettingsStore(load: { MapParameters() }, save: { _ in }))
    await app.start()
    await app.addLocation(folder)
    await app.startIndexing()
    if buildMap, let map = await app.map {
        await map.beginTuning()
        await map.requestPreview()
        await map.waitForPreview()
        await map.keep()
        print("map: \(await map.current?.pointCount ?? 0) points")
    }
    print("library: \(await app.stats.samples) samples at \(dbPath)")
}
