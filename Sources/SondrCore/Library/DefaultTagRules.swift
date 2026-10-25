import Foundation

/// Built-in blacklist for tags that are noise in every library: track numbers, number pairs and
/// note names. Applies to path-derived tags only, always, in addition to the user's rules.
/// Longer numbers (808, 2020) and keys such as `am` or bare `db` stay.
enum DefaultTagRules {
    static let rules: [TagRule] = [
        #"\d{1,2}\.?"#,  // 01, 7, 12.
        #"\d+([-._]\d+)+"#,  // 01-02, 3.5, 1_2
        #"[a-g]#-?\d?"#,  // f#, c#3
        #"[a-g][#b]?-?\d"#,  // c3, c-3, eb2
    ].map { TagRule(kind: .regex, pattern: $0) }

    // The patterns are constants covered by tests, so compiling cannot fail.
    static let set: TagRuleSet = try! TagRuleSet(rules)
}
