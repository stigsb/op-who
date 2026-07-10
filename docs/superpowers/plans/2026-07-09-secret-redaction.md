# Secret Redaction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redact secret-bearing substrings out of trigger/interpreter argv at capture time so secrets never reach the popup, unified log, or predicate rule matching.

**Architecture:** A new pure module `SecretRedaction.swift` in `OpWhoLib` exposes `redactArgv([String]) -> [String]` and `redactString(String) -> String`. Detection is three composable layers — `op` field-name heuristics, known token-pattern regexes, and a high-entropy blob heuristic — built bottom-up and each independently unit-tested. Two integration points (`OnePasswordWatcher` argv capture, `ProcessTree.detectScript` inline snippets) call the redactor so every downstream sink sees only redacted values.

**Tech Stack:** Swift, `Foundation` (`NSRegularExpression`), Swift Testing (`import Testing`).

---

## File Structure

- **Create:** `Sources/OpWhoLib/SecretRedaction.swift` — the entire redaction module (entropy math, three layers, public `redactToken`/`redactString`/`redactArgv`). One responsibility: turning a string/argv into a redacted copy.
- **Create:** `Tests/SecretRedactionTests.swift` — table tests for every layer plus the argv invariant.
- **Modify:** `Sources/OpWhoLib/OnePasswordWatcher.swift` (~line 222) — wrap captured `triggerArgv` in `redactArgv(...)`.
- **Modify:** `Sources/OpWhoLib/ProcessTree.swift` (`detectScript`, the four `truncateSnippet(snippet)` sites) — wrap the snippet in `redactString(...)`.

**Build/test commands** (used throughout):

```bash
swift build
swift test --filter SecretRedactionTests
```

If this is a CommandLine-Tools-only machine, `swift test` needs the framework-path workaround documented in `CONTRIBUTORS.md` ("Running tests without full Xcode"). CI has full Xcode, so plain `swift test` works there.

---

## Task 1: Shannon entropy helper + placeholder constant

**Files:**
- Create: `Sources/OpWhoLib/SecretRedaction.swift`
- Create: `Tests/SecretRedactionTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/SecretRedactionTests.swift`:

```swift
import Testing
@testable import OpWhoLib

@Suite("Secret redaction")
struct SecretRedactionTests {

    @Test func entropyIsZeroForEmptyAndUniform() {
        #expect(shannonEntropy("") == 0)
        #expect(shannonEntropy("aaaaaaaa") == 0)
    }

    @Test func entropyIsHigherForRandomThanRepeated() {
        #expect(shannonEntropy("wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY") > 4.0)
        #expect(shannonEntropy("abababababab") < 1.5)
    }

    @Test func placeholderIsAngleQuoted() {
        #expect(secretRedactionPlaceholder == "‹redacted›")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SecretRedactionTests`
