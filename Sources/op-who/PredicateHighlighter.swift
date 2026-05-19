import AppKit
import OpWhoLib

/// `NSTextStorageDelegate` that lexes the predicate editor's content
/// after every edit and applies foreground-colour attributes per token.
/// Identifiers not in the known-keys list also get an orange underline
/// as a soft "this won't bind to anything" hint — they're not syntax
/// errors (NSPredicate will happily parse them) but they evaluate to
/// nil at runtime, which is almost never what the user wanted.
///
/// Re-highlights the whole storage on every edit because predicate
/// strings are short (one to a few lines). Incremental highlighting
/// would add complexity nobody can see.
final class PredicateHighlighter: NSObject, NSTextStorageDelegate {

    private let knownKeys: Set<String>

    init(knownKeys: [String]) {
        self.knownKeys = Set(knownKeys)
        super.init()
    }

    /// Install on `textView`'s storage and run the initial pass so the
    /// content shows colours before the user types anything.
    func install(on textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        storage.delegate = self
        applyHighlight(to: storage)
    }

    /// AppKit fires this for both `.editedCharacters` (text changed)
    /// and `.editedAttributes` (only attributes changed). We only want
    /// the first one — otherwise our own `addAttributes` call below
    /// would re-fire us into infinite recursion.
    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        applyHighlight(to: textStorage)
    }

    private func applyHighlight(to storage: NSTextStorage) {
        let full = NSRange(location: 0, length: storage.length)
        let source = storage.string
        let tokens = PredicateLexer.tokenize(source)

        storage.beginEditing()
        storage.removeAttribute(.foregroundColor, range: full)
        storage.removeAttribute(.underlineStyle, range: full)
        storage.removeAttribute(.underlineColor, range: full)
        // Reset the base colour so any text not covered by a token
        // (shouldn't happen, but be defensive) renders in the system
        // foreground.
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)

        for token in tokens {
            let attrs = attributes(for: token)
            storage.addAttributes(attrs, range: token.range)
        }
        storage.endEditing()
    }

    private func attributes(for token: PredicateToken) -> [NSAttributedString.Key: Any] {
        switch token.kind {
        case .keyword:
            return [.foregroundColor: NSColor.systemBlue]
        case .stringLiteral:
            return [.foregroundColor: NSColor.systemBrown]
        case .numberLiteral:
            return [.foregroundColor: NSColor.systemPurple]
        case .operator, .punctuation:
            return [.foregroundColor: NSColor.secondaryLabelColor]
        case .identifier:
            if isKnownKey(token.text) {
                return [.foregroundColor: NSColor.labelColor]
            }
            return [
                .foregroundColor: NSColor.systemOrange,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: NSColor.systemOrange,
            ]
        case .unknown:
            return [
                .foregroundColor: NSColor.systemRed,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: NSColor.systemRed,
            ]
        }
    }

    /// An identifier is "known" when its top-level keypath component is
    /// one of `PredicateContext.exposedKeys`. NSPredicate's collection
    /// operators (`@count`, `@sum`, `@avg`, …) are accepted because
    /// they're not user-defined keys — they always resolve. A leading
    /// `$` denotes a SUBQUERY-bound variable; also accept.
    private func isKnownKey(_ text: String) -> Bool {
        let root = text.split(separator: ".").first.map(String.init) ?? text
        if root.hasPrefix("@") || root.hasPrefix("$") { return true }
        return knownKeys.contains(root)
    }
}
