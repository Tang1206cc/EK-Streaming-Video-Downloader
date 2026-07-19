import Foundation

final class DiagnosticLogStore {
    static let shared = DiagnosticLogStore()

    private let lock = NSLock()
    private var entries: [String] = []
    private let formatter = ISO8601DateFormatter()

    func append(_ category: String, _ message: String) {
        lock.lock()
        entries.append("[\(formatter.string(from: Date()))] [\(category)] \(message)")
        if entries.count > 300 {
            entries.removeFirst(entries.count - 300)
        }
        lock.unlock()
    }

    func text() -> String {
        lock.lock()
        let snapshot = entries.joined(separator: "\n")
        lock.unlock()
        return snapshot
    }
}

struct VideoMetadata: Codable {
    var id: String
    var originalUrl: String
    var normalizedUrl: String
    var platform: String
    var platformName: String
    var title: String
    var author: String
    var publishedAt: String
    var duration: String
    var coverUrl: String
    var qualities: [QualityOption]
    var estimatedSizeMb: Double?
    var parseMode: String
    var note: String
    var suggestedFilename: String?
    var savedPath: String?
    var collection: VideoCollection? = nil
    var selectedCollectionItems: [VideoCollectionItem]? = nil
    var directMediaUrl: String? = nil
}

enum DownloadMode: String, Codable {
    case complete
    case audio
    case video
    case separate
}

struct QualityOption: Codable {
    var id: String
    var label: String
    var description: String
    var available: Bool
}

struct VideoCollection: Codable {
    var id: String
    var title: String
    var items: [VideoCollectionItem]
}

struct VideoCollectionItem: Codable {
    var id: String
    var title: String
    var url: String
    var platform: String
    var duration: String?
    var coverUrl: String?
    var index: Int
}

struct DownloadProgressEvent: Codable {
    var status: String
    var progress: Int
    var message: String
    var duration: String? = nil
    var estimatedSizeMb: Double? = nil
    var weChatAuthorized: Bool? = nil
}

struct YTDLPInfo: Decodable {
    var id: String?
    var webpage_url: String?
    var original_url: String?
    var title: String?
    var uploader: String?
    var uploader_id: String?
    var channel: String?
    var timestamp: Double?
    var release_timestamp: Double?
    var upload_date: String?
    var release_date: String?
    var duration: Double?
    var thumbnail: String?
    var thumbnails: [Thumbnail]?
    var entries: [Entry]?
    var formats: [Format]?
    var requested_formats: [Format]?
    var filesize: Double?
    var filesize_approx: Double?
    var tbr: Double?

    struct Thumbnail: Decodable {
        var url: String?
    }

    struct Entry: Decodable {
        var id: String?
        var url: String?
        var webpage_url: String?
        var title: String?
        var duration: Double?
        var thumbnail: String?
        var uploader: String?
        var channel: String?
    }

    struct Format: Decodable {
        var format_id: String?
        var format: String?
        var ext: String?
        var height: Int?
        var acodec: String?
        var vcodec: String?
        var filesize: Double?
        var filesize_approx: Double?
        var tbr: Double?
        var abr: Double?
    }
}

struct XiaohongshuInitialState: Decodable {
    var note: NoteStore?

    struct NoteStore: Decodable {
        var noteDetailMap: [String: NoteDetail]?
    }

    struct NoteDetail: Decodable {
        var note: Note?
    }

    struct Note: Decodable {
        var noteId: String?
        var title: String?
        var desc: String?
        var time: Double?
        var lastUpdateTime: Double?
        var user: User?
        var imageList: [ImageItem]?
    }

    struct User: Decodable {
        var userId: String?
        var nickname: String?
    }

    struct ImageItem: Decodable {
        var url: String?
        var urlPre: String?
        var urlDefault: String?
        var infoList: [ImageInfo]?
    }

    struct ImageInfo: Decodable {
        var imageScene: String?
        var url: String?
    }
}

struct KuaishouInitialState: Decodable {
    var pages: [Page]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let pageMap = try container.decode([String: Page].self)
        pages = Array(pageMap.values)
    }

    struct Page: Decodable {
        var photo: Photo?
    }

    struct Photo: Decodable {
        var photoId: String?
        var caption: String?
        var userEid: String?
        var userName: String?
        var timestamp: Double?
        var duration: Double?
        var coverUrls: [MediaURL]?
        var webpCoverUrls: [MediaURL]?
        var mainMvUrls: [MediaURL]?
        var manifest: Manifest?
        var share_info: String?
    }

    struct Manifest: Decodable {
        var adaptationSet: [AdaptationSet]?
    }

    struct AdaptationSet: Decodable {
        var duration: Double?
        var representation: [Representation]?
    }

    struct Representation: Decodable {
        var id: Int?
        var qualityLabel: String?
        var qualityType: String?
        var width: Int?
        var height: Int?
        var avgBitrate: Double?
        var fileSize: Double?
        var url: String?
        var backupUrl: [String]?
        var videoCodec: String?
        var comment: String?
    }

    struct MediaURL: Decodable {
        var cdn: String?
        var url: String?
    }
}

