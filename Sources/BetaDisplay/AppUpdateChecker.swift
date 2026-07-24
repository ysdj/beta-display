import Foundation

enum AppMetadata {
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/ysdj/beta-display/releases/latest")!

    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.1.0"
    }

    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        normalizedVersion(candidate).compare(
            normalizedVersion(current),
            options: .numeric
        ) == .orderedDescending
    }

    private static func normalizedVersion(_ value: String) -> String {
        let withoutPrefix = value.hasPrefix("v") || value.hasPrefix("V")
            ? String(value.dropFirst())
            : value
        return withoutPrefix.split(separator: "+", maxSplits: 1).first.map(String.init) ?? withoutPrefix
    }
}

enum AppUpdateChecker {
    struct Release: Sendable {
        let tag: String
        let url: URL
    }

    enum Result: Sendable {
        case release(Release)
        case noPublicRelease
        case failed
    }

    static func latestRelease() async -> Result {
        var request = URLRequest(url: AppMetadata.latestReleaseURL)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("BetaDisplay/\(AppMetadata.version)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed }
            if http.statusCode == 404 { return .noPublicRelease }
            guard (200 ... 299).contains(http.statusCode) else { return .failed }
            let payload = try JSONDecoder().decode(ReleasePayload.self, from: data)
            guard let url = URL(string: payload.htmlURL), !payload.tagName.isEmpty else { return .failed }
            return .release(Release(tag: payload.tagName, url: url))
        } catch {
            return .failed
        }
    }

    private struct ReleasePayload: Decodable {
        let tagName: String
        let htmlURL: String

        private enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }
}
