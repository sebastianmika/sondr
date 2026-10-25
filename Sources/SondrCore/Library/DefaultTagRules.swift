import Foundation

/// The initial "Ignored tags (all locations)" rules: track numbers, number pairs and note names are
/// noise in every library. They are ordinary global rules from the start, so the user can edit or
/// delete them; see ``TaggingStore/load(_:)``. Longer numbers (808, 2020) and keys such as `am` or
/// bare `db` stay.
enum DefaultTagRules {
    static let rules: [TagRule] = [
        #"\d{1,2}\.?"#,  // 01, 7, 12.
        #"\d+([-._]\d+)+"#,  // 01-02, 3.5, 1_2
        #"[a-g]#-?\d?"#,  // f#, c#3
        #"[a-g][#b]?-?\d"#,  // c3, c-3, eb2
    ].map { TagRule(kind: .regex, pattern: $0) }
}
