import Foundation

/// App metadata read live from the bundle, plus static repo links.
public enum AppInfo {
    /// The running app's marketing version (CFBundleShortVersionString).
    /// Falls back to "unknown" when read outside an app bundle (e.g. tests).
    public static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
    }

    /// The project's GitHub repository page.
    public static let repoURL = URL(string: "https://github.com/stigsb/op-who")!
}

/// Outcome of an update check.
public enum UpdateCheckResult: Equatable {
    case upToDate(current: String)
    case updateAvailable(latest: String, releaseURL: URL)
    case failed(message: String)
}

public enum UpdateChecker {

    /// GitHub REST endpoint for the most recent published (non-draft,
    /// non-prerelease) release.
    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/stigsb/op-who/releases/latest")!

    /// Parse a version string into numeric components. Accepts an optional
    /// leading "v"/"V". Returns nil if any component is non-numeric or the
    /// string is empty.
    public static func parseVersion(_ string: String) -> [Int]? {
        var s = string
        if let first = s.first, first == "v" || first == "V" {
            s.removeFirst()
        }
        guard !s.isEmpty else { return nil }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        var components: [Int] = []
        for part in parts {
            guard let n = Int(part) else { return nil }
            components.append(n)
        }
        return components.isEmpty ? nil : components
    }

    /// Compare two numeric version-component arrays, zero-padding the shorter.
    public static func compare(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
        let count = max(lhs.count, rhs.count)
        for i in 0..<count {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        return .orderedSame
    }
}
