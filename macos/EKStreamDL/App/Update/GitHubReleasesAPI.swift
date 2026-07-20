import Foundation

struct GitHubAsset: Decodable {
    let name: String
    let browser_download_url: URL
}

struct GitHubRelease: Decodable {
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    let body: String?
    let assets: [GitHubAsset]
}

enum ReleaseAssetSelector {
    static func preferredMacOSAssetNames(for version: Version) -> [String] {
        [
            "macOS-universal-EK StreamDL-\(version.description).zip",
            "macOS-universal-EK.StreamDL-\(version.description).zip",
        ]
    }

    static func macOSAsset(in assets: [GitHubAsset], version: Version) -> GitHubAsset? {
        let expectedNames = preferredMacOSAssetNames(for: version)
        return assets.first(where: { expectedNames.contains($0.name) })
    }
}

enum GitHubReleaseError: LocalizedError {
    case noPublishedRelease
    case invalidResponse
    case invalidRelease
    case missingZipAsset

    var errorDescription: String? {
        switch self {
        case .noPublishedRelease:
            return "GitHub 仓库尚未发布可用版本"
        case .invalidResponse:
            return "GitHub API 返回异常"
        case .invalidRelease:
            return "无法解析 GitHub Releases 信息"
        case .missingZipAsset:
            return "未找到符合 EK StreamDL 命名规范的 macOS Universal 更新包"
        }
    }
}

enum GitHubAPI {
    private static let owner = "Tang1206cc"
    private static let repo = "EK-Streaming-Video-Downloader"
    private static let userAgent = "EKStreamDL"

    static func fetchLatestRelease(
        token: String? = ProcessInfo.processInfo.environment["GITHUB_TOKEN"]
    ) async throws -> GitHubRelease {
        do {
            return try await fetchLatestReleaseFromAPI(token: token)
        } catch {
            return try await fetchLatestReleaseFromAtomFeed()
        }
    }

    private static func fetchLatestReleaseFromAPI(token: String?) async throws -> GitHubRelease {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubReleaseError.invalidResponse
        }
        if httpResponse.statusCode == 404 {
            throw GitHubReleaseError.noPublishedRelease
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw GitHubReleaseError.invalidResponse
        }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard !release.draft, !release.prerelease else {
            throw GitHubReleaseError.noPublishedRelease
        }
        return release
    }

    private static func fetchLatestReleaseFromAtomFeed() async throws -> GitHubRelease {
        let url = URL(string: "https://github.com/\(owner)/\(repo)/releases.atom")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw GitHubReleaseError.invalidResponse
        }

        let parser = LatestReleaseFeedParser(data: data)
        guard let entry = parser.parse() else {
            throw GitHubReleaseError.noPublishedRelease
        }
        guard let latestVersion = Version(entry.tagName) else {
            throw GitHubReleaseError.invalidRelease
        }

        let candidateAssetNames = ReleaseAssetSelector.preferredMacOSAssetNames(for: latestVersion)
        for assetName in candidateAssetNames {
            guard let encodedAssetName = assetName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
                continue
            }
            let assetURL = URL(
                string: "https://github.com/\(owner)/\(repo)/releases/download/\(entry.tagName)/\(encodedAssetName)"
            )!
            if try await releaseAssetExists(at: assetURL) {
                return GitHubRelease(
                    tag_name: entry.tagName,
                    draft: false,
                    prerelease: false,
                    body: entry.releaseNotes,
                    assets: [GitHubAsset(name: assetName, browser_download_url: assetURL)]
                )
            }
        }

        throw GitHubReleaseError.missingZipAsset
    }

    private static func releaseAssetExists(at url: URL) async throws -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 20
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(httpResponse.statusCode)
    }
}

private final class LatestReleaseFeedParser: NSObject, XMLParserDelegate {
    private let parser: XMLParser
    private var isReadingLatestEntry = false
    private var didReadLatestEntry = false
    private var currentElement = ""
    private var latestLink = ""
    private var latestID = ""
    private var latestContent = ""

    init(data: Data) {
        parser = XMLParser(data: data)
        super.init()
        parser.delegate = self
    }

    func parse() -> (tagName: String, releaseNotes: String?)? {
        guard parser.parse() else { return nil }
        let tagName = tagName(from: latestLink) ?? tagName(from: latestID)
        guard let tagName else { return nil }

        let notes = plainText(from: latestContent)
        return (tagName: tagName, releaseNotes: notes.isEmpty || notes == "No content." ? nil : notes)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard !didReadLatestEntry else { return }

        if elementName == "entry" {
            isReadingLatestEntry = true
            return
        }

        guard isReadingLatestEntry else { return }
        currentElement = elementName

        if elementName == "link", attributeDict["rel"] == "alternate", let href = attributeDict["href"] {
            latestLink = href
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard isReadingLatestEntry else { return }
        switch currentElement {
        case "id": latestID += string
        case "content": latestContent += string
        default: break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard isReadingLatestEntry else { return }
        if elementName == currentElement {
            currentElement = ""
        }
        if elementName == "entry" {
            isReadingLatestEntry = false
            didReadLatestEntry = true
        }
    }

    private func tagName(from string: String) -> String? {
        guard let range = string.range(of: "/releases/tag/") else {
            return string.split(separator: "/").last.map(String.init)
        }
        let suffix = string[range.upperBound...]
        return suffix.split(separator: "/").first.map(String.init)
    }

    private func plainText(from html: String) -> String {
        html
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br />", with: "\n")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
