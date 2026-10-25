import Foundation

public enum ClapTokenizerError: Error, Equatable, LocalizedError {
    case resourceMissing(String)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .resourceMissing(let what): return "Tokenizer file missing: \(what)"
        case .malformed(let what): return "Tokenizer file malformed: \(what)"
        }
    }
}

/// Byte-level BPE tokenizer of CLAP's text tower (`RobertaTokenizer`, laion/clap-htsat-unfused).
///
/// Produces the same ids as Hugging Face for `tokenizer(text, truncation=True)`: `<s>` + tokens +
/// `</s>`, at most ``maxLength`` ids. Literal special-token strings in the text (`<s>`, `</s>`,
/// `<pad>`, `<unk>`, `<mask>`) map to their ids as in HF; `<mask>` also swallows the whitespace
/// to its left. `vocab.json` and `merges.txt` are copied from the HF model snapshot
/// `8fa0f1c6d0433df6e97c127f64b2a1d6c0dcda8a`.
public struct ClapTokenizer: Sendable {
    public static let maxLength = 512
    static let beginID: Int32 = 0
    static let endID: Int32 = 2

    private struct Pair: Hashable {
        let left: String
        let right: String
    }

    private static let specialTokens: [String: Int32] = [
        "<s>": 0, "<pad>": 1, "</s>": 2, "<unk>": 3, "<mask>": 50264,
    ]
    private static let leftStrippedSpecials: Set<String> = ["<mask>"]

    private let vocab: [String: Int32]
    private let ranks: [Pair: Int]
    private let byteToChar: [String]
    private let unknownID: Int32

    /// Loads the tokenizer files shipped in this package's resources.
    public static func bundled() throws -> ClapTokenizer {
        func url(_ name: String) throws -> URL {
            guard
                let found = Bundle.module.url(
                    forResource: name, withExtension: nil, subdirectory: "ClapTokenizer")
            else { throw ClapTokenizerError.resourceMissing(name) }
            return found
        }
        return try ClapTokenizer(vocabURL: url("vocab.json"), mergesURL: url("merges.txt"))
    }

    public init(vocabURL: URL, mergesURL: URL) throws {
        let vocabData: Data
        let mergesText: String
        do {
            vocabData = try Data(contentsOf: vocabURL)
            mergesText = try String(contentsOf: mergesURL, encoding: .utf8)
        } catch {
            throw ClapTokenizerError.resourceMissing(error.localizedDescription)
        }
        guard let raw = try? JSONSerialization.jsonObject(with: vocabData) as? [String: Int] else {
            throw ClapTokenizerError.malformed("vocab.json is not a string-to-int map")
        }
        vocab = raw.mapValues { Int32($0) }
        unknownID = Self.specialTokens["<unk>"]!

        var ranks: [Pair: Int] = [:]
        for line in mergesText.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("#version") { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw ClapTokenizerError.malformed("merge line '\(line)'") }
            ranks[Pair(left: String(parts[0]), right: String(parts[1]))] = ranks.count
        }
        self.ranks = ranks
        byteToChar = Self.makeByteToChar()
    }

    /// Token ids for `text`, including `<s>` and `</s>`, truncated to ``maxLength``.
    public func encode(_ text: String) -> [Int32] {
        var content: [Int32] = []
        for piece in Self.splitOnSpecialTokens(text) {
            switch piece {
            case .special(let id): content.append(id)
            case .text(let string): content += encodeText(string)
            }
        }
        if content.count > Self.maxLength - 2 { content.removeSubrange((Self.maxLength - 2)...) }
        return [Self.beginID] + content + [Self.endID]
    }

    // MARK: Pre-tokenisation and BPE

    private enum Piece {
        case text(String)
        case special(Int32)
    }

    /// Splits around special-token strings like HF's added tokens. Whitespace before `<mask>` is dropped.
    private static func splitOnSpecialTokens(_ text: String) -> [Piece] {
        var pieces: [Piece] = []
        var rest = Substring(text)
        while true {
            var next: (range: Range<Substring.Index>, token: String)?
            for token in specialTokens.keys {
                if let range = rest.range(of: token),
                    next == nil || range.lowerBound < next!.range.lowerBound
                {
                    next = (range, token)
                }
            }
            guard let hit = next else { break }
            var before = rest[..<hit.range.lowerBound]
            if leftStrippedSpecials.contains(hit.token) {
                while let last = before.last, last.isWhitespace { before = before.dropLast() }
            }
            if !before.isEmpty { pieces.append(.text(String(before))) }
            pieces.append(.special(specialTokens[hit.token]!))
            rest = rest[hit.range.upperBound...]
        }
        if !rest.isEmpty { pieces.append(.text(String(rest))) }
        return pieces
    }

    /// GPT-2 / RoBERTa pre-tokenisation pattern.
    private nonisolated(unsafe) static let pattern = try! Regex(
        #"'s|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+"#
    ).matchingSemantics(.unicodeScalar)

    private func encodeText(_ text: String) -> [Int32] {
        var ids: [Int32] = []
        for match in text.matches(of: Self.pattern) {
            let word = text[match.range].utf8.map { byteToChar[Int($0)] }
            for token in bpe(word) { ids.append(vocab[token] ?? unknownID) }
        }
        return ids
    }

    /// Repeatedly merges the lowest-ranked adjacent pair, as in GPT-2's `bpe()`.
    private func bpe(_ symbols: [String]) -> [String] {
        var word = symbols
        while word.count > 1 {
            var best: (rank: Int, pair: Pair)?
            for i in 0..<(word.count - 1) {
                let pair = Pair(left: word[i], right: word[i + 1])
                if let rank = ranks[pair], best == nil || rank < best!.rank { best = (rank, pair) }
            }
            guard let merge = best?.pair else { break }
            var merged: [String] = []
            var i = 0
            while i < word.count {
                if i < word.count - 1, word[i] == merge.left, word[i + 1] == merge.right {
                    merged.append(merge.left + merge.right)
                    i += 2
                } else {
                    merged.append(word[i])
                    i += 1
                }
            }
            word = merged
        }
        return word
    }

    /// GPT-2's reversible byte to printable-character map.
    private static func makeByteToChar() -> [String] {
        var printable = Array(0x21...0x7E) + Array(0xA1...0xAC) + Array(0xAE...0xFF)
        var chars = printable
        var extra = 0
        for byte in 0..<256 where !printable.contains(byte) {
            printable.append(byte)
            chars.append(256 + extra)
            extra += 1
        }
        var table = [String](repeating: "", count: 256)
        for (byte, char) in zip(printable, chars) { table[byte] = String(UnicodeScalar(char)!) }
        return table
    }
}
