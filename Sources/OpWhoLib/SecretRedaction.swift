import Foundation

/// Text substituted for any detected secret. Single-angle quotes so it reads
/// distinctly from surrounding argv and is trivially greppable in logs.
public let secretRedactionPlaceholder = "‹redacted›"

/// Shannon entropy of `s` in bits per character. 0 for empty or single-symbol
/// strings; ~6 for a long uniformly-random base64 blob.
func shannonEntropy(_ s: String) -> Double {
    guard !s.isEmpty else { return 0 }
    var counts: [Character: Int] = [:]
    for c in s { counts[c, default: 0] += 1 }
    let n = Double(s.count)
    var h = 0.0
    for (_, count) in counts {
        let p = Double(count) / n
        h -= p * log2(p)
    }
    return h
}

private let base64ishCharset = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+=_-")

/// Redact whitespace-delimited words whose value looks like a high-entropy
/// secret. For `key=value` / `--flag=value` words only the part after the last
/// `=` is evaluated and replaced, so the key stays readable. Words containing
/// `/` (filesystem paths, `op://` URIs) are skipped, which is why the value
/// charset deliberately excludes `/`.
func redactHighEntropy(_ s: String) -> String {
    let words = s.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    let redacted = words.map { word -> String in
        let prefix: String
        let value: String
        if let eq = word.lastIndex(of: "=") {
            prefix = String(word[...eq])
            value = String(word[word.index(after: eq)...])
        } else {
            prefix = ""
            value = word
        }
        guard value.count >= 20,
              !value.contains("/"),
              value.allSatisfy({ base64ishCharset.contains($0) }),
              shannonEntropy(value) >= 3.5
        else { return word }
        return prefix + secretRedactionPlaceholder
    }
    return redacted.joined(separator: " ")
}

private struct PatternRule {
    let regex: NSRegularExpression
    /// Replacement template. `$1` keeps the first capture group (a readable
    /// prefix like `Bearer ` or `user:`); no group means the whole match is
    /// replaced by the placeholder.
    let template: String
}

private func rule(_ pattern: String, keepPrefix: Bool = false) -> PatternRule? {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
    return PatternRule(regex: re, template: keepPrefix ? "$1" + secretRedactionPlaceholder
                                                       : secretRedactionPlaceholder)
}

private let knownPatternRules: [PatternRule] = [
    rule("AKIA[0-9A-Z]{16}"),
    rule("gh[pousr]_[A-Za-z0-9]{36,}"),
    rule("xox[baprs]-[A-Za-z0-9-]{10,}"),
    rule("AIza[0-9A-Za-z_-]{35}"),
    rule("eyJ[A-Za-z0-9_-]+\\.eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+"),
    rule("-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    rule("(?i)(bearer\\s+)[A-Za-z0-9._-]{8,}", keepPrefix: true),
    rule("(://[^/\\s:@]+:)[^/\\s@]+", keepPrefix: true),
].compactMap { $0 }

/// Replace any substring matching a known secret-token shape with the
/// placeholder. `keepPrefix` rules preserve a readable lead-in (`Bearer `,
/// `user:`) so the popup still hints at what kind of secret was hidden.
func redactKnownPatterns(_ s: String) -> String {
    var result = s
    for r in knownPatternRules {
        let ns = result as NSString
        let range = NSRange(location: 0, length: ns.length)
        result = r.regex.stringByReplacingMatches(in: result, range: range, withTemplate: r.template)
    }
    return result
}

private let opFieldRegex = try! NSRegularExpression(
    pattern: "([A-Za-z0-9._-]+)(\\[([A-Za-z]+)\\])?=(\\S+)")

private let secretFieldKeywords = ["credential", "password", "passwd", "secret", "token", "apikey", "api_key"]

/// True when an `op` field assignment `name[type]=value` carries a secret,
/// judged by field type (`password`/`concealed`) or by the field name.
private func shouldRedactField(name: String, type: String?) -> Bool {
    if let t = type?.lowercased(), t == "password" || t == "concealed" { return true }
    let n = name.lowercased()
    if secretFieldKeywords.contains(where: { n.contains($0) }) { return true }
    if n.range(of: "private.?key", options: .regularExpression) != nil { return true }
    return false
}

/// Redact the value of any `op item` field assignment that looks secret,
/// preserving the `name[type]=` prefix so the operation stays legible.
func redactOpFields(_ s: String) -> String {
    let ns = s as NSString
    let matches = opFieldRegex.matches(in: s, range: NSRange(location: 0, length: ns.length))
    guard !matches.isEmpty else { return s }
    var result = s
    // Reverse order so replacing a value never shifts an earlier match's range.
    for m in matches.reversed() {
        let name = ns.substring(with: m.range(at: 1))
        let type = m.range(at: 3).location != NSNotFound ? ns.substring(with: m.range(at: 3)) : nil
        guard shouldRedactField(name: name, type: type) else { continue }
        if let r = Range(m.range(at: 4), in: result) {
            result.replaceSubrange(r, with: secretRedactionPlaceholder)
        }
    }
    return result
}
