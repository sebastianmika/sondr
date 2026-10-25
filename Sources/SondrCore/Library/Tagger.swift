import Foundation

public enum TaggerError: Error, Equatable, LocalizedError {
    case resourceMissing(String)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .resourceMissing(let what): return "Tagger file missing: \(what)"
        case .malformed(let what): return "Tagger file malformed: \(what)"
        }
    }
}

/// Derives tags from a file's path: folder names and file name, split into words, lower-cased,
/// singularised, mapped through an alias table and stripped of stopwords.
///
/// This follows the legacy Python tagger on purpose (see docs/DECISIONS.md for the quirks it
/// keeps), so the golden fixtures in `Tests/Fixtures/golden/tagger.json` apply.
public struct Tagger: Sendable {
    private let aliases: [String: String]
    private let stopwords: Set<String>

    public init(aliases: [String: String], stopwords: Set<String>) {
        self.aliases = aliases
        self.stopwords = stopwords
    }

    /// Loads `aliases.json` and `stopwords.json` from this package's resources.
    public static func bundled() throws -> Tagger {
        func data(_ name: String) throws -> Data {
            guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Tagger"),
                let data = try? Data(contentsOf: url)
            else { throw TaggerError.resourceMissing("\(name).json") }
            return data
        }
        let aliasData = try data("aliases")
        let stopwordData = try data("stopwords")
        guard let aliases = try? JSONDecoder().decode([String: String].self, from: aliasData),
            let stopwords = try? JSONDecoder().decode([String].self, from: stopwordData)
        else { throw TaggerError.malformed("aliases.json or stopwords.json") }
        return Tagger(aliases: aliases, stopwords: Set(stopwords))
    }

    /// Tags for `path` (directory components and file name without extension).
    public func tags(for path: String) -> Set<String> {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init).filter { $0 != "." }
        guard let name = components.last else { return [] }
        let parts = Array(components.dropLast()) + [Self.stem(of: name)]

        var tags = Set<String>()
        for part in parts {
            if let alias = aliases[part.lowercased()] { tags.insert(alias) }
        }
        for part in parts {
            for segment in Self.splitOnSeparators(part) where segment.contains("-") {
                if let tag = normalize(segment.lowercased()) { tags.insert(tag) }
            }
        }
        for part in parts {
            for token in Self.splitToken(part) {
                if let tag = normalize(token) { tags.insert(tag) }
            }
        }
        return tags
    }

    private func normalize(_ raw: String) -> String? {
        var token = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.unicodeScalars.count >= 2 else { return nil }
        if let alias = aliases[token] { return alias }
        token = Singular.of(token)
        if let alias = aliases[token] { return alias }
        return stopwords.contains(token) ? nil : token
    }

    // MARK: Splitting (same as the legacy regexes)

    /// `pathlib.PurePath.stem`: drops the last suffix, but not for names like `.hidden` or `a.`.
    static func stem(of name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex,
            name.index(after: dot) != name.endIndex
        else { return name }
        return String(name[..<dot])
    }

    private static func isSeparator(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || scalar.properties.isWhitespace
    }

    /// `re.split(r"[_\s]+", text)` without the empty pieces.
    static func splitOnSeparators(_ text: String) -> [String] {
        var pieces: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if isSeparator(scalar) {
                if !current.isEmpty { pieces.append(String(current)); current = .init() }
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty { pieces.append(String(current)) }
        return pieces
    }

    private static func isLower(_ s: Unicode.Scalar) -> Bool { s.value >= 97 && s.value <= 122 }
    private static func isUpper(_ s: Unicode.Scalar) -> Bool { s.value >= 65 && s.value <= 90 }
    private static func isDigit(_ s: Unicode.Scalar) -> Bool { s.properties.numericType == .decimal }

    /// Splits on `_`/whitespace, then at lower→Upper, ASCII letter→digit and digit→ASCII letter.
    /// Hyphens stay inside tokens.
    static func splitToken(_ text: String) -> [String] {
        var result: [String] = []
        for piece in splitOnSeparators(text) {
            var current = String.UnicodeScalarView()
            var previous: Unicode.Scalar?
            for scalar in piece.unicodeScalars {
                if let p = previous {
                    let letterBefore = isLower(p) || isUpper(p)
                    let letterNow = isLower(scalar) || isUpper(scalar)
                    if (isLower(p) && isUpper(scalar)) || (letterBefore && isDigit(scalar))
                        || (isDigit(p) && letterNow)
                    {
                        result.append(String(current))
                        current = .init()
                    }
                }
                current.append(scalar)
                previous = scalar
            }
            if !current.isEmpty { result.append(String(current)) }
        }
        return result
    }
}

/// Small rule-based English singulariser, standing in for Python's `inflect`.
enum Singular {
    private static let irregular: [String: String] = [
        "buses": "bus", "gases": "gas", "men": "man", "women": "woman", "children": "child",
        "feet": "foot", "teeth": "tooth", "mice": "mouse",
    ]
    private static let unchanged: Set<String> = [
        "bus", "gas", "chorus", "bonus", "plus", "focus", "this", "his", "was", "has", "its",
        "less", "mass", "bass", "glass", "class", "boss", "kiss", "cross", "dross", "analysis",
        "basis", "axis", "oasis", "synthesis", "emphasis", "hypnosis",
    ]

    static func of(_ word: String) -> String {
        if let known = irregular[word] { return known }
        if unchanged.contains(word) { return word }
        let count = word.unicodeScalars.count
        guard count >= 4, word.hasSuffix("s") else { return word }
        if word.hasSuffix("ss") || word.hasSuffix("us") || word.hasSuffix("is") { return word }
        if word.hasSuffix("ies"), count > 4 { return String(word.dropLast(3)) + "y" }
        for suffix in ["sses", "xes", "ches", "shes", "zzes"] where word.hasSuffix(suffix) {
            return String(word.dropLast(2))
        }
        return String(word.dropLast())
    }
}
