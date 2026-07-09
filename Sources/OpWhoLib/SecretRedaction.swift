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
