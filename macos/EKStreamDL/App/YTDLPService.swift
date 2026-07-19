import Foundation

final class YTDLPService {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let downloadControl = DownloadControlRegistry()
    private let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"
    private let mobileUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    private let kuaishouUserAgent = "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36 Kwai/12.0.40"

    private struct XiaohongshuSupplement {
        var title: String?
        var author: String?
        var publishedAt: String?
        var coverUrl: String?
    }

    private struct CoverImageData {
        var data: Data
        var fileExtension: String
    }

    private struct WeChatChannelsMediaProfile {
        var mediaURL: String
        var referer: String
        var duration: Double?
        var totalBytes: Int64?
    }

    private struct ToutiaoDirectProfile {
        var article: ToutiaoRenderData.ArticleInfo
        var formats: [ToutiaoVODResponse.PlayInfo]
        var selectedFormat: ToutiaoVODResponse.PlayInfo
        var mediaURL: String
        var duration: Double?
        var totalBytes: Int64?
        var coverURL: String?
    }

    private struct ToutiaoRenderData: Decodable {
        var articleInfo: ArticleInfo?

        struct ArticleInfo: Decodable {
            var gid: String?
            var title: String?
            var publishTime: String?
            var detailSource: String?
            var mediaUser: MediaUser?
            var posterUrl: String?
            var videoId: String?
            var videoDuration: Double?
            var playAuthTokenV2: String?
        }

        struct MediaUser: Decodable {
            var screenName: String?
        }
    }

    private struct ToutiaoPlayToken: Decodable {
        var query: String?

        enum CodingKeys: String, CodingKey {
            case query = "GetPlayInfoToken"
        }
    }

    private struct ToutiaoVODResponse: Decodable {
        var result: ResultItem?

        enum CodingKeys: String, CodingKey {
            case result = "Result"
        }

        struct ResultItem: Decodable {
            var data: DataItem?

            enum CodingKeys: String, CodingKey {
                case data = "Data"
            }
        }

        struct DataItem: Decodable {
            var status: Int?
            var coverUrl: String?
            var duration: Double?
            var playInfoList: [PlayInfo]?

            enum CodingKeys: String, CodingKey {
                case status = "Status"
                case coverUrl = "CoverUrl"
                case duration = "Duration"
                case playInfoList = "PlayInfoList"
            }
        }

        struct PlayInfo: Decodable {
            var bitrate: Int64?
            var size: Int64?
            var height: Int?
            var width: Int?
            var format: String?
            var codec: String?
            var definition: String?
            var duration: Double?
            var mainPlayUrl: String?
            var backupPlayUrl: String?

            enum CodingKeys: String, CodingKey {
                case bitrate = "Bitrate"
                case size = "Size"
                case height = "Height"
                case width = "Width"
                case format = "Format"
                case codec = "Codec"
                case definition = "Definition"
                case duration = "Duration"
                case mainPlayUrl = "MainPlayUrl"
                case backupPlayUrl = "BackupPlayUrl"
            }
        }
    }

    func parse(inputText: String) async throws -> VideoMetadata {
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw UserFacingError("请输入链接")
        }
        guard let extractedUrl = URLTools.extractUrl(from: inputText) else {
            throw UserFacingError("未识别到链接")
        }

        let normalizedUrl = try URLTools.normalize(extractedUrl)
        guard let platform = URLTools.detectPlatform(normalizedUrl) else {
            throw UserFacingError("暂不支持的平台")
        }

        let resolvedUrl = try await resolveShareUrlIfNeeded(normalizedUrl, platform: platform)
        guard URLTools.detectPlatform(resolvedUrl) == platform else {
            throw UserFacingError("链接重定向到了非预期平台，已停止解析")
        }

        if platform == .wechatChannels {
            return try await parseWeChatChannelsPublic(
                originalUrl: extractedUrl,
                resolvedUrl: resolvedUrl
            )
        }
        if platform == .bilibili,
           let metadata = try await parseBilibiliViaPublicAPI(
            originalUrl: extractedUrl,
            resolvedUrl: resolvedUrl
           ) {
            return metadata
        }
        if platform == .douyin,
           let metadata = try? await parseDouyinViaSharePage(
            originalUrl: extractedUrl,
            resolvedUrl: resolvedUrl
           ) {
            return metadata
        }
        if platform == .kuaishou,
           let metadata = try? await parseKuaishouViaSharePage(
            originalUrl: extractedUrl,
            resolvedUrl: resolvedUrl
           ) {
            return metadata
        }

