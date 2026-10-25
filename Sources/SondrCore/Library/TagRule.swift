import Foundation

public enum TagRuleError: Error, Equatable, LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let why): return why
        }
    }
}

/// One entry of a tag blacklist. Matched against the final tag (lower case, after aliases and
/// singularising), ignoring case.
public struct TagRule: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// The tag equals the pattern.
        case text
        /// `*` is any run of characters, `?` one character; everything else is literal.
        case glob
        /// A regular expression that must match the whole tag.
        case regex
    }

    public var kind: Kind
    public var pattern: String

    public init(kind: Kind, pattern: String) {
        self.kind = kind
        self.pattern = pattern
    }

    /// Why this rule cannot be used, or `nil` when it is fine.
    public var validationMessage: String? {
        do {
            _ = try TagRuleSet([self])
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Storage as JSON text (a database column or a `meta` value)

    public static func encode(_ rules: [TagRule]) throws -> String {
        let data = try JSONEncoder().encode(rules)
        return String(decoding: data, as: UTF8.self)
    }

    /// `nil` or empty text means no rules.
    public static func decode(_ text: String?) throws -> [TagRule] {
        guard let text, !text.isEmpty else { return [] }
        return try JSONDecoder().decode([TagRule].self, from: Data(text.utf8))
    }
}

/// Rules compiled once, to be applied to many tags.
public struct TagRuleSet: Sendable {
    private struct Compiled: @unchecked Sendable {
        let rule: TagRule
        let text: String?
        let expression: NSRegularExpression?
    }
    private let compiled: [Compiled]

    /// - Throws: ``TagRuleError/invalid(_:)`` for an empty pattern or a regex that does not compile.
    public init(_ rules: [TagRule]) throws {
        compiled = try rules.map { rule in
            let pattern = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pattern.isEmpty else { throw TagRuleError.invalid("A rule needs a pattern.") }
            switch rule.kind {
            case .text:
                return Compiled(rule: rule, text: pattern.lowercased(), expression: nil)
            case .glob:
                return Compiled(rule: rule, text: nil, expression: try Self.expression(Self.regex(fromGlob: pattern)))
            case .regex:
                return Compiled(rule: rule, text: nil, expression: try Self.expression(pattern))
            }
        }
    }

    public func blocks(_ tag: String) -> Bool { firstMatch(for: tag) != nil }

    /// The first rule that matches `tag`, for showing why a tag is hidden.
    public func firstMatch(for tag: String) -> TagRule? {
        let range = NSRange(tag.startIndex..., in: tag)
        for item in compiled {
            if let text = item.text {
                if tag.lowercased() == text { return item.rule }
            } else if let expression = item.expression, expression.firstMatch(in: tag, range: range) != nil {
                return item.rule
            }
        }
        return nil
    }

    private static func expression(_ pattern: String) throws -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: "^(?:\(pattern))$", options: [.caseInsensitive])
        } catch {
            throw TagRuleError.invalid("“\(pattern)” is not a valid regular expression.")
        }
    }

    private static func regex(fromGlob glob: String) -> String {
        glob.map { character -> String in
            switch character {
            case "*": return ".*"
            case "?": return "."
            default: return NSRegularExpression.escapedPattern(for: String(character))
            }
        }.joined()
    }
}
