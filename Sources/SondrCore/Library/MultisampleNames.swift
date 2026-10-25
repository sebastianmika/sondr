import Foundation

/// Finds multisamples (one instrument sampled at several pitches) from file names alone.
///
/// A pitch token is a note name with octave (`C3`, `F#2`, `Db-1`: strong) or a MIDI number 0-127
/// standing alone in the name (`Piano_61`: weak). Files in one folder whose names are equal apart from
/// that token form a candidate group. `midi` numbers octaves with C4 = 60; other tools use C3 = 60, which
/// only shifts all pitches of a group by the same amount, so show ``Member/label`` rather than the number.
public enum MultisampleNames {
    public enum Kind: String, Sendable, Comparable {
        case number, note

        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs == .number && rhs == .note }
    }

    public struct Parsed: Equatable, Sendable {
        /// The name with the pitch token replaced by `{p}` and layer tokens removed, lowercased.
        public let key: String
        public let midi: Int
        public let kind: Kind
        /// Velocity or round-robin token such as `v2`, `rr3` or a take number after a note name (`_0002`).
        public let layer: String?
        /// The note as the file names it (`C3`, `F#2`), whatever octave convention the pack uses.
        /// Nil for number tokens.
        public let label: String?
    }

    public struct Member: Equatable, Sendable {
        public let path: String
        public let midi: Int
        public let layer: String?
        public let label: String?
    }

    public struct Group: Equatable, Sendable {
        /// Folder relative to the library root; empty for the root itself.
        public let folder: String
        public let key: String
        public let kind: Kind
        /// Sorted by pitch, then path.
        public let members: [Member]

        public var pitches: [Int] { Array(Set(members.map(\.midi))).sorted() }
    }

    /// Fewest distinct pitches that make a group; two files are more likely `Kick 1` and `Kick 2`.
    public static let minimumPitches = 3

    private static let noteName = regex("(?<![A-Za-z0-9#])([A-Ga-g])([#b]?)(-?[0-9])(?![A-Za-z0-9])")
    private static let number = regex("(?<![A-Za-z0-9])([0-9]{1,3})(?![A-Za-z0-9])(?!\\s*bpm)")
    private static let layerToken = regex("(?<![A-Za-z0-9])((?:v|vel|rr)[0-9]+)(?![A-Za-z0-9])", options: .caseInsensitive)
    /// A pack's per-file id after the note (`C#2-ASAU`): a hyphen and four capitals or digits at the end.
    private static let idSuffix = regex("^-[A-Z0-9]{4}$")
    private static let takeSuffix = regex("^[ _.-]*[0-9]{3,4}$")
    private static let semitones: [Character: Int] = ["c": 0, "d": 2, "e": 4, "f": 5, "g": 7, "a": 9, "b": 11]

    private static func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // Patterns are literals in this file.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    /// The pitch in a file name (without extension), or nil when it has no usable pitch token.
    ///
    /// - Parameter pitchNumbers: Note numbers from the file's metadata (see ``AudioRootNote/pitchNumbers(from:)``),
    ///   called only for names with a note token. A number in a name that is one of them is the pitch's index
    ///   (`45 Lead C2`), not part of the instrument name, and is left out of the key. A trailing `-XXXX` id
    ///   after the note is left out as well.
    public static func parse(stem: String, pitchNumbers: () -> Set<Int> = { [] }) -> Parsed? {
        let layer = groups(of: layerToken, in: stem).last.map { $0.text.lowercased() }
        let name = layerToken.stringByReplacingMatches(
            in: stem, range: NSRange(stem.startIndex..., in: stem), withTemplate: "")

        if let match = groups(of: noteName, in: name).last {
            let letter = Character(match.captures[0].lowercased())
            let accidental = match.captures[1] == "#" ? 1 : match.captures[1] == "b" ? -1 : 0
            let octave = Int(match.captures[2]) ?? 0
            let midi = 12 * (octave + 1) + (semitones[letter] ?? 0) + accidental
            guard (0...127).contains(midi) else { return nil }
            var key = name.replacingCharacters(in: match.range, with: "{p}")
            let tail = String(name[match.range.upperBound...])
            var take: String?
            if takeSuffix.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)) != nil {
                take = tail.trimmingCharacters(in: CharacterSet(charactersIn: " _.-"))
                key = key.replacingOccurrences(of: "[ _.-]*[0-9]{3,4}$", with: "", options: .regularExpression)
            } else if idSuffix.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)) != nil {
                take = String(tail.dropFirst())
                key = String(key.dropLast(tail.count))
            }
            key = removingPitchIndex(from: key, numbers: pitchNumbers())
            let label = "\(match.captures[0].uppercased())\(match.captures[1])\(match.captures[2])"
            return Parsed(key: normalised(key), midi: midi, kind: .note, layer: layer ?? take, label: label)
        }
        guard let match = groups(of: number, in: name).last, let midi = Int(match.captures[0]), midi <= 127 else { return nil }
        return Parsed(key: normalised(name.replacingCharacters(in: match.range, with: "{p}")), midi: midi, kind: .number, layer: layer, label: nil)
    }

    private static func removingPitchIndex(from key: String, numbers: Set<Int>) -> String {
        guard !numbers.isEmpty else { return key }
        var result = key
        for match in groups(of: number, in: key).reversed() {
            if let value = Int(match.captures[0]), numbers.contains(value) {
                result.replaceSubrange(match.range, with: "")
            }
        }
        return result
    }

    private struct Match {
        let text: String
        let captures: [String]
        let range: Range<String.Index>
    }

    private static func groups(of expression: NSRegularExpression, in text: String) -> [Match] {
        expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { result in
            guard let range = Range(result.range, in: text) else { return nil }
            let captures = (1..<result.numberOfRanges).map { index in
                Range(result.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
            return Match(text: String(text[range]), captures: captures, range: range)
        }
    }

    /// Candidate groups among `paths` (relative to the library root), in folder and key order.
    ///
    /// - Parameter pitchNumbers: Note numbers from the metadata of the file at a path; see ``parse(stem:pitchNumbers:)``.
    public static func groups(paths: [String], pitchNumbers: (String) -> Set<Int> = { _ in [] }) -> [Group] {
        struct Bucket: Hashable {
            let folder: String
            let key: String
            let kind: Kind
        }
        var buckets: [Bucket: [Member]] = [:]
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let stem = url.deletingPathExtension().lastPathComponent
            guard let parsed = parse(stem: stem, pitchNumbers: { pitchNumbers(path) }) else { continue }
            let folder = (path as NSString).deletingLastPathComponent
            buckets[Bucket(folder: folder, key: parsed.key, kind: parsed.kind), default: []]
                .append(Member(path: path, midi: parsed.midi, layer: parsed.layer, label: parsed.label))
        }
        return buckets
            .filter { Set($0.value.map(\.midi)).count >= minimumPitches }
            .map { bucket, members in
                Group(
                    folder: bucket.folder, key: bucket.key, kind: bucket.kind,
                    members: members.sorted { ($0.midi, $0.path) < ($1.midi, $1.path) })
            }
            .sorted { ($0.folder, $0.key, $0.kind) < ($1.folder, $1.key, $1.kind) }
    }

    /// Whether root notes from file metadata show that a number group's numbers really are pitches:
    /// at least ``minimumPitches`` distinct pitches carry a note, and all differ from the number by the
    /// same whole number of octaves. Bare numbers are often just an index (`Decay 01..08`), so a number
    /// group is only a multisample when this holds. Note groups need no confirmation.
    public static func isConfirmed(_ group: Group, rootNote: (String) -> Int?) -> Bool {
        guard group.kind == .number else { return true }
        let pairs = group.members.compactMap { member in rootNote(member.path).map { ($0, member.midi) } }
        let offsets = Set(pairs.map { $0.0 - $0.1 })
        return Set(pairs.map(\.1)).count >= minimumPitches && offsets.count == 1 && (offsets.first ?? 1) % 12 == 0
    }

    /// Whether root notes from file metadata back up the pitches from the names: at least
    /// ``minimumPitches`` distinct pitches carry a note, the notes are not all the same placeholder, and
    /// at least 90% of them differ from the name's pitch by one and the same whole number of octaves.
    ///
    /// Also backed: a pack that skips a number in its names (`-81`, `-83`) while the notes stay consecutive.
    /// Then the notes rise with the names, each pitch has one note, the first file's note is the name's pitch
    /// up to whole octaves, and the difference only ever shrinks (a skipped name makes it drop, never rise).
    /// `rootNotes` runs parallel to `group.members`, nil where a file has none.
    public static func isBackedByMetadata(_ group: Group, rootNotes: [Int?]) -> Bool {
        let pairs = zip(group.members, rootNotes).compactMap { member, note in note.map { (note: $0, midi: member.midi) } }
        guard Set(pairs.map(\.midi)).count >= minimumPitches, Set(pairs.map(\.note)).count > 1 else { return false }
        let counts = Dictionary(grouping: pairs) { $0.note - $0.midi }.mapValues(\.count)
        if let (offset, count) = counts.max(by: { $0.value < $1.value }), offset % 12 == 0, count * 10 >= pairs.count * 9 {
            return true
        }
        return pairs.count * 10 >= group.members.count * 9 && followsSkippedNumbers(pairs)
    }

    /// `pairs` come sorted by pitch (see ``Group/members``).
    private static func followsSkippedNumbers(_ pairs: [(note: Int, midi: Int)]) -> Bool {
        let byPitch = Dictionary(grouping: pairs, by: \.midi)
        let pitches = byPitch.keys.sorted()
        let notes = pitches.map { Set(byPitch[$0]!.map(\.note)) }
        guard notes.allSatisfy({ $0.count == 1 }) else { return false }
        let offsets = zip(pitches, notes).map { $1.first! - $0 }
        guard offsets[0] % 12 == 0 else { return false }
        let risingNotes = zip(notes, notes.dropFirst()).allSatisfy { $0.first! < $1.first! }
        return risingNotes && zip(offsets, offsets.dropFirst()).allSatisfy { $0 >= $1 }
    }

    /// `C4` for 60, `F#3` for 54.
    public static func noteLabel(_ midi: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return "\(names[midi % 12])\(midi / 12 - 1)"
    }

    /// A ``PitchLabel`` for `LibraryScanner`: the root note of the file (`C3`) when its stem names no pitch.
    public static let scannerPitchLabel: PitchLabel = { stem, url in
        parse(stem: stem) == nil ? AudioRootNote.read(from: url).map(noteLabel) : nil
    }

    private static func normalised(_ key: String) -> String {
        let separators = CharacterSet(charactersIn: " _-.")
        let collapsed = key.lowercased().replacingOccurrences(of: "[ _.-]{2,}", with: "_", options: .regularExpression)
        return collapsed.trimmingCharacters(in: separators)
    }
}
