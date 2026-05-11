import Testing
import Foundation
@testable import OpWhoLib

@Suite("ClaudeContext parser")
struct ClaudeContextTests {

    /// Build a JSONL-style multi-line blob from individual record dicts.
    private func jsonl(_ records: [[String: Any]]) -> String {
        // Prefix a junk line — real tail-reads land mid-record, so the parser
        // must skip the first line. Our test data needs to model that.
        var lines = ["NOT-JSON-PARTIAL-LINE"]
        for rec in records {
            let data = try! JSONSerialization.data(withJSONObject: rec)
            lines.append(String(data: data, encoding: .utf8)!)
        }
        return lines.joined(separator: "\n")
    }

    @Test func extractsBashInputFromUserMessage() {
        let blob = jsonl([
            [
                "type": "user",
                "message": [
                    "role": "user",
                    "content": "<bash-input>op vault list</bash-input>\n<bash-stdout>ID NAME</bash-stdout>",
                ],
            ]
        ])
        let ctx = parseClaudeContext(jsonlTail: blob, sessionID: "test")
        #expect(ctx?.lastRelevantCommand == "op vault list")
    }

    @Test func extractsClaudeBashToolUse() {
        let blob = jsonl([
            [
                "type": "assistant",
                "message": [
                    "role": "assistant",
                    "content": [[
                        "type": "tool_use",
                        "name": "Bash",
                        "input": ["command": "op item list"],
                    ]],
                ],
            ]
        ])
        let ctx = parseClaudeContext(jsonlTail: blob, sessionID: "s")
        #expect(ctx?.lastRelevantCommand == "op item list")
    }

    @Test func extractsNaturalLanguagePrompt() {
        let blob = jsonl([
            [
                "type": "user",
                "message": [
                    "role": "user",
                    "content": "please run op item list and tell me the count",
                ],
            ]
        ])
        let ctx = parseClaudeContext(jsonlTail: blob, sessionID: "s")
        #expect(ctx?.lastUserPrompt?.starts(with: "please run op item list") == true)
    }

    @Test func skipsSystemReminders() {
        let blob = jsonl([
            [
                "type": "user",
                "message": [
                    "role": "user",
                    "content": "<system-reminder>tasks getting stale</system-reminder>",
                ],
            ]
        ])
        let ctx = parseClaudeContext(jsonlTail: blob, sessionID: "s")
        #expect(ctx?.lastUserPrompt == nil)
    }

    @Test func picksNewestRelevantCommand() {
        // Older command is git fetch, newer is op item list — newer wins.
        let blob = jsonl([
            [
                "type": "assistant",
                "message": [
                    "role": "assistant",
                    "content": [[
                        "type": "tool_use", "name": "Bash",
                        "input": ["command": "git fetch origin"],
                    ]],
                ],
            ],
            [
                "type": "user",
                "message": [
                    "role": "user",
                    "content": "<bash-input>op item list</bash-input>",
                ],
            ],
        ])
        let ctx = parseClaudeContext(jsonlTail: blob, sessionID: "s")
        #expect(ctx?.lastRelevantCommand == "op item list")
    }

    @Test func filtersIrrelevantCommands() {
        // No op/ssh/git here — should return no command.
        let blob = jsonl([
            [
                "type": "user",
                "message": [
                    "role": "user",
                    "content": "<bash-input>ls -la</bash-input>",
                ],
            ],
        ])
        let ctx = parseClaudeContext(jsonlTail: blob, sessionID: "s")
        #expect(ctx?.lastRelevantCommand == nil)
    }

    @Test func projectDirectoryEncoding() {
        let dir = claudeProjectDirectory(cwd: "/Users/stig/git/trusthere/main")
        #expect(dir.path.hasSuffix("/.claude/projects/-Users-stig-git-trusthere-main"))
    }

    @Test func bashInputCommandHelper() {
        #expect(bashInputCommand(in: "<bash-input>op signin</bash-input>") == "op signin")
        #expect(bashInputCommand(in: "no markers") == nil)
        #expect(bashInputCommand(in: "<bash-input>ls</bash-input>") == nil)  // not relevant
    }

    @Test func relevantCommandRegex() {
        #expect(isRelevantCommand("op item list"))
        #expect(isRelevantCommand("/usr/local/bin/op vault list"))
        #expect(isRelevantCommand("git push origin main"))
        #expect(isRelevantCommand("ssh user@host"))
        #expect(!isRelevantCommand("opentemplate run"))   // not "op " as token
        #expect(!isRelevantCommand("ls -la"))
        #expect(!isRelevantCommand("echo opacity"))
    }
}
