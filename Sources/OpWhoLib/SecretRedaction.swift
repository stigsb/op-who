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
