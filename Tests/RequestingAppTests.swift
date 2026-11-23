import Testing
import Foundation
import Darwin
@testable import OpWhoLib

@Suite("ProcessTree requesting app")
struct RequestingAppTests {
    private let outer = "/Applications/Visual Studio Code.app"
    private let helper = "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app"

    @Test func kernelExecutablePathOfSelf() {
        let path = ProcessTree.kernelExecutablePath(pid: getpid())
        #expect(path?.hasPrefix("/") == true)
    }

    @Test func kernelExecutablePathOfMissingProcess() {
        #expect(ProcessTree.kernelExecutablePath(pid: 99_999_999) == nil)
    }

    @Test func outermostBundlePath() {
        #expect(ProcessTree.outermostAppBundlePath(helper) == outer)
        #expect(ProcessTree.outermostAppBundlePath(helper + "/Contents/MacOS/Code Helper (Plugin)") == outer)
        #expect(ProcessTree.outermostAppBundlePath(outer) == outer)
        #expect(ProcessTree.outermostAppBundlePath("/usr/local/bin/kubectl") == nil)
    }

    @Test func nestedAppReportsOutermostBundleAndItsPID() {
        let main = ProcessTree.RunningApp(pid: 50, bundleID: "com.microsoft.VSCode", bundlePath: outer)
        let nested = ProcessTree.RunningApp(pid: 70, bundleID: "com.microsoft.VSCode.helper", bundlePath: helper)
        let got = ProcessTree.outermostApp(stoppedAt: nested, apps: [50: main, 70: nested]) { path in
            path == outer ? "com.microsoft.VSCode" : nil
        }
        #expect(got.bundleID == "com.microsoft.VSCode")
        #expect(got.pid == 50)
    }

    @Test func nestedAppWithoutRunningOuterKeepsStoppedPID() {
        let nested = ProcessTree.RunningApp(pid: 70, bundleID: "com.microsoft.VSCode.helper", bundlePath: helper)
        let got = ProcessTree.outermostApp(stoppedAt: nested, apps: [70: nested]) { _ in "com.microsoft.VSCode" }
        #expect(got.bundleID == "com.microsoft.VSCode")
        #expect(got.pid == 70)
    }

    @Test func topLevelAppIsReportedAsIs() {
        let app = ProcessTree.RunningApp(pid: 50, bundleID: "com.microsoft.VSCode", bundlePath: outer)
        let got = ProcessTree.outermostApp(stoppedAt: app, apps: [50: app]) { _ in "wrong" }
        #expect(got.bundleID == "com.microsoft.VSCode")
        #expect(got.pid == 50)
    }

    @Test func unreadableOuterBundleFallsBackToStoppedApp() {
        let nested = ProcessTree.RunningApp(pid: 70, bundleID: "com.microsoft.VSCode.helper", bundlePath: helper)
        let got = ProcessTree.outermostApp(stoppedAt: nested, apps: [70: nested]) { _ in nil }
        #expect(got.bundleID == "com.microsoft.VSCode.helper")
        #expect(got.pid == 70)
    }

    @Test func displayNames() {
        #expect(ProcessTree.appDisplayName(bundleID: "com.googlecode.iterm2", bundlePath: "/Applications/iTerm.app") == "iTerm")
        #expect(ProcessTree.appDisplayName(bundleID: "com.microsoft.VSCode", bundlePath: outer) == "Visual Studio Code")
        #expect(ProcessTree.appDisplayName(bundleID: "com.example.gone", bundlePath: nil) == "com.example.gone")
    }
}