Expected: FAIL — `cannot find 'shannonEntropy' in scope` / `cannot find 'secretRedactionPlaceholder' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/OpWhoLib/SecretRedaction.swift`:

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SecretRedactionTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/OpWhoLib/SecretRedaction.swift Tests/SecretRedactionTests.swift
git commit -m "feat: secret-redaction module skeleton (entropy + placeholder)"
```

---

## Task 2: High-entropy blob layer

**Files:**
- Modify: `Sources/OpWhoLib/SecretRedaction.swift`
- Test: `Tests/SecretRedactionTests.swift`

- [ ] **Step 1: Write the failing test**

Append these tests inside the `SecretRedactionTests` struct:

```swift
    @Test func entropyLayerRedactsLongRandomBlob() {
        #expect(redactHighEntropy("wJalrXUtnFEMIK7MDENGbPxRfiCYz9qLpTvBhKmN") == secretRedactionPlaceholder)
    }

    @Test func entropyLayerRedactsValueAfterEquals() {
        #expect(redactHighEntropy("--secret=wJalrXUtnFEMIK7MDENGbPxRfiCYz9qLpTvBhKmN")
                == "--secret=" + secretRedactionPlaceholder)
    }

    @Test func entropyLayerKeepsPathsAndShortWordsAndUris() {
        #expect(redactHighEntropy("/usr/local/bin/op") == "/usr/local/bin/op")
        #expect(redactHighEntropy("op://Personal/GitHub/token") == "op://Personal/GitHub/token")
        #expect(redactHighEntropy("item create") == "item create")
        #expect(redactHighEntropy("short") == "short")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SecretRedactionTests`
Expected: FAIL — `cannot find 'redactHighEntropy' in scope`.

- [ ] **Step 3: Write minimal implementation**

Append to `Sources/OpWhoLib/SecretRedaction.swift`:

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SecretRedactionTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpWhoLib/SecretRedaction.swift Tests/SecretRedactionTests.swift
git commit -m "feat: high-entropy blob redaction layer"
```

---

## Task 3: Known-pattern layer

**Files:**
- Modify: `Sources/OpWhoLib/SecretRedaction.swift`
- Test: `Tests/SecretRedactionTests.swift`

- [ ] **Step 1: Write the failing test**

Append inside `SecretRedactionTests`:

```swift
    @Test func knownPatternsRedactStructuredTokens() {
        #expect(redactKnownPatterns("AKIAIOSFODNN7EXAMPLE") == secretRedactionPlaceholder)
        #expect(redactKnownPatterns("ghp_" + String(repeating: "a", count: 36)) == secretRedactionPlaceholder)
        #expect(redactKnownPatterns("xoxb-123456789012-abcdefabcdef") == secretRedactionPlaceholder)
        #expect(redactKnownPatterns("AIza" + String(repeating: "b", count: 35)) == secretRedactionPlaceholder)
        #expect(redactKnownPatterns("eyJhbGc.eyJzdWI.SflKxwRJ") == secretRedactionPlaceholder)
        #expect(redactKnownPatterns("-----BEGIN OPENSSH PRIVATE KEY-----") == secretRedactionPlaceholder)
    }

    @Test func knownPatternsKeepBearerAndUrlPrefix() {
        #expect(redactKnownPatterns("Authorization: Bearer abcdef123456")
                == "Authorization: Bearer " + secretRedactionPlaceholder)
        #expect(redactKnownPatterns("https://user:hunter2@example.com")
                == "https://user:" + secretRedactionPlaceholder + "@example.com")
    }

    @Test func knownPatternsLeaveOrdinaryTextAlone() {
        #expect(redactKnownPatterns("op item get GitHub") == "op item get GitHub")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SecretRedactionTests`
Expected: FAIL — `cannot find 'redactKnownPatterns' in scope`.

- [ ] **Step 3: Write minimal implementation**

Append to `Sources/OpWhoLib/SecretRedaction.swift`:

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SecretRedactionTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpWhoLib/SecretRedaction.swift Tests/SecretRedactionTests.swift
git commit -m "feat: known-pattern secret redaction layer"
```

---

## Task 4: `op` field-assignment layer

**Files:**
- Modify: `Sources/OpWhoLib/SecretRedaction.swift`
- Test: `Tests/SecretRedactionTests.swift`

- [ ] **Step 1: Write the failing test**

Append inside `SecretRedactionTests`:

```swift
    @Test func opFieldRedactsBySecretType() {
        #expect(redactOpFields("password[password]=hunter2") == "password[password]=" + secretRedactionPlaceholder)
        #expect(redactOpFields("api[concealed]=abc123") == "api[concealed]=" + secretRedactionPlaceholder)
    }

    @Test func opFieldRedactsBySecretName() {
        for name in ["credential", "password", "passwd", "secret", "token", "apikey", "api_key", "myPrivateKey", "private-key"] {
            #expect(redactOpFields("\(name)=xyz") == "\(name)=" + secretRedactionPlaceholder,
                    "expected \(name) to be redacted")
        }
    }

    @Test func opFieldKeepsNonSecretAssignments() {
        #expect(redactOpFields("username=admin") == "username=admin")
        #expect(redactOpFields("url[text]=https://example.com") == "url[text]=https://example.com")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SecretRedactionTests`
Expected: FAIL — `cannot find 'redactOpFields' in scope`.

- [ ] **Step 3: Write minimal implementation**

Append to `Sources/OpWhoLib/SecretRedaction.swift`:

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SecretRedactionTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpWhoLib/SecretRedaction.swift Tests/SecretRedactionTests.swift
git commit -m "feat: op field-assignment secret redaction layer"
```

---

## Task 5: Compose public `redactToken` / `redactString` / `redactArgv`

**Files:**
- Modify: `Sources/OpWhoLib/SecretRedaction.swift`
- Test: `Tests/SecretRedactionTests.swift`

- [ ] **Step 1: Write the failing test**

Append inside `SecretRedactionTests`:

```swift
    @Test func redactArgvPreservesCountAndOrderAndRedactsSecrets() {
        let input = ["op", "item", "create", "password[password]=hunter2", "--vault", "Personal"]
        let out = redactArgv(input)
        #expect(out.count == input.count)
        #expect(out[0] == "op")
        #expect(out[1] == "item")
        #expect(out[2] == "create")
        #expect(out[3] == "password[password]=" + secretRedactionPlaceholder)
        #expect(out[4] == "--vault")
        #expect(out[5] == "Personal")
    }

    @Test func redactArgvLeavesCleanArgvUntouched() {
        let input = ["op", "read", "op://Personal/GitHub/token"]
        #expect(redactArgv(input) == input)
    }

    @Test func redactStringHandlesInlineCommandSnippet() {
        let snippet = "curl -H 'Authorization: Bearer abcdef123456' https://api.example.com"
        #expect(redactString(snippet).contains(secretRedactionPlaceholder))
        #expect(!redactString(snippet).contains("abcdef123456"))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SecretRedactionTests`
Expected: FAIL — `cannot find 'redactArgv'` / `redactString` in scope.

- [ ] **Step 3: Write minimal implementation**

Append to `Sources/OpWhoLib/SecretRedaction.swift`:

```swift
/// Run all three redaction layers over one string. Order matters: op-field
/// assignments first (most specific), then known token patterns, then the
/// entropy sweep as a catch-all.
func redactToken(_ s: String) -> String {
    var r = s
    r = redactOpFields(r)
    r = redactKnownPatterns(r)
    r = redactHighEntropy(r)
    return r
}

/// Redact secrets inside a single string (interpreter inline-command snippets).
public func redactString(_ s: String) -> String { redactToken(s) }

/// Redact secrets from an argv array. The result has the SAME count and order
/// as the input — each token maps to itself or a redacted copy — so every
/// position-based argv parser keeps working unchanged.
public func redactArgv(_ argv: [String]) -> [String] { argv.map(redactToken) }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SecretRedactionTests`
Expected: PASS (all tests in the suite).

- [ ] **Step 5: Commit**

```bash
git add Sources/OpWhoLib/SecretRedaction.swift Tests/SecretRedactionTests.swift
git commit -m "feat: compose public redactArgv/redactString entry points"
```

---

## Task 6: Integrate at argv capture in `OnePasswordWatcher`

**Files:**
- Modify: `Sources/OpWhoLib/OnePasswordWatcher.swift` (~line 222)

- [ ] **Step 1: Make the change**

Find this line (around 222):

```swift
            let triggerArgv = measure("processArgv[\(triggerPID)]") { ProcessTree.processArgv(pid: triggerPID) }
```

Replace it with:

```swift
            let triggerArgv = redactArgv(measure("processArgv[\(triggerPID)]") { ProcessTree.processArgv(pid: triggerPID) })
```

This is the single capture site. `triggerArgv` is what feeds the git-drop log at the next lines, `operationDisplay`, the `argv:` detail row, and `PredicateContext` rule matching — all now receive the redacted form.

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds (`redactArgv` resolves — same `OpWhoLib` module).

- [ ] **Step 3: Verify existing tests still pass**

Run: `swift test`
Expected: PASS — full suite, no regressions.

- [ ] **Step 4: Commit**

```bash
git add Sources/OpWhoLib/OnePasswordWatcher.swift
git commit -m "feat: redact trigger argv at capture (popup + log + rules)"
```

---

## Task 7: Integrate at interpreter inline snippets in `detectScript`

**Files:**
- Modify: `Sources/OpWhoLib/ProcessTree.swift` (`detectScript`, four `truncateSnippet(snippet)` sites)

- [ ] **Step 1: Write the failing test**

Append inside `SecretRedactionTests` (in `Tests/SecretRedactionTests.swift`):

```swift
    @Test func detectScriptRedactsSecretInInlineCommand() {
        let argv = ["bash", "-c", "export TOKEN=ghp_" + String(repeating: "a", count: 36) + "; run"]
        let info = ProcessTree.detectScript(interpreter: "bash", argv: argv)
        #expect(info?.scriptName.contains(secretRedactionPlaceholder) == true)
        #expect(info?.scriptName.contains("ghp_") == false)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SecretRedactionTests`
Expected: FAIL — snippet still contains the raw `ghp_…` token (redaction not yet applied).

- [ ] **Step 3: Make the change**

In `Sources/OpWhoLib/ProcessTree.swift`, wrap the snippet at each of the four inline-command sites. Each currently reads:

```swift
                    scriptName: "-c " + truncateSnippet(snippet),
```
or the `-e` variants. Change every `truncateSnippet(snippet)` occurrence inside `detectScript` to:

```swift
                    scriptName: "-c " + truncateSnippet(redactString(snippet)),
```

The four sites (shell `-c`, python `-c`, perl/ruby `-e`, node `-e`/`-p`) all follow the same `"<flag> " + truncateSnippet(snippet)` shape — insert `redactString(...)` around `snippet` in each. Leave the `-m module` and script-path branches unchanged (not secret-bearing).

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: PASS — the new `detectScript` test and the full suite.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpWhoLib/ProcessTree.swift Tests/SecretRedactionTests.swift
git commit -m "feat: redact secrets in interpreter inline-command snippets"
```

---

## Task 8: Final verification & docs

**Files:**
- Modify: `CLAUDE.md` (Key design decisions list)

- [ ] **Step 1: Full build + test**

Run: `swift build && swift test`
Expected: Build succeeds, all tests pass.

- [ ] **Step 2: Record the design decision**

In `CLAUDE.md`, under "## Key design decisions", append a bullet:

```markdown
- Secrets in argv are redacted at capture (`redactArgv` in `SecretRedaction.swift`): `op` field assignments with a `password`/`concealed` type or a credential-ish name, known token shapes (AWS/GitHub/Slack/JWT/PEM/Bearer/URL-userinfo), and high-entropy blobs are replaced with `‹redacted›` before argv reaches the popup, the unified log, or predicate rule matching. Redaction preserves token count/order so argv parsers are unaffected.
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: note argv secret redaction in key design decisions"
```

---

## Self-review notes

- **Spec coverage:** op field heuristic (Task 4), known patterns + entropy (Tasks 2–3), redact-at-capture placement (Task 6), inline-snippet surface (Task 7), structure-preserving invariant (Task 5 test), Swift-Testing table tests (all tasks). All spec sections map to a task.
- **Type consistency:** `secretRedactionPlaceholder`, `shannonEntropy`, `redactHighEntropy`, `redactKnownPatterns`, `redactOpFields`, `redactToken`, `redactString`, `redactArgv` are used with identical signatures across tasks.
- **Out of scope (unchanged):** env-var scrubbing, network/file scanning, process/chain names.
