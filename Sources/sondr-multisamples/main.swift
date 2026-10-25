import Foundation
import SondrCore

// Usage: swift run -c release sondr-multisamples <library folder> [--all] [--series]
// Prints the multisample groups that file names suggest, and how their file metadata (root note)
// compares. Read-only; no database. --all also lists every member; --series lists the numbered series that were not accepted.

let arguments = Array(CommandLine.arguments.dropFirst())
guard let folder = arguments.first(where: { !$0.hasPrefix("--") }) else {
    FileHandle.standardError.write(Data("usage: sondr-multisamples <folder> [--all] [--series]\n".utf8))
    exit(2)
}
let listAll = arguments.contains("--all")
let listSeries = arguments.contains("--series")
let root = URL(fileURLWithPath: folder).resolvingSymlinksInPath()
let enumerator = FileManager.default.enumerator(
    at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])
var files: [URL] = []
while let url = enumerator?.nextObject() as? URL {
    if LibraryScanner.defaultExtensions.contains(url.pathExtension.lowercased()) { files.append(url.resolvingSymlinksInPath()) }
}
let relative = files.map { String($0.path.dropFirst(root.path.count)).trimmingPrefix("/").description }
let groups = MultisampleNames.groups(paths: relative)

func rootNote(_ path: String) -> Int? { AudioRootNote.read(from: root.appendingPathComponent(path)) }

/// Metadata root note against the pitch from the name: equal, shifted by whole octaves, or unrelated.
/// A few files off the common shift are reported as outliers, not as a disagreement.
func metadataVerdict(_ group: MultisampleNames.Group) -> String {
    let pairs = group.members.compactMap { member in rootNote(member.path).map { (note: $0, midi: member.midi, path: member.path) } }
    guard !pairs.isEmpty else { return "no metadata" }
    let coverage = "\(pairs.count)/\(group.members.count)"
    if Set(pairs.map(\.note)).count == 1, Set(pairs.map(\.midi)).count > 1 { return "metadata uninformative (all root note \(pairs[0].note), \(coverage))" }
    let counts = Dictionary(grouping: pairs) { $0.note - $0.midi }.mapValues(\.count)
    guard let (offset, count) = counts.max(by: { $0.value < $1.value }), offset % 12 == 0, count * 10 >= pairs.count * 9 else {
        return "metadata DISAGREES (\(coverage))"
    }
    let outliers = pairs.filter { $0.note - $0.midi != offset }
    let base = offset == 0 ? "metadata agrees" : "metadata shifted \(offset / 12) octaves"
    return outliers.isEmpty ? "\(base) (\(coverage))" : "\(base) (\(coverage), \(outliers.count) outliers: \(outliers.map { URL(fileURLWithPath: $0.path).lastPathComponent }.joined(separator: ", ")))"
}

func label(_ member: MultisampleNames.Member) -> String { member.label ?? MultisampleNames.noteLabel(member.midi) }

func describe(_ group: MultisampleNames.Group, verdict: String) {
    let pitches = group.pitches
    let range = "\(label(group.members.first!))–\(label(group.members.last!))"
    print("\(group.folder.isEmpty ? "." : group.folder)/  \(group.key)  [\(group.kind.rawValue)]  \(group.members.count) files, \(pitches.count) pitches \(range)  \(verdict)")
    if listAll { for member in group.members { print("    \(label(member))  \(member.path)") } }
}

var confirmed: [MultisampleNames.Group] = []
var series: [MultisampleNames.Group] = []
for group in groups {
    if group.kind == .note || MultisampleNames.isBackedByMetadata(group, rootNotes: group.members.map { rootNote($0.path) }) { confirmed.append(group) } else { series.append(group) }
}
for group in confirmed { describe(group, verdict: metadataVerdict(group)) }
print("\(confirmed.count) multisample groups, \(confirmed.reduce(0) { $0 + $1.members.count }) of \(files.count) files; "
    + "\(confirmed.filter { $0.kind == .note && !metadataVerdict($0).hasPrefix("metadata agrees") && !metadataVerdict($0).hasPrefix("metadata shifted") }.count) note groups without usable metadata")
print("\(series.count) numbered series ignored (numbers without matching root notes)")
if listSeries {
    print("\nNumbered series:")
    for group in series { describe(group, verdict: metadataVerdict(group)) }
}
