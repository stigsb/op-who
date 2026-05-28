import Testing
@testable import OpWhoLib
import Foundation

@Suite("ProcessNode")
struct ProcessNodeTests {

    @Test func displayName() {
        let node = ProcessNode(pid: 123, ppid: 1, name: "bash", tty: nil, executablePath: nil, isVerifiedOnePasswordCLI: false)
        #expect(node.displayName == "bash (123)")
    }

    @Test func chainDisplayNameNormal() {
        let node = ProcessNode(pid: 1, ppid: 0, name: "ssh", tty: nil, executablePath: nil, isVerifiedOnePasswordCLI: false)
        #expect(node.chainDisplayName == "ssh")
    }

    @Test func chainDisplayNameVerifiedOp() {
        let node = ProcessNode(pid: 1, ppid: 0, name: "op", tty: nil, executablePath: "/usr/local/bin/op", isVerifiedOnePasswordCLI: true)
        #expect(node.chainDisplayName == "op")
    }

    @Test func chainDisplayNameUnverifiedOp() {
        let node = ProcessNode(pid: 1, ppid: 0, name: "op", tty: nil, executablePath: nil, isVerifiedOnePasswordCLI: false)
        #expect(node.chainDisplayName == "unverified op")
    }
}

@Suite("ProcessTree")
struct ProcessTreeTests {

    @Test func formatChainSingle() {
        let chain = [
            ProcessNode(pid: 1, ppid: 0, name: "op", tty: nil, executablePath: nil, isVerifiedOnePasswordCLI: true),
        ]
        #expect(ProcessTree.formatChain(chain) == "op")
    }

    @Test func formatChainMultiple() {
        let chain = [
            ProcessNode(pid: 10, ppid: 20, name: "op", tty: nil, executablePath: nil, isVerifiedOnePasswordCLI: true),
            ProcessNode(pid: 20, ppid: 30, name: "bash", tty: "/dev/ttys001", executablePath: nil, isVerifiedOnePasswordCLI: false),
            ProcessNode(pid: 30, ppid: 40, name: "node", tty: "/dev/ttys001", executablePath: nil, isVerifiedOnePasswordCLI: false),
        ]
        #expect(ProcessTree.formatChain(chain) == "op \u{2192} bash \u{2192} node")
    }

    @Test func formatChainUnverifiedOp() {
        let chain = [
            ProcessNode(pid: 10, ppid: 20, name: "op", tty: nil, executablePath: nil, isVerifiedOnePasswordCLI: false),
            ProcessNode(pid: 20, ppid: 30, name: "bash", tty: nil, executablePath: nil, isVerifiedOnePasswordCLI: false),
        ]
        #expect(ProcessTree.formatChain(chain) == "unverified op \u{2192} bash")
    }

    @Test func tidyPathHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(ProcessTree.tidyPath(home) == "~")
    }

    @Test func tidyPathSubdir() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(ProcessTree.tidyPath(home + "/Projects/op-who") == "~/Projects/op-who")
    }

    @Test func tidyPathNonHome() {
        #expect(ProcessTree.tidyPath("/usr/local/bin") == "/usr/local/bin")
    }

    @Test func tidyPathRoot() {
        #expect(ProcessTree.tidyPath("/") == "/")
    }

    @Test func allProcessesReturnsResults() {
        let procs = ProcessTree.allProcesses()
        #expect(!procs.isEmpty)
    }

    @Test func allProcessesContainsCurrentProcess() {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let procs = ProcessTree.allProcesses()
        #expect(procs.contains { $0.pid == myPID })
    }

    @Test func processCWDForSelf() {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let cwd = ProcessTree.processCWD(pid: myPID)
        #expect(cwd != nil)
        #expect(cwd != "")
    }

    @Test func processCWDForInvalidPID() {
        let cwd = ProcessTree.processCWD(pid: -1)
        #expect(cwd == nil)
    }

    @Test func sessionNameFromProjectPath() {
        #expect(ProcessTree.sessionName(fromCWD: "/Users/foo/git/op-who") == "op-who")
    }

    @Test func sessionNameFromHomeSubdir() {
        #expect(ProcessTree.sessionName(fromCWD: "/Users/foo/Projects/myapp") == "myapp")
    }

    @Test func sessionNameTrailingSlash() {
        #expect(ProcessTree.sessionName(fromCWD: "/Users/foo/git/op-who/") == "op-who")
    }

    @Test func sessionNameRoot() {
        #expect(ProcessTree.sessionName(fromCWD: "/") == nil)
    }

    @Test func sessionNameNil() {
        #expect(ProcessTree.sessionName(fromCWD: nil) == nil)
    }

    @Test func sessionNameEmpty() {
        #expect(ProcessTree.sessionName(fromCWD: "") == nil)
    }
}