struct WeChatChannelsFeedResponse: Decodable {
    var data: DataItem?
    var errCode: Int?
    var errMsg: String?

    struct DataItem: Decodable {
        var authorInfo: AuthorInfo?
        var feedInfo: FeedInfo?
        var sceneInfo: SceneInfo?
    }

    struct AuthorInfo: Decodable {
        var nickname: String?
        var headImgUrl: String?
        var authIconUrl: String?
    }

    struct FeedInfo: Decodable {
        var videoUrl: String?
        var originVideoUrl: String?
        var description: String?
        var mediaType: Int?
        var createtime: Double?
        var coverUrl: String?
        var h264VideoInfo: VideoInfo?
        var h265VideoInfo: VideoInfo?
    }

    struct VideoInfo: Decodable {
        var videoUrl: String?
    }

    struct SceneInfo: Decodable {
        var dynamicExportId: String?
    }
}

struct WeChatChannelsYuanbaoParseResponse: Decodable {
    var code: Int?
    var msg: String?
    var data: DataItem?

    struct DataItem: Decodable {
        var wxExportId: String?
        var coverUrl: String?
        var author: String?
        var desc: String?
        var playableUrl: String?

        enum CodingKeys: String, CodingKey {
            case wxExportId = "wx_export_id"
            case coverUrl = "cover_url"
            case author
            case desc
            case playableUrl = "playable_url"
        }
    }
}

struct BilibiliViewResponse: Decodable {
    var code: Int
    var data: DataItem?

    struct DataItem: Decodable {
        var bvid: String
        var cid: Int64
        var title: String
        var pubdate: Double?
        var duration: Int
        var pic: String?
        var owner: Owner?
        var pages: [Page]?
        var ugc_season: UGCSeason?

        struct Owner: Decodable {
            var name: String?
        }

        struct Page: Decodable {
            var cid: Int64
            var page: Int?
            var part: String?
            var duration: Int?
            var first_frame: String?
        }

        struct UGCSeason: Decodable {
            var id: Int?
            var title: String?
            var sections: [Section]?

            struct Section: Decodable {
                var title: String?
                var episodes: [Episode]?
            }

            struct Episode: Decodable {
                var bvid: String?
                var cid: Int64?
                var title: String?
                var cover: String?
                var duration: Int?
            }
        }
    }
}

struct BilibiliPlayurlResponse: Decodable {
    var code: Int
    var message: String?
    var data: DataItem?

    struct DataItem: Decodable {
        var dash: Dash?
        var durl: [Durl]?
    }

    struct Dash: Decodable {
        var duration: Double?
        var video: [MediaStream]?
        var audio: [MediaStream]?
    }

    struct MediaStream: Decodable {
        var baseUrl: String?
        var base_url: String?
        var backupUrl: [String]?
        var backup_url: [String]?
        var bandwidth: Int?
        var size: Int64?
        var codecs: String?
        var width: Int?
        var height: Int?

        var mediaURL: String? {
            baseUrl ?? base_url ?? backupUrl?.first ?? backup_url?.first
        }
    }

    struct Durl: Decodable {
        var url: String?
        var backup_url: [String]?
        var length: Int?
        var size: Int64?

        var mediaURL: String? {
            url ?? backup_url?.first
        }
    }
}

struct DouyinRouterData: Decodable {
    var loaderData: LoaderData

    struct LoaderData: Decodable {
        var videoPage: VideoPage?
        var notePage: VideoPage?

        var primaryPage: VideoPage? {
            videoPage ?? notePage
        }

        enum CodingKeys: String, CodingKey {
            case videoPage = "video_(id)/page"
            case notePage = "note_(id)/page"
        }
    }

    struct VideoPage: Decodable {
        var videoInfoRes: VideoInfoResponse?
    }

    struct VideoInfoResponse: Decodable {
        var item_list: [Item]?
    }

    struct Item: Decodable {
        var aweme_id: String
        var desc: String?
        var create_time: Double?
        var author: Author?
        var music: Music?
        var video: Video?
        var images: [ImageItem]?
    }

    struct Author: Decodable {
        var nickname: String?
    }

    struct Music: Decodable {
        var duration: Double?
    }

    struct Video: Decodable {
        var duration: Double?
        var cover: URLList?
        var play_addr: URLList?
    }

    struct ImageItem: Decodable {
        var url_list: [String]?
        var download_url_list: [String]?
        var height: Double?
        var width: Double?

        var displayURL: String? {
            url_list?.first ?? download_url_list?.first
        }
    }

    struct URLList: Decodable {
        var uri: String?
        var url_list: [String]?
        var data_size: Double?

        var mediaURL: String? {
            url_list?.first
        }
    }
}
