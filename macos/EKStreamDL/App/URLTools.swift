import Foundation

enum SupportedPlatform: String {
    case bilibili
    case douyin
    case kuaishou
    case xiaohongshu
    case toutiao
    case wechatChannels

    var name: String {
        switch self {
        case .bilibili:
            return "哔哩哔哩"
        case .douyin:
            return "抖音"
        case .kuaishou:
            return "快手"
        case .xiaohongshu:
            return "小红书"
        case .toutiao:
            return "今日头条"
        case .wechatChannels:
            return "微信视频号"
        }
    }
}

enum URLTools {
    static func extractUrl(from input: String) -> String? {
        let pattern = #"https?://[^\s"'<>，。、“”‘’）)]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        guard let match = regex.firstMatch(in: input, range: range),
              let urlRange = Range(match.range, in: input) else {
            return nil
        }
        return String(input[urlRange])
    }

    static func normalize(_ rawUrl: String) throws -> String {
        guard var components = URLComponents(string: rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme != nil,
              components.host != nil else {
            throw UserFacingError("链接格式不正确")
        }
        components.fragment = nil
        guard let url = components.url else {
            throw UserFacingError("链接格式不正确")
        }
        return url.absoluteString
    }

    static func detectPlatform(_ rawUrl: String) -> SupportedPlatform? {
        guard let url = URL(string: rawUrl),
              let host = url.host?.lowercased() else {
            return nil
        }

        if host == "weixin.qq.com",
           url.path.hasPrefix("/sph/"),
           url.path.split(separator: "/").count >= 2 {
            return .wechatChannels
        }
        if host == "channels.weixin.qq.com",
           url.path == "/finder-preview/pages/sph",
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           components.queryItems?.contains(where: {
               $0.name == "id" && !($0.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
           }) == true {
            return .wechatChannels
        }

        if host == "b23.tv" || hostMatches(host, domain: "bilibili.com") {
            return .bilibili
        }
        if hostMatches(host, domain: "douyin.com") || hostMatches(host, domain: "iesdouyin.com") {
            return .douyin
        }
        if hostMatches(host, domain: "kuaishou.com") ||
            hostMatches(host, domain: "kwai.com") ||
            hostMatches(host, domain: "chenzhongtech.com") {
            return .kuaishou
        }
        if hostMatches(host, domain: "xiaohongshu.com") || hostMatches(host, domain: "xhslink.com") {
            return .xiaohongshu
        }
        if hostMatches(host, domain: "toutiao.com") {
            return .toutiao
        }
        return nil
    }

    private static func hostMatches(_ host: String, domain: String) -> Bool {
        host == domain || host.hasSuffix(".\(domain)")
    }

    static func sanitizeFilename(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = name.components(separatedBy: illegal).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "video" : String(cleaned.prefix(120))
    }
}

struct UserFacingError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
