import Foundation

public enum PredicateCompletions {

    /// Return candidate completions for a partial word, case-insensitive
    /// prefix-matched against the union of PredicateContext.exposedKeys
    /// and PredicateLexer.keywords. Identifiers come first (sorted),
    /// then keywords (sorted). Original case of each source is preserved.
    public static func candidates(forPartialWord partial: String) -> [String] {
        let needle = partial.lowercased()
        let identifiers = PredicateContext.exposedKeys
            .filter { needle.isEmpty || $0.lowercased().hasPrefix(needle) }
            .sorted()
        let keywords = PredicateLexer.keywords
            .filter { needle.isEmpty || $0.lowercased().hasPrefix(needle) }
            .sorted()
        return identifiers + keywords
    }
}
