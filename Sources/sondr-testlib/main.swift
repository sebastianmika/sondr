import Foundation
import SondrCore

// Usage: sondr-testlib <count> <folder> [seed]
// Writes <count> tiny WAV files into <folder>. Output depends only on count and seed.
// The --db/--fake/--clustered/--map flags come with the index and map phases.

let arguments = Array(CommandLine.arguments.dropFirst())
guard (2...3).contains(arguments.count), let count = Int(arguments[0]), count > 0,
    let seed = arguments.count == 3 ? UInt64(arguments[2]) : 1
else {
    FileHandle.standardError.write(Data("usage: sondr-testlib <count> <folder> [seed]\n".utf8))
    exit(2)
}
let folder = URL(fileURLWithPath: arguments[1])
let elapsed = try ContinuousClock().measure {
    try TestLibraryGenerator.generate(count: count, into: folder, seed: seed)
}
print("wrote \(count) files to \(folder.path) in \(elapsed)")
