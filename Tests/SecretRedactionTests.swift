import Testing
@testable import OpWhoLib
import Foundation

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

    @Test func knownPatternsRedactStructuredTokens() {
        #expect(redactKnownPatterns("AKIAIOSFODNN7EXAMPLE") == secretRedactionPlaceholder)
        #expect(redactKnownPatterns("ghp_" + String(repeating: "a", count: 36)) == secretRedactionPlaceholder)
        #expect(redactKnownPatterns("xoxb-123456789012-abcdefabcdef") == secretRedactionPlaceholder)
        #expect(redactKnownPatterns("AIza" + String(repeating: "b", count: 35)) == secretRedactionPlaceholder)
        #expect(redactKnownPatterns("eyJhbGc.eyJzdWI.SflKxwRJ") == secretRedactionPlaceholder)
        #expect(redactKnownPatterns("-----BEGIN OPENSSH PRIVATE KEY-----") == secretRedactionPlaceholder)
    }

    @Test func knownPatternsRedactWholePemBlocks() {
        let key = """
        -----BEGIN RSA PRIVATE KEY-----
        MIIEpAIBAAKCAQEAwJalrXUtnFEMIK7MDENGbPxRfiCYz9qLpTvBhKmNwJalrXUt
        nFEMIK7MDENGbPxRfiCYz9qLpTvBhKmNwJalrXUtnFEMIK7MDENGbPxRfiCY==
        -----END RSA PRIVATE KEY-----
        """
        #expect(redactKnownPatterns(key) == secretRedactionPlaceholder)

        let cert = """
        -----BEGIN CERTIFICATE-----
        MIIDdzCCAl+gAwIBAgIEAgAAuTANBgkqhkiG9w0BAQsFADBaMQswCQYDVQQGEwJJ
        RTESMBAGA1UEChMJQmFsdGltb3JlMRMwEQYDVQQLEwpDeWJlclRydXN0MSIwIA==
        -----END CERTIFICATE-----
        """
        #expect(redactKnownPatterns(cert) == secretRedactionPlaceholder)
    }

    @Test func pemBlockInsideFlagKeepsFlagPrefix() {
        let arg = "--key=-----BEGIN EC PRIVATE KEY-----\nMHcCAQEEIABC\n-----END EC PRIVATE KEY-----"
        #expect(redactKnownPatterns(arg) == "--key=" + secretRedactionPlaceholder)
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

    @Test func urlHostPortWithoutUserinfoIsPreserved() {
        #expect(redactKnownPatterns("redis://localhost:6379") == "redis://localhost:6379")
        #expect(redactKnownPatterns("postgres://localhost:5432/mydb") == "postgres://localhost:5432/mydb")
    }

    @Test func urlUserinfoPasswordStillRedactedWithHostPortTail() {
        #expect(redactKnownPatterns("postgres://user:secretpw@db.example.com:5432/app")
                == "postgres://user:" + secretRedactionPlaceholder + "@db.example.com:5432/app")
    }

    @Test func entropyLayerKeepsLongFlags() {
        #expect(redactHighEntropy("--enable-some-experimental-feature-flag") == "--enable-some-experimental-feature-flag")
    }

    @Test func entropyLayerStillRedactsBlobAfterFlagEquals() {
        let blob = "wJalrXUtnFEMIK7MDENGbPxRfiCYz9qLpTvBhKmN"
        #expect(redactHighEntropy("--token=" + blob) == "--token=" + secretRedactionPlaceholder)
    }

    @Test func redactArgvTruncatesLongArguments() {
        let long = String(repeating: "a", count: 120)
        let out = redactArgv(["op", long])
        #expect(out[1] == String(repeating: "a", count: maxArgvArgLength) + "…")
        #expect(out[1].count == maxArgvArgLength + 1)
    }

    @Test func redactArgvExemptsArgv0FromTruncation() {
        let longPath = "/opt/homebrew/Cellar/1password-cli/2.31.0/bin/op-longer-than-fifty"
        #expect(longPath.count > maxArgvArgLength)
        let out = redactArgv([longPath, "read"])
        #expect(out[0] == longPath)
    }

    @Test func redactArgvKeepsShortArgumentsVerbatim() {
        let input = ["op", "read", "op://Personal/GitHub/token"]
        #expect(redactArgv(input) == input)
    }

    @Test func redactArgvRedactsBeforeTruncating() {
        // A long PEM key argument collapses to the placeholder, not a truncated
        // slice of the key body.
        let key = "-----BEGIN RSA PRIVATE KEY-----\n" + String(repeating: "MIIEpQ", count: 30) + "\n-----END RSA PRIVATE KEY-----"
        let out = redactArgv(["ssh-add", key])
        #expect(out[1] == secretRedactionPlaceholder)
    }

    @Test func redactArgvHandlesEmptyInput() {
        #expect(redactArgv([]) == [])
        #expect(redactString("") == "")
    }

    @Test func resolveScriptInfoRedactsSecretInInvokedCommand() {
        // A distinct invoked command below a `bash -c` wrapper gets its argv
        // redacted via redactArgv.
        let secret = "ghp_" + String(repeating: "a", count: 36)
        let chain = [
            ProcessNode(pid: 1, ppid: 0, name: "op", tty: nil, executablePath: nil, isVerifiedOnePasswordCLI: false),
            ProcessNode(pid: 2, ppid: 0, name: "terraform", tty: nil, executablePath: nil, isVerifiedOnePasswordCLI: false),
            ProcessNode(pid: 3, ppid: 0, name: "bash", tty: nil, executablePath: nil, isVerifiedOnePasswordCLI: false),
        ]
        let argv: [pid_t: [String]] = [
            1: ["op", "read", "x"],
            2: ["terraform", "apply", "-var", "token=" + secret],
            3: ["bash", "-c", "source /x/.claude/shell-snapshots/s.sh && eval 'terraform apply -var token=…'"],
        ]
        let info = ProcessTree.resolveScriptInfo(
            chain: chain, triggerPID: 1, claudePID: nil, argvFor: { argv[$0] ?? [] })
        #expect(info?.scriptName.contains(secretRedactionPlaceholder) == true)
        #expect(info?.scriptName.contains("ghp_") == false)
    }
}