@Suite("ProcessTree.detectScript")
struct DetectScriptTests {

    @Test func interpreterRecognitionExact() {
        for name in ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh",
                     "ruby", "node", "deno", "bun", "perl", "php",
                     "lua", "luajit", "Rscript"] {
            #expect(ProcessTree.isInterpreter(name: name), "expected \(name) to be an interpreter")
        }
    }

    @Test func interpreterRecognitionPythonVariants() {
        #expect(ProcessTree.isInterpreter(name: "python"))
        #expect(ProcessTree.isInterpreter(name: "python2"))
        #expect(ProcessTree.isInterpreter(name: "python3"))
        #expect(ProcessTree.isInterpreter(name: "python3.11"))
        #expect(ProcessTree.isInterpreter(name: "python3.12"))
        #expect(ProcessTree.isInterpreter(name: "python3.13"))
    }

    @Test func detectScriptHandlesVersionedPythonName() {
        // p_comm for /opt/homebrew/bin/python3.11 lands as "python3.11" in
        // kinfo_proc — ensure the prefix gate keeps Python flag rules active.
        let info = ProcessTree.detectScript(
            interpreter: "python3.11",
            argv: ["python3.11", "-u", "/Users/x/work/app.py"]
        )
        #expect(info?.interpreter == "python3.11")
        #expect(info?.scriptName == "app.py")

        let inline = ProcessTree.detectScript(
            interpreter: "python3.11",
            argv: ["python3.11", "-c", "print('hi')"]
        )
        #expect(inline?.scriptName == "-c print('hi')")

        let mod = ProcessTree.detectScript(
            interpreter: "python3.11",
            argv: ["python3.11", "-m", "http.server"]
        )
        #expect(mod?.scriptName == "-m http.server")
    }

    @Test func interpreterRecognitionRejectsRandomNames() {
        #expect(!ProcessTree.isInterpreter(name: "ssh"))
        #expect(!ProcessTree.isInterpreter(name: "git"))
        #expect(!ProcessTree.isInterpreter(name: "op"))
        #expect(!ProcessTree.isInterpreter(name: "claude"))
        #expect(!ProcessTree.isInterpreter(name: ""))
    }

    @Test func pythonPositionalScript() {
        let info = ProcessTree.detectScript(
            interpreter: "python3",
            argv: ["python3", "deploy.py"]
        )
        #expect(info?.scriptName == "deploy.py")
        #expect(info?.scriptPath == "deploy.py")
        #expect(info?.interpreter == "python3")
    }

    @Test func pythonScriptWithFullPathReturnsBasename() {
        let info = ProcessTree.detectScript(
            interpreter: "python3",
            argv: ["/usr/bin/python3", "/Users/x/work/app.py"]
        )
        #expect(info?.scriptName == "app.py")
        #expect(info?.scriptPath == "/Users/x/work/app.py")
    }

    @Test func pythonScriptAfterUnbufferedFlag() {
        let info = ProcessTree.detectScript(
            interpreter: "python3",
            argv: ["python3", "-u", "/Users/x/work/app.py"]
        )
        #expect(info?.scriptName == "app.py")
        #expect(info?.scriptPath == "/Users/x/work/app.py")
    }

    @Test func pythonInlineCommand() {
        let info = ProcessTree.detectScript(
            interpreter: "python3",
            argv: ["python3", "-c", "print('hi')"]
        )
        #expect(info?.scriptName == "-c print('hi')")
        #expect(info?.scriptPath == nil)
    }

    @Test func pythonInlineCommandTruncated() {
        let long = String(repeating: "a", count: 80)
        let info = ProcessTree.detectScript(
            interpreter: "python3",
            argv: ["python3", "-c", long]
        )
        // 40 chars of body + ellipsis, prefixed by "-c "
        #expect(info?.scriptName.hasPrefix("-c " + String(repeating: "a", count: 40)) == true)
        #expect(info?.scriptName.hasSuffix("…") == true)
    }

    @Test func pythonModuleForm() {
        let info = ProcessTree.detectScript(
            interpreter: "python3",
            argv: ["python3", "-m", "http.server"]
        )
        #expect(info?.scriptName == "-m http.server")
        #expect(info?.scriptPath == nil)
    }

    @Test func pythonSkipsArgvOfWAndXFlags() {
        let info = ProcessTree.detectScript(
            interpreter: "python3",
            argv: ["python3", "-W", "ignore", "-X", "utf8", "script.py"]
        )
        #expect(info?.scriptName == "script.py")
    }

    @Test func bashScriptPositional() {
        let info = ProcessTree.detectScript(
            interpreter: "bash",
            argv: ["bash", "run.sh"]
        )
        #expect(info?.scriptName == "run.sh")
    }

    @Test func bashInlineDashC() {
        let info = ProcessTree.detectScript(
            interpreter: "bash",
            argv: ["bash", "-c", "op signin"]
        )
        #expect(info?.scriptName == "-c op signin")
        #expect(info?.scriptPath == nil)
    }

    @Test func bashLoginInlineDashLC() {
        // bash -lc 'op signin' — the login-shell + command-string combo
        let info = ProcessTree.detectScript(
            interpreter: "bash",
            argv: ["bash", "-lc", "op signin"]
        )
        #expect(info?.scriptName == "-c op signin")
    }

    @Test func zshInlineDashC() {
        let info = ProcessTree.detectScript(
            interpreter: "zsh",
            argv: ["zsh", "-c", "echo hi"]
        )
        #expect(info?.scriptName == "-c echo hi")
    }

    @Test func shNoArgsReturnsNil() {
        let info = ProcessTree.detectScript(
            interpreter: "sh",
            argv: ["sh"]
        )
        #expect(info == nil)
    }

    @Test func bashInteractiveDashIReturnsNil() {
        // bash -i with no command/script is interactive — no script name
        let info = ProcessTree.detectScript(
            interpreter: "bash",
            argv: ["bash", "-i"]
        )
        #expect(info == nil)
    }

    @Test func rubyPositional() {
        let info = ProcessTree.detectScript(
            interpreter: "ruby",
            argv: ["ruby", "test.rb"]
        )
        #expect(info?.scriptName == "test.rb")
    }

    @Test func rubyDashEInline() {
        let info = ProcessTree.detectScript(
            interpreter: "ruby",
            argv: ["ruby", "-e", "puts 1"]
        )
        #expect(info?.scriptName == "-e puts 1")
    }

    @Test func nodePositional() {
        let info = ProcessTree.detectScript(
            interpreter: "node",
            argv: ["node", "app.js"]
        )
        #expect(info?.scriptName == "app.js")
    }

    @Test func nodeFullPathToScript() {
        let info = ProcessTree.detectScript(
            interpreter: "node",
            argv: ["/opt/homebrew/bin/node", "/Users/x/main.mjs"]
        )
        #expect(info?.scriptName == "main.mjs")
        #expect(info?.scriptPath == "/Users/x/main.mjs")
    }

    @Test func nodeDashEEval() {
        let info = ProcessTree.detectScript(
            interpreter: "node",
            argv: ["node", "-e", "console.log(1)"]
        )
        #expect(info?.scriptName == "-e console.log(1)")
    }

    @Test func perlDashE() {
        let info = ProcessTree.detectScript(
            interpreter: "perl",
            argv: ["perl", "-e", "print 'hi'"]
        )
        #expect(info?.scriptName == "-e print 'hi'")
    }

    @Test func doubleDashEndsFlagSection() {
        // python3 -- script-named-like-flag.py
        let info = ProcessTree.detectScript(
            interpreter: "python3",
            argv: ["python3", "--", "-weird.py"]
        )
        #expect(info?.scriptName == "-weird.py")
    }

    @Test func emptyArgvReturnsNil() {
        let info = ProcessTree.detectScript(interpreter: "python3", argv: [])
        #expect(info == nil)
    }
}