        do {
            let infoData = try runYTDLP(arguments: ytdlpInfoArguments(
                for: platform,
                url: resolvedUrl
            )).standardOutput

            let info = try decodeInfo(from: infoData)
            let fallbackCoverURL = bestThumbnailURL(from: info, platform: platform)
            let genericCollection = requestYTDLPCollection(
                platform: platform,
                url: resolvedUrl
            )
            let sharedTitle = platform == .xiaohongshu
                ? xiaohongshuSharedTitle(from: inputText, extractedUrl: extractedUrl)
                : nil
            let xiaohongshuSupplement = platform == .xiaohongshu
                ? requestXiaohongshuSupplement(
                    url: info.webpage_url ?? resolvedUrl,
                    preferredNoteId: info.id,
                    fallbackCoverURL: fallbackCoverURL
                )
                : nil
            let title = textOrNil(xiaohongshuSupplement?.title) ?? sharedTitle ?? textOrNil(info.title) ?? "未命名视频"
            let id = info.id ?? UUID().uuidString
            let collection = genericCollection ?? ytdlpCollection(from: info, platform: platform)

            return VideoMetadata(
                id: id,
                originalUrl: extractedUrl,
                normalizedUrl: info.webpage_url ?? resolvedUrl,
                platform: platform.rawValue,
                platformName: platform.name,
                title: title,
                author: textOrNil(xiaohongshuSupplement?.author) ?? textOrNil(info.uploader) ?? textOrNil(info.channel) ?? "未知作者",
                publishedAt: textOrNil(xiaohongshuSupplement?.publishedAt) ?? formatDate(info: info),
                duration: formatDuration(info.duration),
                coverUrl: textOrNil(xiaohongshuSupplement?.coverUrl) ?? fallbackCoverURL,
                qualities: buildQualities(from: info),
                estimatedSizeMb: estimateSizeMb(from: info),
                parseMode: "real",
                note: "已通过 yt-dlp 解析公开视频信息；如平台限制访问，下载时会返回明确失败提示。",
                suggestedFilename: URLTools.sanitizeFilename(title),
                savedPath: nil,
                collection: collection
            )
        } catch {
            if platform == .bilibili,
               let metadata = try await parseBilibiliViaPublicAPI(
                originalUrl: extractedUrl,
                resolvedUrl: resolvedUrl
               ) {
                return metadata
            }
            if platform == .douyin,
               let metadata = try await parseDouyinViaSharePage(
                originalUrl: extractedUrl,
                resolvedUrl: resolvedUrl
               ) {
                return metadata
            }
            if platform == .douyin {
                throw UserFacingError("解析失败：抖音链接未返回公开视频信息，请重新复制当前作品分享链接后再试")
            }
            if platform == .kuaishou,
               let metadata = try await parseKuaishouViaSharePage(
                originalUrl: extractedUrl,
                resolvedUrl: resolvedUrl
               ) {
                return metadata
            }
            if platform == .toutiao,
               let metadata = try parseToutiaoViaMobilePage(
                originalUrl: extractedUrl,
                resolvedUrl: resolvedUrl
               ) {
                return metadata
            }
            throw error
        }
    }

    private func ytdlpInfoArguments(for platform: SupportedPlatform, url: String) -> [String] {
        let arguments = [
            "--add-header",
            "User-Agent:\(browserUserAgent)",
            "--add-header",
            "Referer:\(platform == .toutiao ? "https://www.toutiao.com/" : "https://www.bilibili.com/")",
            "--dump-single-json",
            "--no-warnings",
            "--no-playlist",
            "--socket-timeout",
            "20",
            url
        ]
        return arguments
    }

    private func ytdlpCollectionArguments(for platform: SupportedPlatform, url: String) -> [String] {
        var arguments = [
            "--add-header",
            "User-Agent:\(browserUserAgent)",
            "--add-header",
            "Referer:\(platform == .toutiao ? "https://www.toutiao.com/" : "https://www.bilibili.com/")",
            "--dump-single-json",
            "--flat-playlist",
            "--no-warnings",
            "--socket-timeout",
            "20"
        ]
        arguments.append(url)
        return arguments
    }

    private func requestYTDLPCollection(platform: SupportedPlatform, url: String) -> VideoCollection? {
        guard let data = try? runYTDLP(arguments: ytdlpCollectionArguments(for: platform, url: url)),
              let info = try? decoder.decode(YTDLPInfo.self, from: data.standardOutput) else {
            return nil
        }
        return ytdlpCollection(from: info, platform: platform)
    }

    private func ytdlpCollection(from info: YTDLPInfo, platform: SupportedPlatform) -> VideoCollection? {
        let entries = info.entries ?? []
        guard entries.count > 1 else {
            return nil
        }

        var seenURLs: Set<String> = []
        let items = entries.enumerated().compactMap { index, entry -> VideoCollectionItem? in
            guard let url = collectionItemURL(from: entry, platform: platform),
                  !seenURLs.contains(url) else {
                return nil
            }
            seenURLs.insert(url)
            let title = textOrNil(entry.title) ?? "第 \(index + 1) 集"
            return VideoCollectionItem(
                id: textOrNil(entry.id) ?? "\(platform.rawValue)-\(index + 1)",
                title: title,
                url: url,
                platform: platform.rawValue,
                duration: formatDuration(entry.duration),
                coverUrl: normalizedCoverUrl(entry.thumbnail),
                index: index + 1
            )
        }

        guard items.count > 1 else {
            return nil
        }
        return VideoCollection(
            id: info.id ?? UUID().uuidString,
            title: textOrNil(info.title) ?? "合集视频",
            items: items
        )
    }

    private func collectionItemURL(from entry: YTDLPInfo.Entry, platform: SupportedPlatform) -> String? {
        let rawURL = textOrNil(entry.webpage_url) ?? textOrNil(entry.url)
        if let rawURL, rawURL.hasPrefix("http") {
            return rawURL
        }
        if platform == .douyin,
           let id = textOrNil(entry.id) ?? rawURL,
           id.range(of: #"^\d+$"#, options: .regularExpression) != nil {
            return "https://www.douyin.com/video/\(id)"
        }
        if platform == .bilibili,
           let id = textOrNil(entry.id) ?? rawURL,
           id.range(of: #"^BV[0-9A-Za-z]{10}$"#, options: .regularExpression) != nil {
            return "https://www.bilibili.com/video/\(id)"
        }
        return nil
    }

    private func parseBilibiliViaPublicAPI(originalUrl: String, resolvedUrl: String) async throws -> VideoMetadata? {
        guard let bvid = extractBVID(from: resolvedUrl) ?? extractBVID(from: originalUrl) else {
            return nil
        }

        let item = try requestBilibiliViewItem(bvid: bvid)
        let playData = try? requestBilibiliPlayData(bvid: item.bvid, cid: item.cid)

        let title = item.title.isEmpty ? "未命名视频" : item.title
        let webpageUrl = "https://www.bilibili.com/video/\(item.bvid)"
        let collection = bilibiliCollection(from: item, fallbackCoverURL: normalizedCoverUrl(item.pic))

        return VideoMetadata(
            id: item.bvid,
            originalUrl: originalUrl,
            normalizedUrl: webpageUrl,
            platform: SupportedPlatform.bilibili.rawValue,
            platformName: SupportedPlatform.bilibili.name,
            title: title,
            author: item.owner?.name ?? "未知作者",
            publishedAt: formatTimestamp(item.pubdate),
            duration: formatDuration(Double(item.duration)),
            coverUrl: normalizedCoverUrl(item.pic),
            qualities: [
                QualityOption(
                    id: "best",
                    label: "最佳可用质量",
                    description: "解析信息来自 B 站公开接口，下载由 ffmpeg 合并可用音视频流",
                    available: true
                )
            ],
            estimatedSizeMb: estimateBilibiliSizeMb(from: playData, fallbackDuration: Double(item.duration)),
            parseMode: "real",
            note: "已通过 B 站公开接口解析视频信息；下载时会使用公开视频流并由 ffmpeg 合并。",
            suggestedFilename: URLTools.sanitizeFilename(title),
            savedPath: nil,
            collection: collection
        )
    }

    private func requestBilibiliViewItem(bvid: String) throws -> BilibiliViewResponse.DataItem {
        var components = URLComponents(string: "https://api.bilibili.com/x/web-interface/view")
        components?.queryItems = [URLQueryItem(name: "bvid", value: bvid)]
        guard let apiURL = components?.url else {
            throw UserFacingError("解析失败：B 站视频参数不完整")
        }

        var data: Data?
        for resolveArguments in curlResolveArgumentSets(for: apiURL.host) {
            data = try? runCurl(arguments: [
                "--fail",
                "--silent",
                "--show-error",
                "--location",
                "--max-time",
                "30",
                "-A",
                browserUserAgent,
                "-e",
                "https://www.bilibili.com/",
            ] + resolveArguments + [
                apiURL.absoluteString
            ], timeout: 10).standardOutput
            if data != nil {
                break
            }
        }
        guard let data else {
            throw UserFacingError("网络异常：无法连接 B 站公开解析接口")
        }

        let apiResponse: BilibiliViewResponse
        do {
            apiResponse = try decoder.decode(BilibiliViewResponse.self, from: data)
        } catch {
            throw UserFacingError("解析失败：无法读取 B 站视频信息")
        }
        guard apiResponse.code == 0, let item = apiResponse.data else {
            throw UserFacingError("解析失败：B 站未返回公开视频信息")
        }
        return item
    }

    private func bilibiliCollection(
        from item: BilibiliViewResponse.DataItem,
        fallbackCoverURL: String
    ) -> VideoCollection? {
        if let seasonCollection = bilibiliUGCSeasonCollection(from: item, fallbackCoverURL: fallbackCoverURL) {
            return seasonCollection
        }
        return bilibiliPageCollection(from: item, fallbackCoverURL: fallbackCoverURL)
    }

    private func bilibiliPageCollection(
        from item: BilibiliViewResponse.DataItem,
        fallbackCoverURL: String
    ) -> VideoCollection? {
        let pages = item.pages ?? []
        guard pages.count > 1 else {
            return nil
        }
        let webpageUrl = "https://www.bilibili.com/video/\(item.bvid)"
        let items = pages.enumerated().map { index, page in
            let pageNumber = page.page ?? index + 1
            let title = textOrNil(page.part) ?? "第 \(pageNumber) 集"
            return VideoCollectionItem(
                id: "\(item.bvid):\(page.cid)",
                title: title,
                url: "\(webpageUrl)?p=\(pageNumber)",
                platform: SupportedPlatform.bilibili.rawValue,
                duration: page.duration.map { formatDuration(Double($0)) },
                coverUrl: normalizedCoverUrl(page.first_frame) == "" ? fallbackCoverURL : normalizedCoverUrl(page.first_frame),
                index: pageNumber
            )
        }

        return VideoCollection(
            id: item.bvid,
            title: item.title,
            items: items
        )
    }

    private func bilibiliUGCSeasonCollection(
        from item: BilibiliViewResponse.DataItem,
        fallbackCoverURL: String
    ) -> VideoCollection? {
        guard let season = item.ugc_season else {
            return nil
        }
        let episodes = season.sections?.flatMap { $0.episodes ?? [] } ?? []
        guard episodes.count > 1 else {
            return nil
        }

        let items = episodes.enumerated().compactMap { index, episode -> VideoCollectionItem? in
            guard let bvid = textOrNil(episode.bvid) else {
                return nil
            }
            let title = textOrNil(episode.title) ?? "第 \(index + 1) 集"
            return VideoCollectionItem(
                id: "\(bvid):\(episode.cid.map(String.init) ?? "\(index + 1)")",
                title: title,
                url: "https://www.bilibili.com/video/\(bvid)",
                platform: SupportedPlatform.bilibili.rawValue,
                duration: episode.duration.map { formatDuration(Double($0)) },
                coverUrl: textOrNil(normalizedCoverUrl(episode.cover)) ?? fallbackCoverURL,
                index: index + 1
            )
        }

        guard items.count > 1 else {
            return nil
        }
        return VideoCollection(
            id: season.id.map { "ugc-season-\($0)" } ?? item.bvid,
            title: textOrNil(season.title) ?? item.title,
            items: items
        )
    }

    private func parseDouyinViaSharePage(originalUrl: String, resolvedUrl: String) async throws -> VideoMetadata? {
        guard let items = try? requestDouyinItems(urls: [originalUrl, resolvedUrl]),
              let item = items.first else {
            return nil
        }

        let rawDescription = item.desc?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = douyinTitle(from: rawDescription)
        let isImagePost = isDouyinImagePost(item)
        let canonicalUrl = douyinCanonicalUrl(for: item)
        let duration = douyinDisplayDuration(for: item)
        let mediaURL = isImagePost ? douyinAudioURL(from: item) : douyinNoWatermarkVideoURL(from: item)
        let coverURL = douyinCoverURL(from: item)

        return VideoMetadata(
            id: item.aweme_id,
            originalUrl: originalUrl,
            normalizedUrl: canonicalUrl,
            platform: SupportedPlatform.douyin.rawValue,
            platformName: SupportedPlatform.douyin.name,
            title: title,
            author: item.author?.nickname ?? "未知作者",
            publishedAt: formatTimestamp(item.create_time),
            duration: formatDuration(duration),
            coverUrl: normalizedCoverUrl(coverURL),
            qualities: [
                QualityOption(
                    id: isImagePost ? "note-share-page" : "no-watermark-share-page",
                    label: isImagePost ? "图文作品" : "无水印播放流",
                    description: isImagePost ? "解析信息来自抖音图文分享页" : "解析信息来自抖音移动分享页",
                    available: true
                )
            ],
            estimatedSizeMb: isImagePost
                ? estimateDouyinImagePostSizeMb(item)
                : estimateDouyinSizeMb(
                    playURL: mediaURL,
                    dataSizeBytes: item.video?.play_addr?.data_size,
                    duration: duration
                ),
            parseMode: "real",
            note: isImagePost
                ? "已通过抖音分享页解析图文作品；下载时会用无水印图片和原声音频在本机合成视频。"
                : "已通过抖音分享页解析公开视频信息；下载时会优先使用无水印实际播放流。",
            suggestedFilename: URLTools.sanitizeFilename(title),
            savedPath: nil,
            collection: douyinCollection(from: items)
        )
    }

    private func requestDouyinSharePage(url: String) throws -> Data {
        for resolveArguments in curlResolveArgumentSets(for: URL(string: url)?.host) {
            let data = try? runCurl(arguments: [
                "--fail",
                "--silent",
                "--show-error",
                "--location",
                "--max-time",
                "30",
                "-A",
                mobileUserAgent,
                "-e",
                "https://www.douyin.com/",
            ] + resolveArguments + [
                url
            ], timeout: 15).standardOutput
            if let data {
                return data
            }
        }
        throw UserFacingError("网络异常：无法连接抖音分享页")
    }

    private func decodeDouyinRouterData(from html: String) throws -> DouyinRouterData? {
        let pattern = #"window\._ROUTER_DATA\s*=\s*(\{.*?\})\s*</script>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)),
              let range = Range(match.range(at: 1), in: html),
              let data = String(html[range]).data(using: .utf8) else {
            return nil
        }
        return try decoder.decode(DouyinRouterData.self, from: data)
    }

    private func douyinTitle(from description: String) -> String {
        let firstLine = description
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? description
        let title = firstLine.isEmpty ? "未命名视频" : firstLine
        return String(title.prefix(80))
    }

    private func douyinDurationSeconds(_ rawDuration: Double?) -> Double? {
        guard let rawDuration, rawDuration > 0 else {
            return nil
        }
        return rawDuration > 1000 ? rawDuration / 1000 : rawDuration
    }

    private func isDouyinImagePost(_ item: DouyinRouterData.Item) -> Bool {
        !(item.images ?? []).isEmpty
    }

    private func douyinCanonicalUrl(for item: DouyinRouterData.Item) -> String {
        if isDouyinImagePost(item) {
            return "https://www.douyin.com/note/\(item.aweme_id)"
        }
        return "https://www.douyin.com/video/\(item.aweme_id)"
    }

    private func douyinDisplayDuration(for item: DouyinRouterData.Item) -> Double? {
        if isDouyinImagePost(item) {
            return douyinDurationSeconds(item.music?.duration)
        }
        return douyinDurationSeconds(item.video?.duration)
    }

    private func douyinCoverURL(from item: DouyinRouterData.Item) -> String? {
        item.video?.cover?.mediaURL ?? douyinImageURLs(from: item).first
    }

    private func douyinImageURLs(from item: DouyinRouterData.Item) -> [String] {
        (item.images ?? []).compactMap { image in
            textOrNil(image.url_list?.first) ?? textOrNil(image.download_url_list?.first)
        }
    }

    private func douyinAudioURL(from item: DouyinRouterData.Item) -> String? {
        if let uri = textOrNil(item.video?.play_addr?.uri),
           let url = URL(string: uri),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return uri
        }
        return item.video?.play_addr?.mediaURL
    }

    private func douyinNoWatermarkVideoURL(from item: DouyinRouterData.Item) -> String? {
        if let videoID = textOrNil(item.video?.play_addr?.uri),
           !videoID.lowercased().hasPrefix("http") {
            return "https://aweme.snssdk.com/aweme/v1/play/?video_id=\(videoID)&ratio=720p&line=0"
        }

        return item.video?.play_addr?.url_list?
            .compactMap { douyinNoWatermarkURL(from: $0) }
            .first
    }

    private func douyinNoWatermarkURL(from url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if trimmed.contains("/playwm/") {
            return trimmed.replacingOccurrences(of: "/playwm/", with: "/play/")
        }
        return trimmed
    }

    private func estimateDouyinSizeMb(playURL: String?, dataSizeBytes: Double?, duration: Double?) -> Double? {
        if let playURL,
           let byteSize = requestMediaContentLength(url: playURL),
           byteSize > 1024 {
            return megabytes(fromBytes: Double(byteSize))
        }
        if let byteSize = byteCount(from: dataSizeBytes) {
            return megabytes(fromBytes: Double(byteSize))
        }

        guard let playURL,
              let duration,
              let bitrate = URLComponents(string: playURL)?
                .queryItems?
                .first(where: { $0.name == "br" || $0.name == "bt" })?
                .value
                .flatMap(Double.init) else {
            return nil
        }
        return megabytes(fromBytes: estimatedBytes(fromKbps: bitrate, duration: duration))
    }

    private func estimateDouyinImagePostSizeMb(_ item: DouyinRouterData.Item) -> Double? {
        var totalBytes: Int64 = 0
        var hasAnySize = false
        if let audioURL = douyinAudioURL(from: item),
           let audioBytes = requestMediaContentLength(url: audioURL) {
            totalBytes += audioBytes
            hasAnySize = true
        }
        for imageURL in douyinImageURLs(from: item) {
            if let imageBytes = requestMediaContentLength(url: imageURL) {
                totalBytes += imageBytes
                hasAnySize = true
            }
        }
        return hasAnySize ? megabytes(fromBytes: Double(totalBytes)) : nil
    }

    private func byteCount(from dataSizeBytes: Double?) -> Int64? {
        guard let dataSizeBytes, dataSizeBytes.isFinite, dataSizeBytes > 0 else {
            return nil
        }
        return Int64(dataSizeBytes.rounded())
    }

    private func parseKuaishouViaSharePage(originalUrl: String, resolvedUrl: String) async throws -> VideoMetadata? {
        let item = try requestKuaishouPhoto(urls: [resolvedUrl, originalUrl])
        let representations = kuaishouRepresentations(from: item)
        let bestRepresentation = bestKuaishouRepresentation(from: representations)
        let mediaURL = kuaishouMediaURL(from: bestRepresentation) ?? item.mainMvUrls?.compactMap(\.url).first
        let coverURL = normalizedCoverUrl(item.coverUrls?.compactMap(\.url).first ?? item.webpCoverUrls?.compactMap(\.url).first)
        let embeddedCover = embeddedImageDataURL(
            url: coverURL,
            referer: "https://m.kuaishou.com/"
        )
        let title = kuaishouTitle(from: item.caption)
        let duration = kuaishouDurationSeconds(item.duration ?? item.manifest?.adaptationSet?.compactMap(\.duration).first)
        let mediaByteSize = mediaURL
            .flatMap { requestMediaContentLength(url: $0, userAgent: kuaishouUserAgent, referer: "https://m.kuaishou.com/") }
            .map(Double.init)
        let estimatedSize = megabytes(fromBytes: bestRepresentation?.fileSize) ?? megabytes(fromBytes: mediaByteSize)

        return VideoMetadata(
            id: preferredKuaishouPhotoId(from: resolvedUrl)
                ?? kuaishouSharePhotoId(from: item.share_info)
                ?? item.photoId
                ?? preferredKuaishouPhotoId(from: originalUrl)
                ?? UUID().uuidString,
            originalUrl: originalUrl,
            normalizedUrl: resolvedUrl,
            platform: SupportedPlatform.kuaishou.rawValue,
            platformName: SupportedPlatform.kuaishou.name,
            title: title,
            author: textOrNil(item.userName) ?? "未知作者",
            publishedAt: formatFlexibleTimestamp(item.timestamp) ?? "未知日期",
            duration: formatDuration(duration),
            coverUrl: embeddedCover ?? coverURL,
            qualities: buildKuaishouQualities(from: representations),
            estimatedSizeMb: estimatedSize,
            parseMode: "real",
            note: "已通过快手分享页解析公开视频信息；下载时会使用分享页返回的公开视频地址。",
            suggestedFilename: URLTools.sanitizeFilename(title),
            savedPath: nil
        )
    }

    private func requestKuaishouPhoto(urls: [String]) throws -> KuaishouInitialState.Photo {
        for url in kuaishouCandidateURLs(from: urls) {
            guard let htmlData = requestKuaishouPage(url: url),
                  let html = String(data: htmlData, encoding: .utf8),
                  let state = decodeKuaishouInitialState(from: html),
                  let photo = selectKuaishouPhoto(
                    from: state,
                    preferredPhotoId: preferredKuaishouPhotoId(from: url)
                  ) else {
                continue
            }
            return photo
        }
        throw UserFacingError("解析失败：无法读取快手视频信息")
    }

    private func requestKuaishouPage(url: String) -> Data? {
        let curlPath = "/usr/bin/curl"
        guard FileManager.default.isExecutableFile(atPath: curlPath) else {
            return nil
        }

        for resolveArguments in curlResolveArgumentSets(for: URL(string: url)?.host) {
            guard let result = try? runProcess(
                executable: curlPath,
                arguments: [
                    "--fail",
                    "--silent",
                    "--show-error",
                    "--location",
                    "--max-time",
                    "30",
                    "-A",
                    kuaishouUserAgent,
                    "-e",
                    "https://v.kuaishou.com/"
                ] + resolveArguments + [
                    url
                ],
                timeout: 35
            ),
                result.exitCode == 0 else {
                continue
            }
            return result.standardOutput
        }

        return nil
    }

    private func decodeKuaishouInitialState(from html: String) -> KuaishouInitialState? {
        let pattern = #"window\.INIT_STATE\s*=\s*(\{.*?\})\s*</script>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)),
              let range = Range(match.range(at: 1), in: html),
              let data = String(html[range]).data(using: .utf8) else {
            return nil
        }
        return try? decoder.decode(KuaishouInitialState.self, from: data)
    }

    private func selectKuaishouPhoto(
        from state: KuaishouInitialState,
        preferredPhotoId: String?
    ) -> KuaishouInitialState.Photo? {
        let photos = state.pages.compactMap(\.photo)
        if let preferredPhotoId,
           let photo = photos.first(where: { photo in
            photo.photoId == preferredPhotoId || (photo.share_info?.contains("photoId=\(preferredPhotoId)") ?? false)
           }) {
            return photo
        }
        return photos.first { photo in
            kuaishouMediaURL(from: bestKuaishouRepresentation(from: kuaishouRepresentations(from: photo))) != nil
                || !(photo.mainMvUrls?.compactMap(\.url).isEmpty ?? true)
        } ?? photos.first
    }

    private func kuaishouCandidateURLs(from urls: [String]) -> [String] {
        var candidates: [String] = []
        for url in urls where !url.isEmpty {
            appendUnique(url, to: &candidates)
            if let corrected = correctedKuaishouShortURL(url) {
                appendUnique(corrected, to: &candidates)
            }
        }
        return candidates
    }

    private func correctedKuaishouShortURL(_ url: String) -> String? {
        guard var components = URLComponents(string: url),
              components.host?.lowercased() == "v.kuaishou.com" else {
            return nil
        }
        let path = components.path
        let correctedPath = path.replacingOccurrences(of: "O", with: "0")
        guard correctedPath != path else {
            return nil
        }
        components.path = correctedPath
        return components.url?.absoluteString
    }

    private func appendUnique(_ value: String, to values: inout [String]) {
        guard !values.contains(value) else {
            return
        }
        values.append(value)
    }

    private func preferredKuaishouPhotoId(from url: String) -> String? {
        guard let components = URLComponents(string: url) else {
            return nil
        }
        if let photoId = components.queryItems?.first(where: { $0.name == "photoId" })?.value,
           !photoId.isEmpty {
            return photoId
        }
        let pathComponents = components.path.split(separator: "/").map(String.init)
        if let photoIndex = pathComponents.firstIndex(of: "photo"),
           pathComponents.indices.contains(photoIndex + 1) {
            return pathComponents[photoIndex + 1]
        }
        return pathComponents.last
    }

    private func kuaishouSharePhotoId(from shareInfo: String?) -> String? {
        guard let shareInfo,
              let components = URLComponents(string: "https://kuaishou.local/?\(shareInfo)") else {
            return nil
        }
        return components.queryItems?.first(where: { $0.name == "photoId" })?.value
    }

    private func kuaishouRepresentations(from photo: KuaishouInitialState.Photo) -> [KuaishouInitialState.Representation] {
        photo.manifest?.adaptationSet?.flatMap { $0.representation ?? [] } ?? []
    }

    private func bestKuaishouRepresentation(
        from representations: [KuaishouInitialState.Representation]
    ) -> KuaishouInitialState.Representation? {
        representations
            .filter { kuaishouMediaURL(from: $0) != nil }
            .max { left, right in
                let leftScore = (left.height ?? 0, left.width ?? 0, left.avgBitrate ?? 0, left.fileSize ?? 0)
                let rightScore = (right.height ?? 0, right.width ?? 0, right.avgBitrate ?? 0, right.fileSize ?? 0)
                return leftScore < rightScore
            }
    }

    private func kuaishouMediaURL(from representation: KuaishouInitialState.Representation?) -> String? {
        guard let representation else {
            return nil
        }
        return textOrNil(representation.url) ?? representation.backupUrl?.compactMap { textOrNil($0) }.first
    }

    private func buildKuaishouQualities(from representations: [KuaishouInitialState.Representation]) -> [QualityOption] {
        let qualities = representations
            .filter { kuaishouMediaURL(from: $0) != nil }
            .sorted { left, right in
                let leftScore = (left.height ?? 0, left.avgBitrate ?? 0)
                let rightScore = (right.height ?? 0, right.avgBitrate ?? 0)
                return leftScore > rightScore
            }
            .prefix(6)
            .map { representation in
                let heightLabel = representation.height.map { "\($0)p" }
                let label = representation.qualityLabel ?? representation.qualityType ?? heightLabel ?? "可下载格式"
                let sizeText = megabytes(fromBytes: representation.fileSize).map { "约 \($0) MB" } ?? "大小未知"
                return QualityOption(
                    id: representation.id.map(String.init) ?? label,
                    label: label,
                    description: "\(representation.videoCodec ?? "mp4")，\(sizeText)",
                    available: true
                )
            }

        if qualities.isEmpty {
            return [
                QualityOption(
                    id: "share-page",
                    label: "公开视频信息",
                    description: "解析信息来自快手分享页",
                    available: true
                )
            ]
        }
        return Array(qualities)
    }

    private func kuaishouTitle(from caption: String?) -> String {
        let title = textOrNil(caption) ?? "未命名视频"
        return String(title.prefix(80))
    }

    private func kuaishouDurationSeconds(_ rawDuration: Double?) -> Double? {
        guard let rawDuration, rawDuration > 0 else {
            return nil
        }
        return rawDuration > 1000 ? rawDuration / 1000 : rawDuration
    }

    private func parseToutiaoViaMobilePage(
        originalUrl: String,
        resolvedUrl: String
    ) throws -> VideoMetadata? {
        guard let profile = try requestToutiaoDirectProfile(url: resolvedUrl) else {
            return nil
        }
        let article = profile.article
        let title = textOrNil(article.title) ?? "未命名视频"
        let author = textOrNil(article.mediaUser?.screenName)
            ?? textOrNil(article.detailSource)
            ?? "未知作者"
        let publishedTimestamp = article.publishTime.flatMap(Double.init)

        return VideoMetadata(
            id: textOrNil(article.gid) ?? textOrNil(article.videoId) ?? UUID().uuidString,
            originalUrl: originalUrl,
            normalizedUrl: resolvedUrl,
            platform: SupportedPlatform.toutiao.rawValue,
            platformName: SupportedPlatform.toutiao.name,
            title: title,
            author: author,
            publishedAt: formatFlexibleTimestamp(publishedTimestamp) ?? "未知日期",
            duration: formatDuration(profile.duration),
            coverUrl: textOrNil(profile.coverURL) ?? "",
            qualities: buildToutiaoQualities(from: profile.formats),
            estimatedSizeMb: profile.totalBytes.flatMap { megabytes(fromBytes: Double($0)) },
            parseMode: "real",
            note: "已通过今日头条移动分享页解析公开视频信息；下载时会使用分享页返回的实际播放内容。",
            suggestedFilename: URLTools.sanitizeFilename(title),
            savedPath: nil,
            directMediaUrl: profile.mediaURL
        )
    }

    private func requestToutiaoDirectProfile(url: String) throws -> ToutiaoDirectProfile? {
        guard let htmlData = requestToutiaoMobilePage(url: url),
              let html = String(data: htmlData, encoding: .utf8),
              let renderData = decodeToutiaoRenderData(from: html),
              let article = renderData.articleInfo,
              let token = textOrNil(article.playAuthTokenV2),
              let tokenData = Data(base64Encoded: token),
              let playQuery = textOrNil((try? decoder.decode(ToutiaoPlayToken.self, from: tokenData))?.query),
              let vodData = requestToutiaoVODData(playQuery: playQuery, referer: url),
              vodData.status == 10 else {
            return nil
        }

        let formats = (vodData.playInfoList ?? []).filter { toutiaoMediaURL(from: $0) != nil }
        guard let selectedFormat = bestToutiaoFormat(from: formats),
              let mediaURL = toutiaoMediaURL(from: selectedFormat) else {
            return nil
        }

        return ToutiaoDirectProfile(
            article: article,
            formats: formats,
            selectedFormat: selectedFormat,
            mediaURL: mediaURL,
            duration: selectedFormat.duration ?? vodData.duration ?? article.videoDuration,
            totalBytes: selectedFormat.size,
            coverURL: textOrNil(vodData.coverUrl) ?? textOrNil(article.posterUrl)
        )
    }

    private func requestToutiaoMobilePage(url: String) -> Data? {
        let curlPath = "/usr/bin/curl"
        guard FileManager.default.isExecutableFile(atPath: curlPath) else {
            return nil
        }

        for resolveArguments in curlResolveArgumentSets(for: URL(string: url)?.host) {
            guard let result = try? runProcess(
                executable: curlPath,
                arguments: [
                    "--fail",
                    "--silent",
                    "--show-error",
                    "--location",
                    "--max-time",
                    "30",
                    "-A",
                    mobileUserAgent,
                    "-e",
                    "https://m.toutiao.com/"
                ] + resolveArguments + [url],
                timeout: 35
            ), result.exitCode == 0 else {
                continue
            }
            return result.standardOutput
        }
        return nil
    }

    private func decodeToutiaoRenderData(from html: String) -> ToutiaoRenderData? {
        let pattern = #"<script[^>]*id=[\"']RENDER_DATA[\"'][^>]*>(.*?)</script>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)),
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }
        let encodedPayload = String(html[range])
        let payload = encodedPayload.removingPercentEncoding ?? encodedPayload
        guard let data = payload.data(using: .utf8) else {
            return nil
        }
        return try? decoder.decode(ToutiaoRenderData.self, from: data)
    }

    private func requestToutiaoVODData(
        playQuery: String,
        referer: String
    ) -> ToutiaoVODResponse.DataItem? {
        let endpoint = "https://vod.bytedanceapi.com/?\(playQuery)"
        for resolveArguments in curlResolveArgumentSets(for: URL(string: endpoint)?.host) {
            guard let result = try? runProcess(
                executable: "/usr/bin/curl",
                arguments: [
                    "--fail",
                    "--silent",
                    "--show-error",
                    "--max-time",
                    "30",
                    "-A",
                    mobileUserAgent,
                    "-e",
                    referer
                ] + resolveArguments + [endpoint],
                timeout: 35
            ), result.exitCode == 0,
              let response = try? decoder.decode(ToutiaoVODResponse.self, from: result.standardOutput) else {
                continue
            }
            return response.result?.data
        }
        return nil
    }

    private func bestToutiaoFormat(
        from formats: [ToutiaoVODResponse.PlayInfo]
    ) -> ToutiaoVODResponse.PlayInfo? {
        formats.max { left, right in
            let leftScore = (left.height ?? 0, left.width ?? 0, left.bitrate ?? 0, left.size ?? 0)
            let rightScore = (right.height ?? 0, right.width ?? 0, right.bitrate ?? 0, right.size ?? 0)
            return leftScore < rightScore
        }
    }

    private func toutiaoMediaURL(from format: ToutiaoVODResponse.PlayInfo) -> String? {
        [format.mainPlayUrl, format.backupPlayUrl]
            .compactMap { textOrNil($0) }
            .first { URL(string: $0)?.scheme?.lowercased().hasPrefix("http") == true }
    }

    private func buildToutiaoQualities(
        from formats: [ToutiaoVODResponse.PlayInfo]
    ) -> [QualityOption] {
        formats
            .sorted { left, right in
                (left.height ?? 0, left.bitrate ?? 0) > (right.height ?? 0, right.bitrate ?? 0)
            }
            .prefix(6)
            .enumerated()
            .map { index, format in
                let label = textOrNil(format.definition) ?? format.height.map { "\($0)p" } ?? "可下载格式"
                let dimensions = [format.width, format.height]
                    .compactMap { $0 }
                    .map(String.init)
                    .joined(separator: "x")
                let sizeText = format.size
                    .flatMap { megabytes(fromBytes: Double($0)) }
                    .map { "约 \($0) MB" }
                    ?? "大小未知"
                let description = [dimensions, textOrNil(format.codec), sizeText]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
                return QualityOption(
                    id: "toutiao-\(index)-\(label)",
                    label: label,
                    description: description,
                    available: true
                )
            }
    }

    private func parseWeChatChannelsPublic(
        originalUrl: String,
        resolvedUrl: String
    ) async throws -> VideoMetadata {
        guard let shortURI = weChatChannelsShortURI(from: resolvedUrl)
            ?? weChatChannelsShortURI(from: originalUrl) else {
            throw UserFacingError("解析失败：未识别到微信视频号分享标识")
        }

        let response = try await requestWeChatChannelsFeed(shortURI: shortURI)
        if let errCode = response.errCode, errCode != 0 {
            throw UserFacingError("解析失败：\(textOrNil(response.errMsg) ?? "微信视频号未返回公开内容")")
        }
        guard let data = response.data,
              let feedInfo = data.feedInfo else {
            throw UserFacingError("解析失败：该微信视频号内容已失效或不可公开访问")
        }

        let title = textOrNil(feedInfo.description) ?? "未命名视频"
        let shareURL = "https://weixin.qq.com/sph/\(shortURI)"
        var mediaProfile: WeChatChannelsMediaProfile?
        if let parseResponse = await WeChatChannelsAuthorization.shared.parseIfAuthorized(shareURL: shareURL) {
            mediaProfile = try? await weChatChannelsMediaProfile(from: parseResponse)
        }
        let canonicalURL = "https://channels.weixin.qq.com/finder-preview/pages/sph?id=\(shortURI)"
        return VideoMetadata(
            id: textOrNil(data.sceneInfo?.dynamicExportId) ?? shortURI,
            originalUrl: originalUrl,
            normalizedUrl: canonicalURL,
            platform: SupportedPlatform.wechatChannels.rawValue,
            platformName: SupportedPlatform.wechatChannels.name,
            title: title,
            author: textOrNil(data.authorInfo?.nickname) ?? "未知作者",
            publishedAt: formatFlexibleTimestamp(feedInfo.createtime) ?? "未知日期",
            duration: mediaProfile?.duration.map(formatDuration) ?? "登录后获取",
            coverUrl: textOrNil(feedInfo.coverUrl) ?? "",
            qualities: [
                QualityOption(
                    id: "source",
                    label: "原始画质",
                    description: "微信视频号实际播放内容",
                    available: true
                )
            ],
            estimatedSizeMb: mediaProfile?.totalBytes.flatMap { megabytes(fromBytes: Double($0)) },
            parseMode: "real",
            note: "已通过微信视频号官方预览接口解析；首次下载时需在独立的腾讯元宝窗口完成授权。",
            suggestedFilename: URLTools.sanitizeFilename(title),
            savedPath: nil
        )
    }

    private func weChatChannelsShortURI(from rawURL: String) -> String? {
        guard let url = URL(string: rawURL),
              let host = url.host?.lowercased() else {
            return nil
        }
        if host == "weixin.qq.com" {
            let components = url.path.split(separator: "/")
            if components.count >= 2, components[0] == "sph" {
                return textOrNil(String(components[1]))
            }
        }
        if host == "channels.weixin.qq.com",
           url.path == "/finder-preview/pages/sph",
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            return components.queryItems?
                .first(where: { $0.name == "id" })?
                .value
                .flatMap(textOrNil)
        }
        return nil
    }

    private func requestWeChatChannelsFeed(shortURI: String) async throws -> WeChatChannelsFeedResponse {
        guard let url = URL(string: "https://channels.weixin.qq.com/finder-preview/api/feed/get_feed_info") else {
            throw UserFacingError("解析失败：微信视频号接口地址无效")
        }
        let payload: [String: Any] = [
            "baseReq": ["generalToken": ""],
            "shortUri": shortURI
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://channels.weixin.qq.com", forHTTPHeaderField: "Origin")
        request.setValue(
            "https://channels.weixin.qq.com/finder-preview/pages/sph?id=\(shortURI)",
            forHTTPHeaderField: "Referer"
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw UserFacingError("解析失败：微信视频号公开接口暂时不可用")
        }
        do {
            return try decoder.decode(WeChatChannelsFeedResponse.self, from: data)
        } catch {
            throw UserFacingError("解析失败：微信视频号返回了无法识别的数据")
        }
    }

    private func resolveShareUrlIfNeeded(_ normalizedUrl: String, platform: SupportedPlatform) async throws -> String {
        let host = URL(string: normalizedUrl)?.host?.lowercased()
        if platform == .bilibili,
           host == "b23.tv",
           let redirectURL = try resolveRedirectWithCurl(normalizedUrl) {
            return redirectURL
        }
        if platform == .kuaishou,
           host == "v.kuaishou.com",
           let redirectURL = try resolveRedirectWithCurl(
            normalizedUrl,
            userAgent: kuaishouUserAgent,
            referer: "https://v.kuaishou.com/"
           ) {
            return redirectURL
        }
        if platform == .toutiao,
           isToutiaoShortLink(normalizedUrl),
           let redirectURL = try resolveRedirectWithCurl(
            normalizedUrl,
            userAgent: mobileUserAgent,
            referer: "https://m.toutiao.com/"
           ) {
            return absoluteRedirectURL(redirectURL, relativeTo: normalizedUrl)
        }
        return normalizedUrl
    }

    private func isToutiaoShortLink(_ url: String) -> Bool {
        guard let components = URLComponents(string: url),
              let host = components.host?.lowercased(),
              host == "toutiao.com" || host.hasSuffix(".toutiao.com") else {
            return false
        }
        return components.path.hasPrefix("/is/")
    }

    private func absoluteRedirectURL(_ redirectURL: String, relativeTo baseURL: String) -> String {
        guard let base = URL(string: baseURL),
              let resolved = URL(string: redirectURL, relativeTo: base) else {
            return redirectURL
        }
        return resolved.absoluteURL.absoluteString
    }

    private func resolveRedirectWithCurl(_ url: String, userAgent: String? = nil, referer: String? = nil) throws -> String? {
        let curlPath = "/usr/bin/curl"
        guard FileManager.default.isExecutableFile(atPath: curlPath) else {
            return nil
        }
        var arguments = [
            "--silent",
            "--show-error",
            "--head",
            "--dump-header",
            "-",
            "--output",
            "/dev/null",
            "--max-redirs",
            "0",
            "--max-time",
            "20",
            "-A",
            userAgent ?? browserUserAgent
        ]
        if let referer {
            arguments += ["-e", referer]
        }
        for resolveArguments in curlResolveArgumentSets(for: URL(string: url)?.host) {
            let result = try runProcess(
                executable: curlPath,
                arguments: arguments + resolveArguments + [
                    url
                ],
                timeout: 22
            )
            guard result.exitCode == 0 else {
                continue
            }

            let headerText = [
                String(data: result.standardOutput, encoding: .utf8),
                String(data: result.standardError, encoding: .utf8)
            ]
                .compactMap { $0 }
                .joined(separator: "\n")
            for line in headerText.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.lowercased().hasPrefix("location:") {
                    return String(trimmed.dropFirst("location:".count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return nil
    }

    private func curlResolveArgumentSets(for host: String?) -> [[String]] {
        guard let host else {
            return [[]]
        }
        let resolved = resolvePublicIPv4Candidates(host: host)
            .map { ["--resolve", "\(host):443:\($0)"] }
        return resolved.isEmpty ? [[]] : resolved + [[]]
    }

    private func resolvePublicIPv4Candidates(host: String) -> [String] {
        let digPath = "/usr/bin/dig"
        guard FileManager.default.isExecutableFile(atPath: digPath) else {
            return []
        }

        var candidates: [String] = []
        for server in ["223.5.5.5", "119.29.29.29"] {
            guard let result = try? runProcess(
                executable: digPath,
                arguments: ["@\(server)", "+time=3", "+tries=1", "+short", host],
                timeout: 5
            ),
                result.exitCode == 0,
                let output = String(data: result.standardOutput, encoding: .utf8) else {
                continue
            }

            for line in output.components(separatedBy: .newlines) {
                let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if isUsableIPv4(value), !candidates.contains(value) {
                    candidates.append(value)
                }
            }
        }
        return candidates
    }

    private func isUsableIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".")
        guard parts.count == 4,
              let first = Int(parts[0]),
              let second = Int(parts[1]),
              parts.allSatisfy({ Int($0) != nil }) else {
            return false
        }
        return !(first == 198 && (18...19).contains(second))
    }

    private func extractBVID(from urlText: String) -> String? {
        let pattern = #"BV[0-9A-Za-z]{10}"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: urlText, range: NSRange(urlText.startIndex..<urlText.endIndex, in: urlText)),
              let range = Range(match.range, in: urlText) else {
            return nil
        }
        return String(urlText[range])
    }

    private func normalizedCoverUrl(_ value: String?) -> String {
        guard let value, !value.isEmpty else {
            return ""
        }
        if value.hasPrefix("//") {
            return "https:\(value)"
        }
        if value.hasPrefix("http://") {
            return "https://" + value.dropFirst("http://".count)
        }
        return value
    }

    private func bestThumbnailURL(from info: YTDLPInfo, platform: SupportedPlatform) -> String {
        let rawThumbnailURL = info.thumbnail ?? info.thumbnails?.compactMap(\.url).last
        guard platform == .xiaohongshu else {
            return rawThumbnailURL ?? ""
        }
        return normalizedCoverUrl(rawThumbnailURL)
    }

    private func xiaohongshuSharedTitle(from inputText: String, extractedUrl: String) -> String? {
        guard let urlRange = inputText.range(of: extractedUrl) else {
            return nil
        }
        return normalizedXiaohongshuTitle(String(inputText[..<urlRange.lowerBound]))
    }

    private func normalizedXiaohongshuTitle(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let collapsed = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(
                CharacterSet(charactersIn: "，。,.、；;：:！!？?\"'“”‘’【】[]()（）")
            )
        )
        guard !trimmed.isEmpty else {
            return nil
        }
        return String(trimmed.prefix(80))
    }

    private func requestXiaohongshuSupplement(
        url: String,
        preferredNoteId: String?,
        fallbackCoverURL: String
    ) -> XiaohongshuSupplement? {
        guard let htmlData = requestXiaohongshuPage(url: url),
              let html = String(data: htmlData, encoding: .utf8),
              let state = decodeXiaohongshuInitialState(from: html) else {
            return nil
        }

        let notes = state.note?.noteDetailMap?.values.compactMap(\.note) ?? []
        guard let note = notes.first(where: { $0.noteId == preferredNoteId }) ?? notes.first else {
            return nil
        }

        let rawCoverURL = xiaohongshuCoverURL(from: note.imageList) ?? fallbackCoverURL
        let normalizedCover = normalizedCoverUrl(rawCoverURL)
        let embeddedCover = embeddedImageDataURL(
            url: normalizedCover,
            referer: "https://www.xiaohongshu.com/"
        )

        return XiaohongshuSupplement(
            title: normalizedXiaohongshuTitle(note.title) ?? normalizedXiaohongshuTitle(note.desc),
            author: note.user?.nickname,
            publishedAt: formatFlexibleTimestamp(note.time ?? note.lastUpdateTime),
            coverUrl: embeddedCover ?? textOrNil(normalizedCover)
        )
    }

    private func requestXiaohongshuPage(url: String) -> Data? {
        let curlPath = "/usr/bin/curl"
        guard FileManager.default.isExecutableFile(atPath: curlPath) else {
            return nil
        }

        for resolveArguments in curlResolveArgumentSets(for: URL(string: url)?.host) {
            guard let result = try? runProcess(
                executable: curlPath,
                arguments: [
                    "--fail",
                    "--silent",
                    "--show-error",
                    "--location",
                    "--max-time",
                    "30",
                    "-A",
                    browserUserAgent,
                    "-e",
                    "https://www.xiaohongshu.com/"
                ] + resolveArguments + [
                    url
                ],
                timeout: 35
            ),
                result.exitCode == 0 else {
                continue
            }
            return result.standardOutput
        }

        return nil
    }

    private func decodeXiaohongshuInitialState(from html: String) -> XiaohongshuInitialState? {
        let pattern = #"window\.__INITIAL_STATE__\s*=\s*(\{.*?\})\s*</script>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)),
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }

        let jsonText = String(html[range])
            .replacingOccurrences(of: ":undefined", with: ":null")
            .replacingOccurrences(of: "[undefined", with: "[null")
            .replacingOccurrences(of: ",undefined", with: ",null")
            .replacingOccurrences(of: "undefined,", with: "null,")
        guard let data = jsonText.data(using: .utf8) else {
            return nil
        }
        return try? decoder.decode(XiaohongshuInitialState.self, from: data)
    }

    private func xiaohongshuCoverURL(from imageList: [XiaohongshuInitialState.ImageItem]?) -> String? {
        guard let imageList else {
            return nil
        }

        for image in imageList {
            if let url = textOrNil(image.urlDefault) {
                return url
            }
            if let url = image.infoList?.first(where: { $0.imageScene == "WB_DFT" }).flatMap({ textOrNil($0.url) }) {
                return url
            }
            if let url = textOrNil(image.urlPre) {
                return url
            }
            if let url = image.infoList?.compactMap({ textOrNil($0.url) }).first {
                return url
            }
            if let url = textOrNil(image.url) {
                return url
            }
        }

        return nil
    }

    private func embeddedImageDataURL(url: String, referer: String) -> String? {
        guard textOrNil(url) != nil,
              url.hasPrefix("http"),
              let urlHost = URL(string: url)?.host else {
            return nil
        }
        let curlPath = "/usr/bin/curl"
        guard FileManager.default.isExecutableFile(atPath: curlPath) else {
            return nil
        }

        for resolveArguments in curlResolveArgumentSets(for: urlHost) {
            guard let result = try? runProcess(
                executable: curlPath,
                arguments: [
                    "--fail",
                    "--silent",
                    "--show-error",
                    "--location",
                    "--max-time",
                    "20",
                    "-A",
                    browserUserAgent,
                    "-e",
                    referer
                ] + resolveArguments + [
                    url
                ],
                timeout: 25
            ),
                result.exitCode == 0,
                !result.standardOutput.isEmpty,
                result.standardOutput.count <= 2_500_000,
                let mimeType = imageMimeType(for: result.standardOutput) else {
                continue
            }
            return "data:\(mimeType);base64,\(result.standardOutput.base64EncodedString())"
        }

        return nil
    }

    private func imageMimeType(for data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "image/jpeg"
        }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return "image/png"
        }
        if bytes.starts(with: [0x47, 0x49, 0x46]) {
            return "image/gif"
        }
        if bytes.count >= 12,
           bytes[0...3] == [0x52, 0x49, 0x46, 0x46],
           bytes[8...11] == [0x57, 0x45, 0x42, 0x50] {
            return "image/webp"
        }
        return nil
    }

    private func imageFileExtension(for mimeType: String?) -> String? {
        switch mimeType?.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "image/jpeg", "image/jpg":
            return "jpg"
        case "image/png":
            return "png"
        case "image/gif":
            return "gif"
        case "image/webp":
            return "webp"
        default:
            return nil
        }
    }

    private func imageFileExtension(fromPathExtension pathExtension: String) -> String? {
        switch pathExtension.lowercased() {
        case "jpg", "jpeg":
            return "jpg"
        case "png", "gif", "webp":
            return pathExtension.lowercased()
        default:
            return nil
        }
    }

    private func loadCoverImage(from source: String, referer: String?) async throws -> CoverImageData {
        if source.lowercased().hasPrefix("data:") {
            return try decodeCoverDataURL(source)
        }

        guard let url = URL(string: source),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw UserFacingError("封面下载失败：封面地址无效")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        if let referer = textOrNil(referer) {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw UserFacingError("封面下载失败：图片请求被拒绝")
        }

        let detectedMimeType = imageMimeType(for: data)
        let fileExtension = imageFileExtension(for: detectedMimeType)
            ?? imageFileExtension(for: response.mimeType)
            ?? imageFileExtension(fromPathExtension: url.pathExtension)
        guard !data.isEmpty, let fileExtension else {
            throw UserFacingError("封面下载失败：未获取到有效图片")
        }

        return CoverImageData(data: data, fileExtension: fileExtension)
    }

    private func decodeCoverDataURL(_ source: String) throws -> CoverImageData {
        guard let separatorRange = source.range(of: ",") else {
            throw UserFacingError("封面下载失败：封面数据格式不正确")
        }

        let header = String(source[..<separatorRange.lowerBound])
        let payload = String(source[separatorRange.upperBound...])
        guard header.lowercased().hasPrefix("data:image/") else {
            throw UserFacingError("封面下载失败：封面数据不是图片")
        }

        let declaredMimeType = header
            .dropFirst("data:".count)
            .split(separator: ";")
            .first
            .map(String.init)
        let decodedData: Data?
        if header.lowercased().contains(";base64") {
            decodedData = Data(base64Encoded: payload.removingPercentEncoding ?? payload)
        } else {
            decodedData = (payload.removingPercentEncoding ?? payload).data(using: .utf8)
        }

        guard let data = decodedData, !data.isEmpty else {
            throw UserFacingError("封面下载失败：封面数据为空")
        }

        let fileExtension = imageFileExtension(for: imageMimeType(for: data))
            ?? imageFileExtension(for: declaredMimeType)
        guard let fileExtension else {
            throw UserFacingError("封面下载失败：封面数据不是有效图片")
        }

        return CoverImageData(data: data, fileExtension: fileExtension)
    }

    private func textOrNil(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func formatFlexibleTimestamp(_ timestamp: Double?) -> String? {
        guard let timestamp, timestamp > 0 else {
            return nil
        }
        let seconds = timestamp > 10_000_000_000 ? timestamp / 1000 : timestamp
        let date = Date(timeIntervalSince1970: seconds)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func formatTimestamp(_ timestamp: Double?) -> String {
        guard let timestamp else {
            return "未知日期"
        }
        let date = Date(timeIntervalSince1970: timestamp)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    func download(
        metadata: VideoMetadata,
        downloadDirectoryPath: String? = nil,
        mode: DownloadMode = .complete,
        taskIdentifier: String? = nil,
        progress: @escaping (DownloadProgressEvent) -> Void
    ) async throws -> String {
        guard let taskIdentifier = taskIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !taskIdentifier.isEmpty else {
            return try await performDownload(
                metadata: metadata,
                downloadDirectoryPath: downloadDirectoryPath,
                mode: mode,
                progress: progress
            )
        }

        downloadControl.begin(taskIdentifier: taskIdentifier)
        return try await DownloadExecutionContext.$taskIdentifier.withValue(taskIdentifier) {
            do {
                let savedPath = try await performDownload(
                    metadata: metadata,
                    downloadDirectoryPath: downloadDirectoryPath,
                    mode: mode,
                    progress: progress
                )
                progress(DownloadProgressEvent(status: "downloading", progress: 99, message: "正在校验下载文件"))
                let outputPaths = downloadControl.existingOutputPaths(taskIdentifier: taskIdentifier)
                do {
                    try validateDownloadedMedia(
                        paths: outputPaths,
                        metadata: metadata,
                        mode: mode
                    )
                } catch {
                    downloadControl.deleteTrackedOutputs(taskIdentifier: taskIdentifier)
                    throw error
                }
                downloadControl.finishSuccess(taskIdentifier: taskIdentifier)
                return savedPath
            } catch {
                if downloadControl.isCancelled(taskIdentifier: taskIdentifier) {
                    downloadControl.finishCancelled(taskIdentifier: taskIdentifier)
                    throw UserFacingError("下载已取消")
                }
                downloadControl.finishFailure(taskIdentifier: taskIdentifier)
                throw error
            }
        }
    }

    func cancelDownload(taskIdentifier: String, deletePartialFiles: Bool) async {
        await downloadControl.cancel(
            taskIdentifier: taskIdentifier,
            deletePartialFiles: deletePartialFiles
        )
    }

    func pauseDownload(taskIdentifier: String) throws {
        try downloadControl.pause(taskIdentifier: taskIdentifier)
    }

    func resumeDownload(taskIdentifier: String) throws {
        try downloadControl.resume(taskIdentifier: taskIdentifier)
    }

    private func performDownload(
        metadata: VideoMetadata,
        downloadDirectoryPath: String?,
        mode: DownloadMode,
        progress: @escaping (DownloadProgressEvent) -> Void
    ) async throws -> String {
        let downloadsDirectory = try resolveDownloadsDirectory(customPath: downloadDirectoryPath)
        if let selectedItems = metadata.selectedCollectionItems,
           !selectedItems.isEmpty {
            return try await downloadCollectionItems(
                parentMetadata: metadata,
                items: selectedItems,
                downloadsDirectory: downloadsDirectory,
                mode: mode,
                progress: progress
            )
        }

        return try await downloadSingle(
            metadata: metadata,
            downloadsDirectory: downloadsDirectory,
            mode: mode,
            progress: progress
        )
    }

    func downloadCover(
        metadata: VideoMetadata,
        downloadDirectoryPath: String? = nil
    ) async throws -> String {
        let downloadsDirectory = try resolveDownloadsDirectory(customPath: downloadDirectoryPath)
        guard let coverUrl = textOrNil(metadata.coverUrl) else {
            throw UserFacingError("封面下载失败：未找到封面图片")
        }

        let coverImage = try await loadCoverImage(from: coverUrl, referer: metadata.normalizedUrl)
        let savedPath = uniqueOutputPath(
            directory: downloadsDirectory,
            baseName: outputBaseName(for: metadata, suffix: "封面"),
            fileExtension: coverImage.fileExtension
        )
        try coverImage.data.write(to: URL(fileURLWithPath: savedPath), options: .atomic)
        return savedPath
    }

    private func downloadSingle(
        metadata: VideoMetadata,
        downloadsDirectory: URL,
        mode: DownloadMode,
        progress: @escaping (DownloadProgressEvent) -> Void
    ) async throws -> String {
        progress(DownloadProgressEvent(status: "preparing", progress: 1, message: "准备下载"))

        if metadata.platform == SupportedPlatform.bilibili.rawValue,
           let savedPath = try await downloadBilibiliViaPublicAPI(
            metadata: metadata,
            downloadsDirectory: downloadsDirectory,
            mode: mode,
            progress: progress
           ) {
            return savedPath
        }
        if metadata.platform == SupportedPlatform.douyin.rawValue {
            return try await downloadDouyinViaSharePage(
                metadata: metadata,
                downloadsDirectory: downloadsDirectory,
                mode: mode,
                progress: progress
            )
        }
        if metadata.platform == SupportedPlatform.kuaishou.rawValue {
            return try await downloadKuaishouViaSharePage(
                metadata: metadata,
                downloadsDirectory: downloadsDirectory,
                mode: mode,
                progress: progress
            )
        }
        if metadata.platform == SupportedPlatform.wechatChannels.rawValue {
            return try await downloadWeChatChannels(
                metadata: metadata,
                downloadsDirectory: downloadsDirectory,
                mode: mode,
                progress: progress
            )
        }
        if metadata.platform == SupportedPlatform.toutiao.rawValue,
           textOrNil(metadata.directMediaUrl) != nil {
            return try await downloadToutiaoViaMobilePage(
                metadata: metadata,
                downloadsDirectory: downloadsDirectory,
                mode: mode,
                progress: progress
            )
        }

        if mode == .complete {
            let savedPath = try await downloadViaYTDLP(
                metadata: metadata,
                downloadsDirectory: downloadsDirectory,
                mode: .complete,
                suffix: nil,
                progressMessage: progressMessage(for: mode),
                progressStart: 1,
                progressEnd: 99,
                progress: progress
            )
            progress(DownloadProgressEvent(status: "completed", progress: 100, message: "已完成：\(savedPath)"))
            return savedPath
        }

        return try await downloadLocalProcessedViaYTDLP(
            metadata: metadata,
            downloadsDirectory: downloadsDirectory,
            mode: mode,
            progress: progress
        )
    }

    private func downloadCollectionItems(
        parentMetadata: VideoMetadata,
        items: [VideoCollectionItem],
        downloadsDirectory: URL,
        mode: DownloadMode,
        progress: @escaping (DownloadProgressEvent) -> Void
    ) async throws -> String {
        let orderedItems = items.sorted { $0.index < $1.index }
        guard !orderedItems.isEmpty else {
            throw UserFacingError("下载失败：请先选择合集视频")
        }

        var savedPaths: [String] = []
        let total = orderedItems.count
        for (offset, item) in orderedItems.enumerated() {
            let itemMetadata = metadataForCollectionItem(parentMetadata: parentMetadata, item: item)
            let savedPath = try await downloadSingle(
                metadata: itemMetadata,
                downloadsDirectory: downloadsDirectory,
                mode: mode
            ) { event in
                let itemProgress = max(0, min(100, event.progress))
                let base = Double(offset) / Double(total)
                let scaled = Int(((base + Double(itemProgress) / 100 / Double(total)) * 99).rounded())
                progress(
                    DownloadProgressEvent(
                        status: event.status == "failed" ? "failed" : "downloading",
                        progress: max(1, min(99, scaled)),
                        message: "第 \(offset + 1)/\(total) 集：\(event.message)"
                    )
                )
            }
            savedPaths.append(savedPath)
        }

        let summary = savedPaths.joined(separator: "；")
        progress(DownloadProgressEvent(status: "completed", progress: 100, message: "已完成：\(summary)"))
        return summary
    }

    private func metadataForCollectionItem(
        parentMetadata: VideoMetadata,
        item: VideoCollectionItem
    ) -> VideoMetadata {
        let filename = URLTools.sanitizeFilename(String(format: "%02d %@", item.index, item.title))
        return VideoMetadata(
            id: item.id,
            originalUrl: item.url,
            normalizedUrl: item.url,
            platform: item.platform,
            platformName: parentMetadata.platformName,
            title: item.title,
            author: parentMetadata.author,
            publishedAt: parentMetadata.publishedAt,
            duration: item.duration ?? parentMetadata.duration,
            coverUrl: item.coverUrl ?? parentMetadata.coverUrl,
            qualities: parentMetadata.qualities,
            estimatedSizeMb: nil,
            parseMode: parentMetadata.parseMode,
            note: parentMetadata.note,
            suggestedFilename: filename,
            savedPath: nil
        )
    }

    private func downloadViaYTDLP(
        metadata: VideoMetadata,
        downloadsDirectory: URL,
        mode: DownloadMode,
        suffix: String?,
        progressMessage: String,
        progressStart: Int,
        progressEnd: Int,
        progress: @escaping (DownloadProgressEvent) -> Void
    ) async throws -> String {
        let outputTemplate = outputTemplatePath(
            directory: downloadsDirectory,
            metadata: metadata,
            suffix: suffix
        )
        var savedPath = ""
        try await runStreamingYTDLP(
            arguments: ytdlpDownloadArguments(for: metadata, outputTemplate: outputTemplate, mode: mode),
            onLine: { line in
                if let event = Self.parseProgressLine(line) {
                    progress(
                        self.scaledProgressEvent(
                            event,
                            message: progressMessage,
                            start: progressStart,
                            end: progressEnd
                        )
                    )
                }
                if line.hasPrefix("filepath:") {
                    savedPath = String(line.dropFirst("filepath:".count))
                }
            }
        )

        if savedPath.isEmpty {
            savedPath = downloadsDirectory.path
        }

        return savedPath
    }

    private func downloadSeparateViaYTDLP(
        metadata: VideoMetadata,
        downloadsDirectory: URL,
        progress: @escaping (DownloadProgressEvent) -> Void
    ) async throws -> String {
        return try await downloadLocalProcessedViaYTDLP(
            metadata: metadata,
            downloadsDirectory: downloadsDirectory,
            mode: .separate,
            progress: progress
        )
    }

    private func downloadLocalProcessedViaYTDLP(
        metadata: VideoMetadata,
        downloadsDirectory: URL,
        mode: DownloadMode,
        progress: @escaping (DownloadProgressEvent) -> Void
    ) async throws -> String {
        let sourcePath = try await downloadViaYTDLP(
            metadata: metadata,
            downloadsDirectory: downloadsDirectory,
            mode: .complete,
            suffix: "源视频-\(UUID().uuidString.prefix(8))",
            progressMessage: "下载源视频",
            progressStart: 5,
            progressEnd: 52,
            progress: progress
        )

        return try await processDownloadedCompleteFile(
            sourcePath: sourcePath,
            metadata: metadata,
            downloadsDirectory: downloadsDirectory,
            mode: mode,
            duration: durationSeconds(from: metadata.duration),
            progress: progress,
            removeSourceWhenDone: true
        )
    }

    private func resolveDownloadsDirectory(customPath: String?) throws -> URL {
        guard let customPath = textOrNil(customPath) else {
            return defaultDownloadsDirectory()
        }

        let expandedPath = (customPath as NSString).expandingTildeInPath
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw UserFacingError("下载失败：选择的下载目录不存在")
        }
        guard FileManager.default.isWritableFile(atPath: expandedPath) else {
            throw UserFacingError("下载失败：没有权限写入选择的下载目录")
        }
        return URL(fileURLWithPath: expandedPath, isDirectory: true)
    }

    private func defaultDownloadsDirectory() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    private func ytdlpDownloadArguments(
        for metadata: VideoMetadata,
        outputTemplate: String,
        mode: DownloadMode
    ) -> [String] {
        var arguments = [
            "--newline",
            "--no-playlist",
            "--no-part",
            "--socket-timeout",
            "20"
        ]
        if metadata.platform == SupportedPlatform.toutiao.rawValue {
            arguments += [
                "--add-header",
                "User-Agent:\(browserUserAgent)",
                "--add-header",
                "Referer:https://www.toutiao.com/"
            ]
        }
        switch mode {
        case .complete:
            arguments += [
                "--merge-output-format",
                "mp4"
            ]
        case .audio:
            arguments += [
                "-f",
                "bestaudio/best",
                "--extract-audio",
                "--audio-format",
                "m4a"
            ]
        case .video:
            arguments += [
                "-f",
                "bestvideo[ext=mp4]/bestvideo"
            ]
        case .separate:
            break
        }
        arguments += [
            "--progress-template",
            "download:%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s",
            "--print",
            "after_move:filepath:%(filepath)s",
            "-o",
            outputTemplate,
            metadata.normalizedUrl
        ]
        return arguments
    }

    private func downloadDouyinViaSharePage(
        metadata: VideoMetadata,
        downloadsDirectory: URL,
        mode: DownloadMode,
        progress: @escaping (DownloadProgressEvent) -> Void
    ) async throws -> String {
        progress(DownloadProgressEvent(status: "preparing", progress: 3, message: "获取抖音下载地址"))

        let item = try requestDouyinItem(urls: [metadata.originalUrl, metadata.normalizedUrl])
        if isDouyinImagePost(item) {
            return try await downloadDouyinImagePost(
                item: item,
                metadata: metadata,
                downloadsDirectory: downloadsDirectory,
                mode: mode,
                progress: progress
            )
        }

        guard let mediaURL = douyinNoWatermarkVideoURL(from: item) else {
            throw UserFacingError("下载失败：抖音未返回可下载的视频地址")
        }

        let duration = douyinDurationSeconds(item.video?.duration)
        let totalBytes = byteCount(from: item.video?.play_addr?.data_size)

        return try await downloadDirectMedia(
            metadata: metadata,
            mediaURL: mediaURL,
            downloadsDirectory: downloadsDirectory,
            mode: mode,
            duration: duration,
            totalBytes: totalBytes,
            progress: progress,
            userAgent: mobileUserAgent,
            referer: "https://www.douyin.com/",
            platformName: "抖音"
        )
    }

    private func requestDouyinItem(urls: [String]) throws -> DouyinRouterData.Item {
        guard let item = try requestDouyinItems(urls: urls).first else {
            throw UserFacingError("下载失败：无法读取抖音视频信息")
        }
        return item
    }

    private func requestDouyinItems(urls: [String]) throws -> [DouyinRouterData.Item] {
        for url in urls where !url.isEmpty {
            guard let htmlData = try? requestDouyinSharePage(url: url),
                  let html = String(data: htmlData, encoding: .utf8),
                  let routerData = try? decodeDouyinRouterData(from: html),
                  let items = routerData.loaderData.primaryPage?.videoInfoRes?.item_list,
                  !items.isEmpty else {
                continue
            }
            return items
        }
        throw UserFacingError("下载失败：无法读取抖音视频信息")
    }

    private func douyinCollection(from items: [DouyinRouterData.Item]) -> VideoCollection? {
        guard items.count > 1 else {
            return nil
        }
        let collectionItems = items.enumerated().map { index, item in
            let title = douyinTitle(from: item.desc?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            return VideoCollectionItem(
                id: item.aweme_id,
                title: title,
                url: douyinCanonicalUrl(for: item),
                platform: SupportedPlatform.douyin.rawValue,
                duration: formatDuration(douyinDisplayDuration(for: item)),
                coverUrl: normalizedCoverUrl(douyinCoverURL(from: item)),
                index: index + 1
            )
        }

        return VideoCollection(
            id: "douyin-\(items.first?.aweme_id ?? UUID().uuidString)",
            title: "抖音合集",
            items: collectionItems
        )
    }

    private func downloadDouyinImagePost(
        item: DouyinRouterData.Item,
        metadata: VideoMetadata,
        downloadsDirectory: URL,
        mode: DownloadMode,
        progress: @escaping (DownloadProgressEvent) -> Void
    ) async throws -> String {
        let imageURLs = douyinImageURLs(from: item)
        guard !imageURLs.isEmpty else {
            throw UserFacingError("下载失败：抖音图文作品未返回图片地址")
        }

        let duration = douyinDisplayDuration(for: item) ?? max(3, Double(imageURLs.count * 3))
        var temporaryPaths: [String] = []
        defer {
            temporaryPaths.forEach { removeTemporaryFile(at: $0) }
        }

        let imagePaths: [String]
        if mode == .audio {
            imagePaths = []
        } else {
            imagePaths = try await downloadDouyinImagePostImages(
                imageURLs: imageURLs,
                metadata: metadata,
                progress: progress
            )
            temporaryPaths += imagePaths
        }

        let audioURL = douyinAudioURL(from: item)
        let audioPath: String?
        if let audioURL, mode != .video {
            let path = temporaryOutputPath(baseName: "\(metadata.id)-audio", fileExtension: "mp3")
            temporaryPaths.append(path)
            try await runCurlDownload(
                url: audioURL,
                outputPath: path,
                totalBytes: requestMediaContentLength(url: audioURL),
                progress: progress,
                userAgent: mobileUserAgent,
                referer: "https://www.douyin.com/",
                platformName: "抖音",
                progressMessage: "下载原声音频",
                progressStart: mode == .audio ? 5 : 36,
                progressEnd: mode == .audio ? 99 : 55
            )
            audioPath = path
        } else {
            audioPath = nil
        }

        switch mode {
        case .audio:
            guard let audioPath else {
                throw UserFacingError("下载失败：抖音图文作品未返回音频地址")
            }
            let outputPath = downloadOutputPath(
                directory: downloadsDirectory,
                metadata: metadata,
                suffix: outputSuffix(for: mode),
                fileExtension: "mp3"
            )
            try FileManager.default.copyItem(atPath: audioPath, toPath: outputPath)
            progress(DownloadProgressEvent(status: "completed", progress: 100, message: "已完成：\(outputPath)"))
            return outputPath

        case .video:
            let outputPath = downloadOutputPath(
                directory: downloadsDirectory,
                metadata: metadata,
                suffix: outputSuffix(for: mode),
                fileExtension: "mp4"
            )
            try await runDouyinImagePostFFmpeg(
                imagePaths: imagePaths,
                audioPath: nil,
                outputPath: outputPath,
                duration: duration,
                progressMessage: "生成图文视频",
                progressStart: 36,
                progressEnd: 99,
                progress: progress
            )
            progress(DownloadProgressEvent(status: "completed", progress: 100, message: "已完成：\(outputPath)"))
            return outputPath

        case .complete:
            let outputPath = downloadOutputPath(
                directory: downloadsDirectory,
                metadata: metadata,
                suffix: nil,
                fileExtension: "mp4"
            )
            try await runDouyinImagePostFFmpeg(
                imagePaths: imagePaths,
                audioPath: audioPath,
                outputPath: outputPath,
                duration: duration,
                progressMessage: "合成图文视频",
                progressStart: 56,
                progressEnd: 99,
                progress: progress
            )
            progress(DownloadProgressEvent(status: "completed", progress: 100, message: "已完成：\(outputPath)"))
            return outputPath

        case .separate:
            let videoPath = downloadOutputPath(
                directory: downloadsDirectory,
                metadata: metadata,
                suffix: "仅视频",
                fileExtension: "mp4"
            )
            try await runDouyinImagePostFFmpeg(
                imagePaths: imagePaths,
                audioPath: nil,
                outputPath: videoPath,
                duration: duration,
                progressMessage: "生成图文视频",
                progressStart: 56,
                progressEnd: 84,
                progress: progress
            )
            guard let audioPath else {
                throw UserFacingError("下载失败：抖音图文作品未返回音频地址")
            }
            let finalAudioPath = downloadOutputPath(
                directory: downloadsDirectory,
                metadata: metadata,
                suffix: "音频",
                fileExtension: "mp3"
            )
            try FileManager.default.copyItem(atPath: audioPath, toPath: finalAudioPath)
            let savedPath = "视频 \(videoPath)；音频 \(finalAudioPath)"
            progress(DownloadProgressEvent(status: "completed", progress: 100, message: "已完成：\(savedPath)"))
            return savedPath
        }
    }

    private func downloadDouyinImagePostImages(
        imageURLs: [String],
        metadata: VideoMetadata,
        progress: @escaping (DownloadProgressEvent) -> Void
    ) async throws -> [String] {
        var imagePaths: [String] = []
        var shouldCleanupOnFailure = true
        defer {
            if shouldCleanupOnFailure {
                imagePaths.forEach { removeTemporaryFile(at: $0) }
            }
        }
        for (index, imageURL) in imageURLs.enumerated() {
            let pathExtension = imageFileExtension(fromPathExtension: URL(string: imageURL)?.pathExtension ?? "") ?? "jpg"
            let outputPath = temporaryOutputPath(
                baseName: "\(metadata.id)-image-\(index + 1)",
                fileExtension: pathExtension
            )
            let start = 5 + Int((Double(index) / Double(max(1, imageURLs.count))) * 30)
            let end = 5 + Int((Double(index + 1) / Double(max(1, imageURLs.count))) * 30)
            try await runCurlDownload(
                url: imageURL,
                outputPath: outputPath,
                totalBytes: requestMediaContentLength(url: imageURL),
                progress: progress,
                userAgent: mobileUserAgent,
                referer: "https://www.douyin.com/",
                platformName: "抖音",
                progressMessage: "下载图文图片",
                progressStart: start,
                progressEnd: max(start + 1, end)
            )
            imagePaths.append(outputPath)
        }
        shouldCleanupOnFailure = false
        return imagePaths
    }

    private func runDouyinImagePostFFmpeg(
        imagePaths: [String],
        audioPath: String?,
        outputPath: String,
        duration: Double,
        progressMessage: String,
        progressStart: Int,
        progressEnd: Int,
        progress: @escaping (DownloadProgressEvent) -> Void
    ) async throws {
        guard !imagePaths.isEmpty else {
            throw UserFacingError("下载失败：抖音图文作品未返回图片地址")
        }
        let secondsPerImage = max(1, duration / Double(max(1, imagePaths.count)))

        progress(DownloadProgressEvent(status: "downloading", progress: progressStart, message: progressMessage))

        var arguments = [
            "-y",
            "-nostdin",
            "-hide_banner",
            "-loglevel", "warning"
        ]
        for imagePath in imagePaths {
            arguments += [
                "-loop", "1",
                "-framerate", "30",
                "-t", String(format: "%.3f", secondsPerImage),
                "-i", imagePath
            ]
        }

        let normalizedVideoInputs = imagePaths.indices
            .map { "[\($0):v]scale=1080:1920:force_original_aspect_ratio=decrease,pad=1080:1920:(ow-iw)/2:(oh-ih)/2,setsar=1,format=yuv420p[v\($0)]" }
        let concatInputs = imagePaths.indices.map { "[v\($0)]" }.joined()
        let filterGraph = (normalizedVideoInputs + [
            "\(concatInputs)concat=n=\(imagePaths.count):v=1:a=0,trim=duration=\(String(format: "%.3f", duration)),setpts=PTS-STARTPTS[vout]"
        ]).joined(separator: ";")

        if let audioPath {
            arguments += [
                "-i",
                audioPath,
                "-filter_complex", filterGraph,
                "-map",
                "[vout]",
                "-map",
                "\(imagePaths.count):a:0",
                "-c:a",
                "aac",
                "-b:a",
                "192k",
                "-shortest"
            ]
        } else {
            arguments += [
                "-filter_complex", filterGraph,
                "-map",
                "[vout]",
                "-an",
                "-t",
                String(format: "%.3f", duration)
            ]
        }

        arguments += [
            "-r", "30",
            "-c:v",
            "libx264",
            "-preset",
            "veryfast",
            "-crf",
            "18",
            "-movflags",
            "+faststart",
            "-progress",
            "pipe:1",
            "-nostats",
            outputPath
        ]

        try await runStreamingFFmpeg(arguments: arguments) { line in
            if let event = Self.parseFFmpegProgressLine(line, duration: duration) {
                progress(
                    self.scaledProgressEvent(
                        event,
                        message: progressMessage,
                        start: progressStart,
                        end: progressEnd
                    )
                )
            } else if line == "progress=end" {
                progress(DownloadProgressEvent(status: "downloading", progress: progressEnd, message: "正在收尾"))
            }
        }
    }

    private struct MediaInspection {
        var hasVideo: Bool
        var hasAudio: Bool
        var duration: Double?
    }

    private func validateDownloadedMedia(
        paths: Set<String>,
        metadata: VideoMetadata,
        mode: DownloadMode
    ) throws {
        let mediaPaths = paths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .filter { path in
                let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
                return ["mp4", "mov", "m4v", "webm", "mkv", "mp3", "m4a", "aac", "wav", "flac"].contains(ext)
            }
        guard !mediaPaths.isEmpty else {
            throw UserFacingError("下载校验失败：未找到已生成的媒体文件")
        }

        let inspected = try mediaPaths.map { path -> (String, MediaInspection) in
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard size >= 1_024 else {
                throw UserFacingError("下载校验失败：生成的媒体文件内容不完整")
            }
            return (path, try inspectMedia(at: path))
        }
        let expectedItems = max(1, metadata.selectedCollectionItems?.count ?? 1)
        let videoFiles = inspected.filter { $0.1.hasVideo }
        let audioFiles = inspected.filter { $0.1.hasAudio }
        let videoOnlyFiles = inspected.filter { $0.1.hasVideo && !$0.1.hasAudio }
        let audioOnlyFiles = inspected.filter { $0.1.hasAudio && !$0.1.hasVideo }

        switch mode {
        case .complete:
            guard videoFiles.count >= expectedItems else {
                throw UserFacingError("下载校验失败：视频流缺失")
            }
        case .audio:
            guard audioOnlyFiles.count >= expectedItems else {
                throw UserFacingError("下载校验失败：音频流缺失")
            }
        case .video:
            guard videoOnlyFiles.count >= expectedItems else {
                throw UserFacingError("下载校验失败：纯视频文件无效")
            }
        case .separate:
            guard videoOnlyFiles.count >= expectedItems, audioOnlyFiles.count >= expectedItems else {
                throw UserFacingError("下载校验失败：分开生成的音视频文件不完整")
            }
        }

        if metadata.selectedCollectionItems == nil,
           let expectedDuration = durationSeconds(from: metadata.duration), expectedDuration >= 1,
           mode != .audio,
           let actualDuration = videoFiles.compactMap({ $0.1.duration }).max(),
           actualDuration < max(0.5, expectedDuration * 0.5) {
            throw UserFacingError("下载校验失败：生成的视频时长异常，请重试")
        }
    }

    private func inspectMedia(at path: String) throws -> MediaInspection {
        let result = try runProcess(
            executable: resolveFFmpegPath(),
            arguments: ["-hide_banner", "-i", path],
            timeout: 20
        )
        let text = result.standardErrorText
        let hasVideo = text.range(of: #"Stream #.*Video:"#, options: .regularExpression) != nil
        let hasAudio = text.range(of: #"Stream #.*Audio:"#, options: .regularExpression) != nil
        let duration: Double?
        if let match = text.range(of: #"Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)"#, options: .regularExpression) {
            let durationText = String(text[match])
            let values = durationText
                .replacingOccurrences(of: "Duration:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: ":")
                .compactMap { Double($0) }
            duration = values.count == 3 ? values[0] * 3600 + values[1] * 60 + values[2] : nil
        } else {
            duration = nil
        }
        guard hasVideo || hasAudio else {
            throw UserFacingError("下载校验失败：无法识别生成的媒体流")
        }
        return MediaInspection(hasVideo: hasVideo, hasAudio: hasAudio, duration: duration)
    }

    private func downloadKuaishouViaSharePage(
        metadata: VideoMetadata,
        downloadsDirectory: URL,
        mode: DownloadMode,
        progress: @escaping (DownloadProgressEvent) -> Void
    ) async throws -> String {
        progress(DownloadProgressEvent(status: "preparing", progress: 3, message: "获取快手下载地址"))

        let item = try requestKuaishouPhoto(urls: [metadata.normalizedUrl, metadata.originalUrl])
        let bestRepresentation = bestKuaishouRepresentation(from: kuaishouRepresentations(from: item))
        guard let mediaURL = kuaishouMediaURL(from: bestRepresentation) ?? item.mainMvUrls?.compactMap(\.url).first else {
            throw UserFacingError("下载失败：快手未返回可下载的视频地址")
        }

        let duration = kuaishouDurationSeconds(item.duration ?? item.manifest?.adaptationSet?.compactMap(\.duration).first)
        let totalBytes = byteCount(from: bestRepresentation?.fileSize)
            ?? requestMediaContentLength(url: mediaURL, userAgent: kuaishouUserAgent, referer: "https://m.kuaishou.com/")

        return try await downloadDirectMedia(
            metadata: metadata,
            mediaURL: mediaURL,
            downloadsDirectory: downloadsDirectory,
            mode: mode,
            duration: duration,
            totalBytes: totalBytes,
            progress: progress,
            userAgent: kuaishouUserAgent,
            referer: "https://m.kuaishou.com/",
            platformName: "快手"
        )
    }

    private func downloadWeChatChannels(
        metadata: VideoMetadata,
        downloadsDirectory: URL,
        mode: DownloadMode,
        progress: @escaping (DownloadProgressEvent) -> Void
    ) async throws -> String {
        progress(DownloadProgressEvent(status: "preparing", progress: 3, message: "检查微信视频号授权"))
        let shareURL = weChatChannelsShortURI(from: metadata.originalUrl)
            .map { "https://weixin.qq.com/sph/\($0)" }
            ?? metadata.originalUrl
        let parseResponse = try await WeChatChannelsAuthorization.shared.authorizedParse(
            shareURL: shareURL
        ) {
            guard let taskIdentifier = DownloadExecutionContext.taskIdentifier else {
                return false
            }
            return self.downloadControl.isCancelled(taskIdentifier: taskIdentifier)
        }
        try throwIfCurrentDownloadCancelled()

        progress(DownloadProgressEvent(status: "preparing", progress: 4, message: "获取微信视频号播放地址"))
        let mediaProfile = try await weChatChannelsMediaProfile(from: parseResponse)
        progress(
            DownloadProgressEvent(
                status: "preparing",
                progress: 4,
                message: "已获取微信视频号媒体信息",
                duration: mediaProfile.duration.map(formatDuration),
                estimatedSizeMb: mediaProfile.totalBytes.flatMap { megabytes(fromBytes: Double($0)) },
                weChatAuthorized: true
            )
        )
        return try await downloadDirectMedia(
            metadata: metadata,
            mediaURL: mediaProfile.mediaURL,
            downloadsDirectory: downloadsDirectory,
            mode: mode,
            duration: mediaProfile.duration ?? durationSeconds(from: metadata.duration),
            totalBytes: mediaProfile.totalBytes,
            progress: progress,
            userAgent: browserUserAgent,
            referer: mediaProfile.referer,
            platformName: "微信视频号"
        )
    }

    private func weChatChannelsMediaProfile(
        from parseResponse: WeChatChannelsYuanbaoParseResponse
    ) async throws -> WeChatChannelsMediaProfile {
        guard let parseData = parseResponse.data else {
            throw UserFacingError("下载失败：腾讯元宝未返回微信视频号播放凭证")
        }
        guard let playableURL = textOrNil(parseData.playableUrl),
              let playableComponents = URLComponents(string: playableURL) else {
            throw UserFacingError("下载失败：微信视频号播放凭证无效")
        }
        let token = playableComponents.queryItems?.first(where: { $0.name == "token" })?.value
        let exportID = playableComponents.queryItems?.first(where: { $0.name == "eid" })?.value
            ?? parseData.wxExportId
        guard let generalToken = textOrNil(token),
              let resolvedExportID = textOrNil(exportID) else {
            throw UserFacingError("下载失败：微信视频号播放凭证不完整")
        }

        let feedResponse = try await requestWeChatChannelsFeed(
            exportID: resolvedExportID,
            generalToken: generalToken
        )
        guard let feedInfo = feedResponse.data?.feedInfo,
              let mediaURL = weChatChannelsMediaURL(from: feedInfo) else {
            throw UserFacingError("下载失败：微信视频号未返回可用的视频地址")
        }

        let referer = weChatChannelsFeedReferer(exportID: resolvedExportID, generalToken: generalToken)
        let totalBytes = requestMediaContentLength(
            url: mediaURL,
            userAgent: browserUserAgent,
            referer: referer
        )
        let duration = probeMediaDuration(
            url: mediaURL,
            userAgent: browserUserAgent,
            referer: referer
        )
        return WeChatChannelsMediaProfile(
            mediaURL: mediaURL,
            referer: referer,
            duration: duration,
            totalBytes: totalBytes
        )
    }

    private func requestWeChatChannelsFeed(
        exportID: String,
        generalToken: String
    ) async throws -> WeChatChannelsFeedResponse {
        var components = URLComponents(string: "https://channels.weixin.qq.com/finder-preview/api/feed/get_feed_info")
        components?.queryItems = [
            URLQueryItem(name: "_rid", value: "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"),
            URLQueryItem(
                name: "_pageUrl",
                value: "https://channels.weixin.qq.com/finder-preview/pages/feed"
            )
        ]
        guard let url = components?.url else {
            throw UserFacingError("下载失败：微信视频号接口地址无效")
        }
        let payload: [String: Any] = [
            "baseReq": ["generalToken": generalToken],
            "exportId": exportID
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://channels.weixin.qq.com", forHTTPHeaderField: "Origin")
        request.setValue(
            weChatChannelsFeedReferer(exportID: exportID, generalToken: generalToken),
            forHTTPHeaderField: "Referer"
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw UserFacingError("下载失败：微信视频号播放接口暂时不可用")
        }
        let result: WeChatChannelsFeedResponse
        do {
            result = try decoder.decode(WeChatChannelsFeedResponse.self, from: data)
        } catch {
            throw UserFacingError("下载失败：微信视频号返回了无法识别的播放数据")
        }
        if let errCode = result.errCode, errCode != 0 {
            throw UserFacingError("下载失败：\(textOrNil(result.errMsg) ?? "微信视频号播放凭证已失效")")
        }
        return result
    }

    private func weChatChannelsFeedReferer(exportID: String, generalToken: String) -> String {
        var components = URLComponents(string: "https://channels.weixin.qq.com/finder-preview/pages/feed")
        components?.queryItems = [
            URLQueryItem(name: "entry_card_type", value: "48"),
            URLQueryItem(name: "comment_scene", value: "39"),
            URLQueryItem(name: "appid", value: "0"),
            URLQueryItem(name: "token", value: generalToken),
            URLQueryItem(name: "entry_scene", value: "0"),
            URLQueryItem(name: "eid", value: exportID)
        ]
        return components?.url?.absoluteString
            ?? "https://channels.weixin.qq.com/finder-preview/pages/feed"
    }

    private func weChatChannelsMediaURL(from feedInfo: WeChatChannelsFeedResponse.FeedInfo) -> String? {
        let candidates = [
            feedInfo.originVideoUrl,
            feedInfo.videoUrl,
            feedInfo.h264VideoInfo?.videoUrl,
            feedInfo.h265VideoInfo?.videoUrl
        ].compactMap(textOrNil)
        for candidate in candidates {
            if let cleanedURL = cleanWeChatChannelsMediaURL(candidate) {
                return cleanedURL
            }
        }
        return candidates.first
    }

    private func cleanWeChatChannelsMediaURL(_ source: String) -> String? {
        guard var components = URLComponents(string: source),
              let encfilekey = components.queryItems?.first(where: { $0.name == "encfilekey" })?.value,
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value,
              !encfilekey.isEmpty,
              !token.isEmpty else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "encfilekey", value: encfilekey),
            URLQueryItem(name: "token", value: token)
        ]
        components.fragment = nil
        return components.url?.absoluteString
    }

    private func downloadBilibiliViaPublicAPI(
        metadata: VideoMetadata,
        downloadsDirectory: URL,
        mode: DownloadMode,
        progress: @escaping (DownloadProgressEvent) -> Void
    ) async throws -> String? {
        guard let bvid = extractBVID(from: metadata.normalizedUrl) ?? extractBVID(from: metadata.originalUrl) else {
            return nil
        }

        progress(DownloadProgressEvent(status: "preparing", progress: 3, message: "获取 B 站下载地址"))

        let viewItem = try requestBilibiliViewItem(bvid: bvid)
        let preferredPage = preferredBilibiliPage(from: metadata.normalizedUrl, in: viewItem)
        let selectedCID = preferredPage?.cid ?? viewItem.cid
        let fallbackDuration = preferredPage?.duration.map(Double.init) ?? Double(viewItem.duration)
        let playData = try requestBilibiliPlayData(bvid: viewItem.bvid, cid: selectedCID)

        if let dash = playData.dash,
           let videoStream = bestBilibiliVideoStream(from: dash.video),
           let videoURL = videoStream.mediaURL {
            let audioURL = bestBilibiliAudioStream(from: dash.audio)?.mediaURL
            let duration = dash.duration ?? fallbackDuration
            return try await downloadBilibiliMedia(
                videoURL: videoURL,
                audioURL: audioURL,
                downloadsDirectory: downloadsDirectory,
                metadata: metadata,
                mode: mode,
                duration: duration,
                progress: progress
            )
        }

        if let durl = playData.durl?.first(where: { $0.mediaURL != nil }),
           let mediaURL = durl.mediaURL {
            let duration = durl.length.map { Double($0) / 1000 } ?? fallbackDuration
            return try await downloadBilibiliMedia(
                videoURL: mediaURL,
                audioURL: nil,
                downloadsDirectory: downloadsDirectory,
                metadata: metadata,
                mode: mode,
                duration: duration,
                progress: progress
            )
        }

        throw UserFacingError("下载失败：B 站未返回可下载的视频流")
    }

    private func preferredBilibiliPage(
        from urlText: String,
        in item: BilibiliViewResponse.DataItem
    ) -> BilibiliViewResponse.DataItem.Page? {
        guard let pageNumber = bilibiliPageNumber(from: urlText) else {
            return nil
        }
        return item.pages?.first { $0.page == pageNumber }
    }

    private func bilibiliPageNumber(from urlText: String) -> Int? {
        guard let components = URLComponents(string: urlText) else {
            return nil
        }
        return components.queryItems?
            .first(where: { $0.name.lowercased() == "p" })?
            .value
            .flatMap(Int.init)
    }

    private func downloadBilibiliMedia(
        videoURL: String,
        audioURL: String?,
        downloadsDirectory: URL,
        metadata: VideoMetadata,
        mode: DownloadMode,
        duration: Double,
        progress: @escaping (DownloadProgressEvent) -> Void
    ) async throws -> String {
        switch mode {
        case .complete:
            let outputPath = downloadOutputPath(
                directory: downloadsDirectory,
                metadata: metadata,
                suffix: nil,
                fileExtension: "mp4"
            )
            try await runBilibiliFFmpeg(
                videoURL: videoURL,
                audioURL: audioURL,
                outputPath: outputPath,
                duration: duration,
                progress: progress
            )
            progress(DownloadProgressEvent(status: "completed", progress: 100, message: "已完成：\(outputPath)"))
            return outputPath
        case .audio:
            let sourceURL = audioURL ?? videoURL
            let outputPath = downloadOutputPath(
                directory: downloadsDirectory,
                metadata: metadata,
                suffix: outputSuffix(for: mode),
                fileExtension: "m4a"
            )
            try await runRemoteMediaFFmpeg(
                mediaURL: sourceURL,
                outputPath: outputPath,
                transform: .audio,
                duration: duration,
                progressMessage: progressMessage(for: mode),
                progressStart: 5,
                progressEnd: 99,
                progress: progress,
                userAgent: browserUserAgent,
                headers: bilibiliMediaHeaders()
            )
            progress(DownloadProgressEvent(status: "completed", progress: 100, message: "已完成：\(outputPath)"))
            return outputPath
        case .video:
            let outputPath = downloadOutputPath(
                directory: downloadsDirectory,
                metadata: metadata,
                suffix: outputSuffix(for: mode),
                fileExtension: "mp4"
            )
            try await runRemoteMediaFFmpeg(
                mediaURL: videoURL,
                outputPath: outputPath,
                transform: .video,
                duration: duration,
                progressMessage: progressMessage(for: mode),
                progressStart: 5,
                progressEnd: 99,
                progress: progress,
                userAgent: browserUserAgent,
                headers: bilibiliMediaHeaders()
            )
            progress(DownloadProgressEvent(status: "completed", progress: 100, message: "已完成：\(outputPath)"))
            return outputPath
        case .separate:
            let videoPath = downloadOutputPath(
                directory: downloadsDirectory,
                metadata: metadata,
                suffix: "视频",
                fileExtension: "mp4"
            )
            let audioPath = downloadOutputPath(
                directory: downloadsDirectory,
                metadata: metadata,
                suffix: "音频",
                fileExtension: "m4a"
            )
            try await runRemoteMediaFFmpeg(
                mediaURL: videoURL,
                outputPath: videoPath,
                transform: .video,
                duration: duration,
                progressMessage: "下载视频流",
                progressStart: 5,
                progressEnd: 52,
                progress: progress,
                userAgent: browserUserAgent,
                headers: bilibiliMediaHeaders()
            )
            let sourceURL = audioURL ?? videoURL
            try await runRemoteMediaFFmpeg(
                mediaURL: sourceURL,
                outputPath: audioPath,
                transform: .audio,
                duration: duration,
                progressMessage: "下载音频流",
                progressStart: 53,
                progressEnd: 99,
                progress: progress,
                userAgent: browserUserAgent,
                headers: bilibiliMediaHeaders()
            )
            let savedPath = "视频 \(videoPath)；音频 \(audioPath)"
            progress(DownloadProgressEvent(status: "completed", progress: 100, message: "已完成：\(savedPath)"))
            return savedPath
        }
    }

    private func processDownloadedCompleteFile(
        sourcePath: String,
        metadata: VideoMetadata,
        downloadsDirectory: URL,
        mode: DownloadMode,
        duration: Double?,
        progress: @escaping (DownloadProgressEvent) -> Void,
        removeSourceWhenDone: Bool
    ) async throws -> String {
        guard FileManager.default.fileExists(atPath: sourcePath) else {
            throw UserFacingError("下载失败：无法确认源视频保存路径")
        }
        defer {
            if removeSourceWhenDone {
                removeTemporaryFile(at: sourcePath)
            }
        }

        switch mode {
        case .complete:
            progress(DownloadProgressEvent(status: "completed", progress: 100, message: "已完成：\(sourcePath)"))
            return sourcePath
        case .audio:
            let outputPath = downloadOutputPath(
                directory: downloadsDirectory,
                metadata: metadata,
                suffix: outputSuffix(for: mode),
                fileExtension: "m4a"
            )
            try await runLocalMediaFFmpeg(
                inputPath: sourcePath,
                outputPath: outputPath,
                transform: .audio,
                duration: duration,
                progressMessage: progressMessage(for: mode),
                progressStart: 53,
                progressEnd: 99,
                progress: progress
            )
            progress(DownloadProgressEvent(status: "completed", progress: 100, message: "已完成：\(outputPath)"))
            return outputPath
        case .video:
            let outputPath = downloadOutputPath(
                directory: downloadsDirectory,
                metadata: metadata,
                suffix: outputSuffix(for: mode),
                fileExtension: "mp4"
            )
            try await runLocalMediaFFmpeg(
                inputPath: sourcePath,
                outputPath: outputPath,
                transform: .video,
                duration: duration,
                progressMessage: progressMessage(for: mode),
                progressStart: 53,
                progressEnd: 99,
                progress: progress
            )
            progress(DownloadProgressEvent(status: "completed", progress: 100, message: "已完成：\(outputPath)"))
            return outputPath
        case .separate:
            let videoPath = downloadOutputPath(
                directory: downloadsDirectory,
                metadata: metadata,
                suffix: "视频",
                fileExtension: "mp4"
            )
            let audioPath = downloadOutputPath(
                directory: downloadsDirectory,
                metadata: metadata,
                suffix: "音频",
                fileExtension: "m4a"
            )
            try await runLocalMediaFFmpeg(
                inputPath: sourcePath,
                outputPath: videoPath,
                transform: .video,
                duration: duration,
                progressMessage: "生成视频文件",
                progressStart: 53,
                progressEnd: 76,
                progress: progress
            )
            try await runLocalMediaFFmpeg(
                inputPath: sourcePath,
                outputPath: audioPath,
                transform: .audio,
                duration: duration,
                progressMessage: "生成音频文件",
                progressStart: 77,
                progressEnd: 99,
                progress: progress
            )
            let savedPath = "视频 \(videoPath)；音频 \(audioPath)"
            progress(DownloadProgressEvent(status: "completed", progress: 100, message: "已完成：\(savedPath)"))
            return savedPath
        }
    }

    private func downloadDirectMedia(
        metadata: VideoMetadata,
        mediaURL: String,
        downloadsDirectory: URL,
        mode: DownloadMode,
        duration: Double?,
        totalBytes: Int64?,
        progress: @escaping (DownloadProgressEvent) -> Void,
        userAgent: String,
        referer: String,
        platformName: String
    ) async throws -> String {
        if mode == .complete {
            let outputPath = downloadOutputPath(
                directory: downloadsDirectory,
                metadata: metadata,
                suffix: nil,
                fileExtension: "mp4"
            )
            try await runCurlDownload(
                url: mediaURL,
                outputPath: outputPath,
                totalBytes: totalBytes,
                progress: progress,
                userAgent: userAgent,
                referer: referer,
                platformName: platformName
            )
            progress(DownloadProgressEvent(status: "completed", progress: 100, message: "已完成：\(outputPath)"))
            return outputPath
        }

        let sourcePath = downloadOutputPath(
            directory: downloadsDirectory,
            metadata: metadata,
            suffix: "源视频-\(UUID().uuidString.prefix(8))",
            fileExtension: "mp4"
        )
        try await runCurlDownload(
            url: mediaURL,
            outputPath: sourcePath,
            totalBytes: totalBytes,
            progress: progress,
            userAgent: userAgent,
            referer: referer,
            platformName: platformName,
            progressMessage: "下载源视频",
            progressStart: 5,
            progressEnd: 52
        )

        return try await processDownloadedCompleteFile(
            sourcePath: sourcePath,
            metadata: metadata,
            downloadsDirectory: downloadsDirectory,
            mode: mode,
            duration: duration,
            progress: progress,
            removeSourceWhenDone: true
        )
    }

    private func downloadToutiaoViaMobilePage(
        metadata: VideoMetadata,
        downloadsDirectory: URL,
        mode: DownloadMode,
        progress: @escaping (DownloadProgressEvent) -> Void
    ) async throws -> String {
        let refreshedProfile = try? requestToutiaoDirectProfile(url: metadata.normalizedUrl)
        guard let mediaURL = textOrNil(refreshedProfile?.mediaURL)
            ?? textOrNil(metadata.directMediaUrl) else {
            throw UserFacingError("下载失败：今日头条播放地址已失效，请重新解析后再试")
        }

        return try await downloadDirectMedia(
            metadata: metadata,
            mediaURL: mediaURL,
            downloadsDirectory: downloadsDirectory,
            mode: mode,
            duration: refreshedProfile?.duration ?? durationSeconds(from: metadata.duration),
            totalBytes: refreshedProfile?.totalBytes,
            progress: progress,
            userAgent: mobileUserAgent,
            referer: metadata.normalizedUrl,
            platformName: SupportedPlatform.toutiao.name
        )
    }

    private func requestBilibiliPlayData(bvid: String, cid: Int64) throws -> BilibiliPlayurlResponse.DataItem {
        var components = URLComponents(string: "https://api.bilibili.com/x/player/playurl")
        components?.queryItems = [
            URLQueryItem(name: "bvid", value: bvid),
            URLQueryItem(name: "cid", value: "\(cid)"),
            URLQueryItem(name: "qn", value: "80"),
            URLQueryItem(name: "fnval", value: "16"),
            URLQueryItem(name: "fourk", value: "1")
        ]
        guard let apiURL = components?.url else {
            throw UserFacingError("下载失败：B 站视频参数不完整")
        }

        var data: Data?
        for resolveArguments in curlResolveArgumentSets(for: apiURL.host) {
            data = try? runCurl(arguments: [
                "--fail",
                "--silent",
                "--show-error",
                "--location",
                "--max-time",
                "30",
                "-A",
                browserUserAgent,
                "-e",
                "https://www.bilibili.com/",
            ] + resolveArguments + [
                apiURL.absoluteString
            ], timeout: 12).standardOutput
            if data != nil {
                break
            }
        }
        guard let data else {
            throw UserFacingError("网络异常：无法连接 B 站下载接口")
        }

        let apiResponse: BilibiliPlayurlResponse
        do {
            apiResponse = try decoder.decode(BilibiliPlayurlResponse.self, from: data)
        } catch {
            throw UserFacingError("下载失败：无法读取 B 站下载地址")
        }
        guard apiResponse.code == 0, let item = apiResponse.data else {
            throw UserFacingError("下载失败：B 站未返回可下载视频地址")
        }
        return item
    }

    private func bestBilibiliVideoStream(
        from streams: [BilibiliPlayurlResponse.MediaStream]?
    ) -> BilibiliPlayurlResponse.MediaStream? {
        let candidates = (streams ?? []).filter { $0.mediaURL != nil }
        let avcCandidates = candidates.filter { ($0.codecs ?? "").lowercased().hasPrefix("avc1") }
        return (avcCandidates.isEmpty ? candidates : avcCandidates).max { left, right in
            let leftScore = (left.height ?? 0, left.bandwidth ?? 0)
            let rightScore = (right.height ?? 0, right.bandwidth ?? 0)
            return leftScore < rightScore
        }
    }

    private func bestBilibiliAudioStream(
        from streams: [BilibiliPlayurlResponse.MediaStream]?
    ) -> BilibiliPlayurlResponse.MediaStream? {
        (streams ?? [])
            .filter { $0.mediaURL != nil }
            .max { ($0.bandwidth ?? 0) < ($1.bandwidth ?? 0) }
    }

    private func runBilibiliFFmpeg(
        videoURL: String,
        audioURL: String?,
        outputPath: String,
        duration: Double,
        progress: @escaping (DownloadProgressEvent) -> Void
    ) async throws {
        progress(DownloadProgressEvent(status: "downloading", progress: 5, message: "下载并合并中"))

        let headers = bilibiliMediaHeaders()
        var arguments = [
            "-y",
            "-nostdin",
            "-hide_banner",
            "-loglevel",
            "warning",
            "-user_agent",
            browserUserAgent,
            "-headers",
            headers,
            "-i",
            videoURL
        ]

        if let audioURL {
            arguments += [
                "-user_agent",
                browserUserAgent,
                "-headers",
                headers,
                "-i",
                audioURL,
                "-map",
                "0:v:0",
                "-map",
                "1:a:0"
            ]
        }

        arguments += [
            "-c",
            "copy",
            "-movflags",
            "+faststart",
            "-progress",
            "pipe:1",
            "-nostats",
            outputPath
        ]

        try await runStreamingFFmpeg(arguments: arguments) { line in
            if let event = Self.parseFFmpegProgressLine(line, duration: duration) {
                progress(event)
            }
        }
    }

    private enum RemoteMediaTransform {
        case audio
        case video
    }

    private func runRemoteMediaFFmpeg(
        mediaURL: String,
        outputPath: String,
        transform: RemoteMediaTransform,
        duration: Double?,
        progressMessage: String,
        progressStart: Int,
        progressEnd: Int,
        progress: @escaping (DownloadProgressEvent) -> Void,
        userAgent: String,
        referer: String? = nil,
        headers: String? = nil
    ) async throws {
        progress(DownloadProgressEvent(status: "downloading", progress: progressStart, message: progressMessage))

        var arguments = [
            "-y",
            "-nostdin",
            "-hide_banner",
            "-loglevel",
            "warning",
            "-user_agent",
            userAgent
        ]
        if let headers {
            arguments += ["-headers", headers]
        } else if let referer {
            arguments += ["-headers", "Referer: \(referer)\r\n"]
        }

        arguments += ["-i", mediaURL]
        switch transform {
        case .audio:
            arguments += [
                "-map",
                "0:a:0",
                "-vn",
                "-c:a",
                "aac",
                "-b:a",
                "192k"
            ]
        case .video:
            arguments += [
                "-map",
                "0:v:0",
                "-an",
                "-c:v",
                "copy",
                "-movflags",
                "+faststart"
            ]
        }

        arguments += [
            "-progress",
            "pipe:1",
            "-nostats",
            outputPath
        ]

        try await runStreamingFFmpeg(arguments: arguments) { line in
            if let duration,
               let event = Self.parseFFmpegProgressLine(line, duration: duration) {
                progress(
                    self.scaledProgressEvent(
                        event,
                        message: progressMessage,
                        start: progressStart,
                        end: progressEnd
                    )
                )
            } else if line == "progress=end" {
                progress(DownloadProgressEvent(status: "downloading", progress: progressEnd, message: "正在收尾"))
            }
        }
    }

    private func runLocalMediaFFmpeg(
        inputPath: String,
        outputPath: String,
        transform: RemoteMediaTransform,
        duration: Double?,
        progressMessage: String,
        progressStart: Int,
        progressEnd: Int,
        progress: @escaping (DownloadProgressEvent) -> Void
    ) async throws {
        progress(DownloadProgressEvent(status: "downloading", progress: progressStart, message: progressMessage))

        var arguments = [
            "-y",
            "-nostdin",
            "-hide_banner",
            "-loglevel",
            "warning",
            "-i",
            inputPath
        ]
        switch transform {
        case .audio:
            arguments += [
                "-map",
                "0:a:0",
                "-vn",
                "-c:a",
                "aac",
                "-b:a",
                "192k"
            ]
        case .video:
            arguments += [
                "-map",
                "0:v:0",
                "-an",
                "-c:v",
                "libx264",
                "-preset",
                "veryfast",
                "-crf",
                "18",
                "-pix_fmt",
                "yuv420p",
                "-movflags",
                "+faststart"
            ]
        }

        arguments += [
            "-progress",
            "pipe:1",
            "-nostats",
            outputPath
        ]

        try await runStreamingFFmpeg(arguments: arguments) { line in
            if let duration,
               let event = Self.parseFFmpegProgressLine(line, duration: duration) {
                progress(
                    self.scaledProgressEvent(
                        event,
                        message: progressMessage,
                        start: progressStart,
                        end: progressEnd
                    )
                )
            } else if line == "progress=end" {
                progress(DownloadProgressEvent(status: "downloading", progress: progressEnd, message: "正在收尾"))
            }
        }
    }

    private func durationSeconds(from displayDuration: String) -> Double? {
        let parts = displayDuration
            .split(separator: ":")
            .compactMap { Double($0) }
        guard !parts.isEmpty else {
            return nil
        }
        if parts.count == 3 {
            return parts[0] * 3600 + parts[1] * 60 + parts[2]
        }
        if parts.count == 2 {
            return parts[0] * 60 + parts[1]
        }
        return parts[0] > 0 ? parts[0] : nil
    }

    private func removeTemporaryFile(at path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            return
        }
        try? FileManager.default.removeItem(atPath: path)
    }

    private func uniqueOutputPath(directory: URL, baseName: String, fileExtension: String) -> String {
        let sanitizedBaseName = URLTools.sanitizeFilename(baseName)
        var candidate = directory.appendingPathComponent("\(sanitizedBaseName).\(fileExtension)")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(sanitizedBaseName) \(index).\(fileExtension)")
            index += 1
        }
        return candidate.path
    }

    private func temporaryOutputPath(baseName: String, fileExtension: String) -> String {
        let path = uniqueOutputPath(
            directory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            baseName: baseName,
            fileExtension: fileExtension
        )
        trackCurrentDownloadOutput(path)
        return path
    }

    private func downloadOutputPath(
        directory: URL,
        metadata: VideoMetadata,
        suffix: String?,
        fileExtension: String
    ) -> String {
        let path = uniqueOutputPath(
            directory: directory,
            baseName: outputBaseName(for: metadata, suffix: suffix),
            fileExtension: fileExtension
        )
        trackCurrentDownloadOutput(path)
        return path
    }

    private func outputTemplatePath(directory: URL, metadata: VideoMetadata, suffix: String?) -> String {
        let safeBaseName = URLTools.sanitizeFilename(outputBaseName(for: metadata, suffix: suffix))
        let path = directory
            .appendingPathComponent("\(safeBaseName).%(ext)s")
            .path
        if let taskIdentifier = DownloadExecutionContext.taskIdentifier {
            downloadControl.registerOutputTemplate(path, taskIdentifier: taskIdentifier)
        }
        return path
    }

    private func trackCurrentDownloadOutput(_ path: String) {
        guard let taskIdentifier = DownloadExecutionContext.taskIdentifier else {
            return
        }
        downloadControl.registerOutputPath(path, taskIdentifier: taskIdentifier)
    }

    private func registerCurrentDownloadProcess(_ process: Process) {
        guard let taskIdentifier = DownloadExecutionContext.taskIdentifier else {
            return
        }
        downloadControl.register(process: process, taskIdentifier: taskIdentifier)
    }

    private func unregisterCurrentDownloadProcess(_ process: Process) {
        guard let taskIdentifier = DownloadExecutionContext.taskIdentifier else {
            return
        }
        downloadControl.unregister(process: process, taskIdentifier: taskIdentifier)
    }

    private func throwIfCurrentDownloadCancelled() throws {
        guard let taskIdentifier = DownloadExecutionContext.taskIdentifier,
              downloadControl.isCancelled(taskIdentifier: taskIdentifier) else {
            return
        }
        throw UserFacingError("下载已取消")
    }

    private func outputBaseName(for metadata: VideoMetadata, suffix: String?) -> String {
        let baseName = metadata.suggestedFilename ?? metadata.title
        guard let suffix, !suffix.isEmpty else {
            return baseName
        }
        return "\(baseName) - \(suffix)"
    }

    private func outputSuffix(for mode: DownloadMode) -> String? {
        switch mode {
        case .complete:
            return nil
        case .audio:
            return "音频"
        case .video:
            return "仅视频"
        case .separate:
            return nil
        }
    }

    private func progressMessage(for mode: DownloadMode) -> String {
        switch mode {
        case .complete:
            return "下载中"
        case .audio:
            return "下载音频中"
        case .video:
            return "下载视频中"
        case .separate:
            return "下载中"
        }
    }

    private func scaledProgressEvent(
        _ event: DownloadProgressEvent,
        message: String,
        start: Int,
        end: Int
    ) -> DownloadProgressEvent {
        let clampedProgress = max(1, min(99, event.progress))
        let span = max(0, end - start)
        let scaledProgress = start + Int((Double(clampedProgress) / 99 * Double(span)).rounded())
        return DownloadProgressEvent(
            status: event.status,
            progress: max(start, min(end, scaledProgress)),
            message: event.message == "正在收尾" ? event.message : message
        )
    }

    private func bilibiliMediaHeaders() -> String {
        [
            "User-Agent: \(browserUserAgent)",
            "Referer: https://www.bilibili.com/",
            "Origin: https://www.bilibili.com"
        ].joined(separator: "\r\n") + "\r\n"
    }

    private func decodeInfo(from data: Data) throws -> YTDLPInfo {
        do {
            return try decoder.decode(YTDLPInfo.self, from: data)
        } catch {
            throw UserFacingError("解析失败：无法读取视频信息")
        }
    }

    private func buildQualities(from info: YTDLPInfo) -> [QualityOption] {
        let formats = (info.formats ?? [])
            .filter { $0.vcodec != "none" }
            .compactMap { format -> QualityOption? in
                guard let formatId = format.format_id else {
                    return nil
                }
                let heightLabel = format.height.map { "\($0)p" }
                let label = heightLabel ?? format.format ?? format.ext ?? "可下载格式"
                return QualityOption(
                    id: formatId,
                    label: label,
                    description: format.format ?? "yt-dlp 可下载格式",
                    available: true
                )
            }

        if formats.isEmpty {
            return [
                QualityOption(
                    id: "best",
                    label: "最佳可用质量",
                    description: "由 yt-dlp 自动选择",
                    available: true
                )
            ]
        }

        return Array(formats.prefix(6))
    }

    private func estimateSizeMb(from info: YTDLPInfo) -> Double? {
        if let directSize = megabytes(fromBytes: info.filesize ?? info.filesize_approx) {
            return directSize
        }

        if let requestedFormats = info.requested_formats, !requestedFormats.isEmpty {
            let byteSize = requestedFormats.compactMap(byteCount).reduce(0, +)
            if byteSize > 0 {
                return megabytes(fromBytes: byteSize)
            }

            let bitrateSize = requestedFormats
                .compactMap { estimatedBytes(fromKbps: $0.tbr ?? $0.abr, duration: info.duration) }
                .reduce(0, +)
            if bitrateSize > 0 {
                return megabytes(fromBytes: bitrateSize)
            }
        }

        let formats = info.formats ?? []
        let videoFormats = formats.filter { $0.vcodec != "none" }
        let audioFormats = formats.filter { $0.vcodec == "none" && $0.acodec != "none" }
        let bestVideo = videoFormats.max { left, right in
            let leftScore = (left.height ?? 0, left.tbr ?? 0)
            let rightScore = (right.height ?? 0, right.tbr ?? 0)
            return leftScore < rightScore
        }
        let bestAudio = audioFormats.max { ($0.tbr ?? $0.abr ?? 0) < ($1.tbr ?? $1.abr ?? 0) }

        let byteSize = [bestVideo, bestAudio].compactMap { $0 }.compactMap(byteCount).reduce(0, +)
        if byteSize > 0 {
            return megabytes(fromBytes: byteSize)
        }

        let bitrateSize = [bestVideo, bestAudio]
            .compactMap { $0 }
            .compactMap { estimatedBytes(fromKbps: $0.tbr ?? $0.abr, duration: info.duration) }
            .reduce(0, +)
        if bitrateSize > 0 {
            return megabytes(fromBytes: bitrateSize)
        }

        return megabytes(fromBytes: estimatedBytes(fromKbps: info.tbr, duration: info.duration))
    }

    private func estimateBilibiliSizeMb(
        from playData: BilibiliPlayurlResponse.DataItem?,
        fallbackDuration: Double
    ) -> Double? {
        guard let playData else {
            return nil
        }

        if let dash = playData.dash {
            let videoStream = bestBilibiliVideoStream(from: dash.video)
            let audioStream = bestBilibiliAudioStream(from: dash.audio)
            let byteSize = [videoStream, audioStream].compactMap { $0?.size.map(Double.init) }.reduce(0, +)
            if byteSize > 0 {
                return megabytes(fromBytes: byteSize)
            }

            let duration = dash.duration ?? fallbackDuration
            let bandwidth = [videoStream, audioStream].compactMap { $0?.bandwidth }.reduce(0, +)
            if duration > 0, bandwidth > 0 {
                return megabytes(fromBytes: Double(bandwidth) * duration / 8)
            }
        }

        if let durl = playData.durl?.first(where: { $0.mediaURL != nil }) {
            if let size = durl.size {
                return megabytes(fromBytes: Double(size))
            }
        }

        return nil
    }

    private func byteCount(for format: YTDLPInfo.Format) -> Double? {
        guard let value = format.filesize ?? format.filesize_approx, value > 0 else {
            return nil
        }
        return value
    }

    private func estimatedBytes(fromKbps bitrate: Double?, duration: Double?) -> Double? {
        guard let bitrate, let duration, bitrate > 0, duration > 0 else {
            return nil
        }
        return bitrate * 1000 * duration / 8
    }

    private func megabytes(fromBytes bytes: Double?) -> Double? {
        guard let bytes, bytes > 0 else {
            return nil
        }
        return (bytes / 1_048_576 * 10).rounded() / 10
    }

    private func formatDate(info: YTDLPInfo) -> String {
        if let dateText = textOrNil(info.upload_date) ?? textOrNil(info.release_date),
           dateText.count == 8 {
            let year = dateText.prefix(4)
            let month = dateText.dropFirst(4).prefix(2)
            let day = dateText.suffix(2)
            return "\(year)-\(month)-\(day)"
        }

        guard let timestamp = info.timestamp ?? info.release_timestamp else {
            return "未知日期"
        }
        let date = Date(timeIntervalSince1970: timestamp)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func formatDuration(_ duration: Double?) -> String {
        guard let duration else {
            return "未知时长"
        }
        let totalSeconds = Int(duration.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func runYTDLP(arguments: [String]) throws -> ProcessResult {
        let result = try runProcess(executable: resolveYTDLPPath(), arguments: arguments)
        guard result.exitCode == 0 else {
            throw standardizeYTDLPError(result.standardErrorText)
        }
        return result
    }

    private func runCurl(arguments: [String], timeout: TimeInterval = 35) throws -> ProcessResult {
        let curlPath = "/usr/bin/curl"
        guard FileManager.default.isExecutableFile(atPath: curlPath) else {
            throw UserFacingError("网络异常：系统 curl 不可用，无法发起解析请求")
        }

        let result = try runProcess(executable: curlPath, arguments: arguments, timeout: timeout)
        guard result.exitCode == 0 else {
            throw UserFacingError("网络异常：解析接口请求失败，请稍后重试")
        }
        return result
    }

    private func requestMediaContentLength(
        url: String,
        userAgent: String? = nil,
        referer: String? = nil
    ) -> Int64? {
        let curlPath = "/usr/bin/curl"
        guard FileManager.default.isExecutableFile(atPath: curlPath) else {
            return nil
        }

        let baseArguments = [
            "--silent",
            "--show-error",
            "--location",
            "--dump-header",
            "-",
            "--output",
            "/dev/null",
            "--connect-timeout",
            "15",
            "--max-time",
            "25",
            "-A",
            userAgent ?? mobileUserAgent,
            "-e",
            referer ?? "https://www.douyin.com/"
        ]

        for resolveArguments in curlResolveArgumentSets(for: URL(string: url)?.host) {
            let tailArguments = resolveArguments + [url]
            if let byteCount = requestContentLengthWithCurl(
                curlPath: curlPath,
                arguments: baseArguments + ["--head"] + tailArguments,
                validExitCodes: [0]
            ) {
                return byteCount
            }
            if let byteCount = requestContentLengthWithCurl(
                curlPath: curlPath,
                arguments: baseArguments + [
                    "--range",
                    "0-0",
                    "--max-filesize",
                    "1048576"
                ] + tailArguments,
                validExitCodes: [0, 63]
            ) {
                return byteCount
            }
        }

        return nil
    }

    private func probeMediaDuration(
        url: String,
        userAgent: String,
        referer: String
    ) -> Double? {
        guard let ffmpegPath = try? resolveFFmpegPath() else {
            return nil
        }
        let result = try? runProcess(
            executable: ffmpegPath,
            arguments: [
                "-hide_banner",
                "-loglevel",
                "info",
                "-user_agent",
                userAgent,
                "-headers",
                "Referer: \(referer)\r\n",
                "-i",
                url
            ],
            timeout: 25
        )
        guard let result else {
            return nil
        }
        let output = result.standardErrorText
            + (String(data: result.standardOutput, encoding: .utf8) ?? "")
        let pattern = #"Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: output,
                range: NSRange(output.startIndex..<output.endIndex, in: output)
              ),
              match.numberOfRanges == 4,
              let hoursRange = Range(match.range(at: 1), in: output),
              let minutesRange = Range(match.range(at: 2), in: output),
              let secondsRange = Range(match.range(at: 3), in: output),
              let hours = Double(output[hoursRange]),
              let minutes = Double(output[minutesRange]),
              let seconds = Double(output[secondsRange]) else {
            return nil
        }
        let duration = hours * 3600 + minutes * 60 + seconds
        return duration > 0 ? duration : nil
    }

    private func requestContentLengthWithCurl(curlPath: String, arguments: [String], validExitCodes: [Int32]) -> Int64? {
        guard let result = try? runProcess(executable: curlPath, arguments: arguments, timeout: 30),
              validExitCodes.contains(result.exitCode),
              let headerText = String(data: result.standardOutput, encoding: .utf8),
              let byteCount = parseContentLength(from: headerText) else {
            return nil
        }
        return byteCount
    }

    private func parseContentLength(from headerText: String) -> Int64? {
        var contentLength: Int64?
        for line in headerText.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercased = trimmed.lowercased()
            if lowercased.hasPrefix("content-length:") {
                let value = trimmed.dropFirst("content-length:".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let bytes = Int64(value), bytes > 0 {
                    contentLength = bytes
                }
            } else if lowercased.hasPrefix("content-range:"),
                      let slashIndex = trimmed.lastIndex(of: "/") {
                let value = trimmed[trimmed.index(after: slashIndex)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let bytes = Int64(value), bytes > 0 {
                    contentLength = bytes
                }
            }
        }
        return contentLength
    }

    private func runCurlDownload(
        url: String,
        outputPath: String,
        totalBytes: Int64?,
        progress: @escaping (DownloadProgressEvent) -> Void,
        userAgent: String? = nil,
        referer: String? = nil,
        platformName: String = "抖音",
        progressMessage: String = "下载中",
        progressStart: Int = 5,
        progressEnd: Int = 99
    ) async throws {
        let curlPath = "/usr/bin/curl"
        guard FileManager.default.isExecutableFile(atPath: curlPath) else {
            throw UserFacingError("网络异常：系统 curl 不可用，无法下载")
        }

        progress(DownloadProgressEvent(status: "downloading", progress: progressStart, message: progressMessage))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: curlPath)
        process.arguments = [
            "--fail",
            "--silent",
            "--show-error",
            "--location",
            "--connect-timeout",
            "20",
            "--retry",
            "2",
            "--retry-delay",
            "1",
            "-A",
            userAgent ?? mobileUserAgent,
            "-e",
            referer ?? "https://www.douyin.com/",
            "--output",
            outputPath,
            url
        ]
        process.environment = buildEnvironment()

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let outputBuffer = LockedData()
        let errorBuffer = LockedData()
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                outputBuffer.append(data)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                errorBuffer.append(data)
            }
        }

        try process.run()
        registerCurrentDownloadProcess(process)
        defer {
            unregisterCurrentDownloadProcess(process)
        }

        var lastProgress = progressStart
        while process.isRunning {
            if let totalBytes, totalBytes > 0 {
                let attributes = try? FileManager.default.attributesOfItem(atPath: outputPath)
                let currentBytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                let ratio = max(0, min(1, Double(currentBytes) / Double(totalBytes)))
                let span = max(0, progressEnd - progressStart)
                let currentProgress = max(
                    progressStart,
                    min(progressEnd, progressStart + Int((ratio * Double(span)).rounded()))
                )
                if currentProgress > lastProgress {
                    lastProgress = currentProgress
                    progress(DownloadProgressEvent(status: "downloading", progress: currentProgress, message: progressMessage))
                }
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        process.waitUntilExit()

        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        outputBuffer.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
        errorBuffer.append(errorPipe.fileHandleForReading.readDataToEndOfFile())

        try throwIfCurrentDownloadCancelled()
        guard process.terminationStatus == 0 else {
            let errorText = [
                String(data: outputBuffer.data(), encoding: .utf8),
                String(data: errorBuffer.data(), encoding: .utf8)
            ]
                .compactMap { $0 }
                .joined(separator: "\n")
            throw standardizeCurlDownloadError(errorText, platformName: platformName)
        }

        progress(DownloadProgressEvent(status: "downloading", progress: progressEnd, message: "正在收尾"))
    }

    private func runStreamingYTDLP(arguments: [String], onLine: @escaping (String) -> Void) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try resolveYTDLPPath())
        process.arguments = arguments
        process.environment = buildEnvironment()

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let errorBuffer = LockedData()
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                errorBuffer.append(data)
                if let line = String(data: data, encoding: .utf8) {
                    line.components(separatedBy: .newlines)
                        .filter { !$0.isEmpty }
                        .forEach(onLine)
                }
            }
        }
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
                return
            }
            text.components(separatedBy: .newlines)
                .filter { !$0.isEmpty }
                .forEach(onLine)
        }

        try process.run()
        registerCurrentDownloadProcess(process)
        defer {
            unregisterCurrentDownloadProcess(process)
        }
        process.waitUntilExit()
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil

        try throwIfCurrentDownloadCancelled()
        guard process.terminationStatus == 0 else {
            let errorText = String(data: errorBuffer.data(), encoding: .utf8) ?? ""
            throw standardizeYTDLPError(errorText)
        }
    }

    private func runStreamingFFmpeg(arguments: [String], onLine: @escaping (String) -> Void) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try resolveFFmpegPath())
        process.arguments = arguments
        process.environment = buildEnvironment()

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let errorBuffer = LockedData()
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
                return
            }
            text.components(separatedBy: .newlines)
                .filter { !$0.isEmpty }
                .forEach(onLine)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                errorBuffer.append(data)
            }
        }

        try process.run()
        registerCurrentDownloadProcess(process)
        defer {
            unregisterCurrentDownloadProcess(process)
        }
        process.waitUntilExit()
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil

        try throwIfCurrentDownloadCancelled()
        guard process.terminationStatus == 0 else {
            let errorText = String(data: errorBuffer.data(), encoding: .utf8) ?? ""
            throw standardizeFFmpegError(errorText)
        }
    }

    private func runProcess(executable: String, arguments: [String], timeout: TimeInterval = 45) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = buildEnvironment()

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let outputBuffer = LockedData()
        let errorBuffer = LockedData()
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                outputBuffer.append(data)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                errorBuffer.append(data)
            }
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            finished.signal()
        }

        try process.run()
        registerCurrentDownloadProcess(process)
        defer {
            unregisterCurrentDownloadProcess(process)
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 3) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                finished.wait()
            }
            throw UserFacingError("网络异常：解析请求超时，请稍后重试或更换链接")
        }

        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        outputBuffer.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
        errorBuffer.append(errorPipe.fileHandleForReading.readDataToEndOfFile())

        try throwIfCurrentDownloadCancelled()
        return ProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: outputBuffer.data(),
            standardError: errorBuffer.data()
        )
    }

    private func resolveYTDLPPath() throws -> String {
        for candidate in RuntimeToolPaths.ytDLPCandidates()
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }

        throw UserFacingError("未找到 yt-dlp。请先安装 yt-dlp，或设置 EK_STREAMDL_YTDLP_PATH 指向可执行文件。")
    }

    private func resolveFFmpegPath() throws -> String {
        for candidate in RuntimeToolPaths.ffmpegCandidates()
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }

        throw UserFacingError("未找到 ffmpeg。请先安装 ffmpeg，或设置 EK_STREAMDL_FFMPEG_PATH 指向可执行文件。")
    }

    private func buildEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let extraPaths = [
            RuntimeToolPaths.managedDirectoryPathIfAvailable(),
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ].compactMap { $0 }
        let currentPath = environment["PATH"] ?? ""
        environment["PATH"] = ([currentPath] + extraPaths).filter { !$0.isEmpty }.joined(separator: ":")
        applySystemProxy(to: &environment)
        return environment
    }

    private func applySystemProxy(to environment: inout [String: String]) {
        guard let proxy = URLSessionConfiguration.default.connectionProxyDictionary else {
            return
        }
        func stringValue(_ key: String) -> String? {
            (proxy[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func intValue(_ key: String) -> Int? {
            (proxy[key] as? NSNumber)?.intValue
        }
        if intValue("HTTPEnable") == 1,
           let host = stringValue("HTTPProxy"), !host.isEmpty {
            let port = intValue("HTTPPort") ?? 80
            environment["http_proxy"] = environment["http_proxy"] ?? "http://\(host):\(port)"
        }
        if intValue("HTTPSEnable") == 1,
           let host = stringValue("HTTPSProxy"), !host.isEmpty {
            let port = intValue("HTTPSPort") ?? 443
            environment["https_proxy"] = environment["https_proxy"] ?? "http://\(host):\(port)"
        }
    }

    private func standardizeYTDLPError(_ rawError: String) -> UserFacingError {
        let lowercased = rawError.lowercased()
        if lowercased.contains("unsupported url") {
            return UserFacingError("暂不支持的平台或链接格式")
        }
        if lowercased.contains("private") || lowercased.contains("login") || lowercased.contains("cookies") {
            return UserFacingError("平台限制导致无法下载：该内容可能需要登录或不是公开视频")
        }
        if lowercased.contains("permission") || lowercased.contains("operation not permitted") {
            return UserFacingError("权限不足：无法写入下载目录")
        }
        if lowercased.contains("network") || lowercased.contains("timed out") || lowercased.contains("connection") {
            return UserFacingError("网络异常：请检查网络后重试")
        }
        if lowercased.contains("ffmpeg") {
            return UserFacingError("下载失败：需要安装 ffmpeg 以合并或处理视频")
        }
        return UserFacingError("解析或下载失败：平台可能限制访问，或链接已失效")
    }

    private func standardizeFFmpegError(_ rawError: String) -> UserFacingError {
        let lowercased = rawError.lowercased()
        if lowercased.contains("permission") || lowercased.contains("operation not permitted") {
            return UserFacingError("权限不足：无法写入下载目录")
        }
        if lowercased.contains("403") || lowercased.contains("forbidden") {
            return UserFacingError("下载失败：媒体地址拒绝访问，请稍后重试或更换链接")
        }
        if lowercased.contains("network") || lowercased.contains("timed out") || lowercased.contains("connection") {
            return UserFacingError("网络异常：请检查网络后重试")
        }
        if lowercased.contains("invalid data") || lowercased.contains("moov atom not found") {
            return UserFacingError("下载失败：媒体数据无效，请稍后重试或更换链接")
        }
        return UserFacingError("下载失败：无法处理视频文件")
    }

    private func standardizeCurlDownloadError(_ rawError: String, platformName: String) -> UserFacingError {
        let lowercased = rawError.lowercased()
        if lowercased.contains("permission") || lowercased.contains("operation not permitted") {
            return UserFacingError("权限不足：无法写入下载目录")
        }
        if lowercased.contains("403") || lowercased.contains("forbidden") {
            return UserFacingError("下载失败：\(platformName)媒体地址拒绝访问，请重新解析后重试")
        }
        if lowercased.contains("404") || lowercased.contains("not found") {
            return UserFacingError("下载失败：\(platformName)媒体地址已失效，请重新解析后重试")
        }
        if lowercased.contains("timed out") || lowercased.contains("connection") || lowercased.contains("could not resolve") {
            return UserFacingError("网络异常：请检查网络后重试")
        }
        return UserFacingError("下载失败：无法保存\(platformName)视频")
    }

    static func parseProgressLine(_ line: String) -> DownloadProgressEvent? {
        guard line.hasPrefix("download:") else {
            return nil
        }
        let payload = String(line.dropFirst("download:".count))
        let percentText = payload.components(separatedBy: "|").first ?? ""
        let numericText = percentText
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let progressValue = Double(numericText) ?? 0
        let progress = max(1, min(99, Int(progressValue.rounded())))
        return DownloadProgressEvent(status: "downloading", progress: progress, message: "下载中")
    }

    static func parseFFmpegProgressLine(_ line: String, duration: Double) -> DownloadProgressEvent? {
        if line == "progress=end" {
            return DownloadProgressEvent(status: "downloading", progress: 99, message: "正在收尾")
        }

        guard duration > 0 else {
            return nil
        }

        let prefixes = ["out_time_us=", "out_time_ms="]
        guard let prefix = prefixes.first(where: { line.hasPrefix($0) }) else {
            return nil
        }
        let rawValue = String(line.dropFirst(prefix.count))
        guard let microseconds = Double(rawValue) else {
            return nil
        }

        let seconds = microseconds / 1_000_000
        let ratio = max(0, min(1, seconds / duration))
        let progress = max(5, min(99, 5 + Int((ratio * 94).rounded())))
        return DownloadProgressEvent(status: "downloading", progress: progress, message: "下载并合并中")
    }
}

private enum DownloadExecutionContext {
    @TaskLocal static var taskIdentifier: String?
}

private final class DownloadControlRegistry {
    private final class State {
        var processes: [ObjectIdentifier: Process] = [:]
        var outputPaths: Set<String> = []
        var outputTemplates: [String: Set<String>] = [:]
        var isCancelled = false
        var isPaused = false
    }

    private struct Snapshot {
        var processes: [Process]
        var outputPaths: Set<String>
        var outputTemplates: [String: Set<String>]
    }

    private let lock = NSLock()
    private var states: [String: State] = [:]

    func begin(taskIdentifier: String) {
        lock.lock()
        states[taskIdentifier] = State()
        lock.unlock()
    }

    func register(process: Process, taskIdentifier: String) {
        lock.lock()
        let state = states[taskIdentifier] ?? State()
        states[taskIdentifier] = state
        state.processes[ObjectIdentifier(process)] = process
        let shouldTerminate = state.isCancelled
        let shouldPause = state.isPaused
        lock.unlock()

        if shouldTerminate, process.isRunning {
            process.terminate()
        } else if shouldPause, process.isRunning {
            kill(process.processIdentifier, SIGSTOP)
        }
    }

    func pause(taskIdentifier: String) throws {
        lock.lock()
        guard let state = states[taskIdentifier], !state.isCancelled else {
            lock.unlock()
            throw UserFacingError("当前下载任务无法暂停")
        }
        state.isPaused = true
        let processes = Array(state.processes.values)
        lock.unlock()
        for process in processes where process.isRunning {
            kill(process.processIdentifier, SIGSTOP)
        }
    }

    func resume(taskIdentifier: String) throws {
        lock.lock()
        guard let state = states[taskIdentifier], !state.isCancelled else {
            lock.unlock()
            throw UserFacingError("当前下载任务无法继续")
        }
        state.isPaused = false
        let processes = Array(state.processes.values)
        lock.unlock()
        for process in processes where process.isRunning {
            kill(process.processIdentifier, SIGCONT)
        }
    }

    func unregister(process: Process, taskIdentifier: String) {
        lock.lock()
        states[taskIdentifier]?.processes.removeValue(forKey: ObjectIdentifier(process))
        lock.unlock()
    }

    func registerOutputPath(_ path: String, taskIdentifier: String) {
        lock.lock()
        let state = states[taskIdentifier] ?? State()
        states[taskIdentifier] = state
        state.outputPaths.insert(path)
        lock.unlock()
    }

    func registerOutputTemplate(_ path: String, taskIdentifier: String) {
        let existingPaths = matchingPaths(for: path)
        lock.lock()
        let state = states[taskIdentifier] ?? State()
        states[taskIdentifier] = state
        state.outputTemplates[path] = existingPaths
        lock.unlock()
    }

    func isCancelled(taskIdentifier: String) -> Bool {
        lock.lock()
        let value = states[taskIdentifier]?.isCancelled ?? false
        lock.unlock()
        return value
    }

    func finishSuccess(taskIdentifier: String) {
        lock.lock()
        states.removeValue(forKey: taskIdentifier)
        lock.unlock()
    }

    func finishFailure(taskIdentifier: String) {
        lock.lock()
        states[taskIdentifier]?.processes.removeAll()
        lock.unlock()
    }

    func finishCancelled(taskIdentifier: String) {
        lock.lock()
        states.removeValue(forKey: taskIdentifier)
        lock.unlock()
    }

    func existingOutputPaths(taskIdentifier: String) -> Set<String> {
        lock.lock()
        guard let state = states[taskIdentifier] else {
            lock.unlock()
            return []
        }
        let snapshot = snapshot(from: state)
        lock.unlock()
        var paths = snapshot.outputPaths
        for (template, existingPaths) in snapshot.outputTemplates {
            paths.formUnion(matchingPaths(for: template).subtracting(existingPaths))
        }
        return Set(paths.filter { FileManager.default.fileExists(atPath: $0) })
    }

    func deleteTrackedOutputs(taskIdentifier: String) {
        lock.lock()
        guard let state = states[taskIdentifier] else {
            lock.unlock()
            return
        }
        let snapshot = snapshot(from: state)
        lock.unlock()
        cleanup(snapshot)
    }

    func cancel(taskIdentifier: String, deletePartialFiles: Bool) async {
        let initialSnapshot: Snapshot
        lock.lock()
        let state = states[taskIdentifier] ?? State()
        states[taskIdentifier] = state
        state.isCancelled = true
        state.isPaused = false
        initialSnapshot = snapshot(from: state)
        lock.unlock()

        resume(initialSnapshot.processes)
        terminate(initialSnapshot.processes)
        try? await Task.sleep(nanoseconds: 220_000_000)

        lock.lock()
        let latestSnapshot = states[taskIdentifier].map { snapshot(from: $0) } ?? initialSnapshot
        lock.unlock()

        forceTerminate(latestSnapshot.processes)
        try? await Task.sleep(nanoseconds: 100_000_000)

        guard deletePartialFiles else {
            return
        }
        cleanup(initialSnapshot)
        cleanup(latestSnapshot)
    }

    private func snapshot(from state: State) -> Snapshot {
        Snapshot(
            processes: Array(state.processes.values),
            outputPaths: state.outputPaths,
            outputTemplates: state.outputTemplates
        )
    }

    private func terminate(_ processes: [Process]) {
        for process in processes where process.isRunning {
            process.terminate()
        }
    }

    private func resume(_ processes: [Process]) {
        for process in processes where process.isRunning {
            kill(process.processIdentifier, SIGCONT)
        }
    }

    private func forceTerminate(_ processes: [Process]) {
        for process in processes where process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private func cleanup(_ snapshot: Snapshot) {
        snapshot.outputPaths.forEach(removeFileIfPresent(at:))
        for (template, existingPaths) in snapshot.outputTemplates {
            let createdPaths = matchingPaths(for: template).subtracting(existingPaths)
            createdPaths.forEach(removeFileIfPresent(at:))
        }
    }

    private func matchingPaths(for outputTemplate: String) -> Set<String> {
        guard let markerRange = outputTemplate.range(of: "%(ext)s") else {
            return []
        }
        let prefixPath = String(outputTemplate[..<markerRange.lowerBound])
        let prefixURL = URL(fileURLWithPath: prefixPath)
        let directoryURL = prefixURL.deletingLastPathComponent()
        let filenamePrefix = prefixURL.lastPathComponent
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return Set(
            fileURLs
                .filter { $0.lastPathComponent.hasPrefix(filenamePrefix) }
                .map(\.path)
        )
    }

    private func removeFileIfPresent(at path: String) {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return
        }
        try? FileManager.default.removeItem(atPath: path)
    }
}

struct ProcessResult {
    var exitCode: Int32
    var standardOutput: Data
    var standardError: Data

    var standardErrorText: String {
        String(data: standardError, encoding: .utf8) ?? ""
    }
}

private final class LockedData {
    private var storage = Data()
    private let lock = NSLock()

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    func data() -> Data {
        lock.lock()
        let value = storage
        lock.unlock()
        return value
    }
}

final class RedirectCaptureDelegate: NSObject, URLSessionTaskDelegate {
    private let lock = NSLock()
    private var capturedURL: URL?

    var redirectURL: URL? {
        lock.lock()
        let value = capturedURL
        lock.unlock()
        return value
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        capturedURL = request.url
        lock.unlock()
        completionHandler(nil)
    }
}
