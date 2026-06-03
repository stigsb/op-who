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

    private struct ReleaseResponse: Decodable {
        let tagName: String
        let htmlURL: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    /// Decode a GitHub `/releases/latest` response body and decide whether an
    /// update is available relative to `currentVersion`. Pure — no network.
    public static func evaluate(responseData: Data, currentVersion: String) -> UpdateCheckResult {
        let release: ReleaseResponse
        do {
            release = try JSONDecoder().decode(ReleaseResponse.self, from: responseData)
        } catch {
            return .failed(message: "Unexpected response from GitHub.")
        }

        guard let latestComponents = parseVersion(release.tagName),
              let releaseURL = URL(string: release.htmlURL) else {
            return .failed(message: "Could not read the latest release info.")
        }

        // Normalized (v-stripped) string for display.
        let latestDisplay = latestComponents.map(String.init).joined(separator: ".")

        guard let currentComponents = parseVersion(currentVersion) else {
            // Can't compare against an unknown local version; surface the
            // available release rather than claiming up-to-date.
            return .updateAvailable(latest: latestDisplay, releaseURL: releaseURL)
        }

        switch compare(latestComponents, currentComponents) {
        case .orderedDescending:
            return .updateAvailable(latest: latestDisplay, releaseURL: releaseURL)
        case .orderedSame, .orderedAscending:
            return .upToDate(current: currentVersion)
        }
    }

    /// Fetch the latest release from GitHub and evaluate it against
    /// `currentVersion`. The completion handler is always invoked on the main
    /// thread. Network and decoding failures map to `.failed`.
    public static func checkForUpdates(
        currentVersion: String,
        session: URLSession = .shared,
        completion: @escaping (UpdateCheckResult) -> Void
    ) {
        func finish(_ result: UpdateCheckResult) {
            DispatchQueue.main.async { completion(result) }
        }

        var request = URLRequest(url: latestReleaseAPI)
        // GitHub's API rejects requests without a User-Agent.
        request.setValue("op-who/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                finish(.failed(message: error.localizedDescription))
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                finish(.failed(message: "GitHub returned HTTP \(http.statusCode)."))
                return
            }
            guard let data = data else {
                finish(.failed(message: "No data received from GitHub."))
                return
            }
            finish(evaluate(responseData: data, currentVersion: currentVersion))
        }
        task.resume()
    }
}
