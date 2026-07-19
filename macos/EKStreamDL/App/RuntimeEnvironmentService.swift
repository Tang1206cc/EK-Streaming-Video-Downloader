import CryptoKit
import Darwin
import Foundation

struct RuntimeEnvironmentComponent: Codable {
    var id: String
    var name: String
    var purpose: String
    var required: Bool
    var installed: Bool
    var installable: Bool
    var version: String?
    var path: String?
    var detail: String
    var updateAvailable: Bool? = nil
    var latestVersion: String? = nil
}

struct RuntimeEnvironmentReport: Codable {
    var ready: Bool
    var components: [RuntimeEnvironmentComponent]
    var missingComponentIds: [String]
    var recommendedComponentIds: [String]? = nil
    var message: String
    var managedToolsDirectory: String
    var checkedAt: String? = nil
    var diagnostics: [String]? = nil
}

struct RuntimeEnvironmentProgressEvent: Codable {
    var progress: Int
    var message: String
    var componentId: String?
}

enum RuntimeToolPaths {
    static func managedToolsDirectory() throws -> URL {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw UserFacingError("无法定位当前用户的应用支持目录")
        }
        return applicationSupport
            .appendingPathComponent("EK StreamDL", isDirectory: true)
            .appendingPathComponent("Tools", isDirectory: true)
    }

    static func managedYTDLPURL() throws -> URL {
        try managedToolsDirectory().appendingPathComponent("yt-dlp_macos", isDirectory: false)
    }

    static func managedFFmpegURL() throws -> URL {
        try managedToolsDirectory().appendingPathComponent("ffmpeg", isDirectory: false)
    }

    static func ytDLPCandidates() -> [String] {
        uniquePaths([
            Bundle.main.url(forResource: "yt-dlp_macos", withExtension: nil)?.path,
            ProcessInfo.processInfo.environment["EK_STREAMDL_YTDLP_PATH"],
            try? managedYTDLPURL().path,
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
            "/usr/bin/yt-dlp"
        ])
    }

    static func ffmpegCandidates() -> [String] {
        uniquePaths([
            Bundle.main.url(forResource: "ffmpeg", withExtension: nil)?.path,
            ProcessInfo.processInfo.environment["EK_STREAMDL_FFMPEG_PATH"],
            try? managedFFmpegURL().path,
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ])
    }

    static func managedDirectoryPathIfAvailable() -> String? {
        try? managedToolsDirectory().path
    }

    private static func uniquePaths(_ paths: [String?]) -> [String] {
        var seen = Set<String>()
        return paths.compactMap { path in
            guard let path, !path.isEmpty, seen.insert(path).inserted else {
                return nil
            }
            return path
        }
    }
}

actor RuntimeEnvironmentService {
    private let fileManager = FileManager.default
    private let ytDLPChecksumsURL = URL(
        string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS"
    )!
    private let ytDLPDownloadURL = URL(
        string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos"
    )!
    private let ytDLPReleaseURL = URL(
        string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest"
    )!
    private let platformProbeURLs: [(String, URL)] = [
        ("哔哩哔哩", URL(string: "https://www.bilibili.com/")!),
        ("抖音", URL(string: "https://www.douyin.com/")!),
        ("快手", URL(string: "https://www.kuaishou.com/")!),
        ("小红书", URL(string: "https://www.xiaohongshu.com/")!),
        ("今日头条", URL(string: "https://www.toutiao.com/")!),
        ("微信视频号", URL(string: "https://weixin.qq.com/")!)
    ]

    func checkEnvironment() async -> RuntimeEnvironmentReport {
        DiagnosticLogStore.shared.append("环境检查", "开始执行完整运行环境检查")
        let operatingSystem = inspectOperatingSystem()
        let downloadsDirectory = inspectDownloadsDirectory()
        let network = await inspectPlatformNetwork()
        var ytDLP = inspectTool(
            id: "yt-dlp",
            name: "yt-dlp",
            purpose: "解析视频页面信息并获取可下载的视频、音频资源",
            candidates: RuntimeToolPaths.ytDLPCandidates(),
            versionArguments: ["--version"],
            versionTimeout: 60
        )
        if ytDLP.installed, let latestVersion = await latestYTDLPVersion() {
            ytDLP.latestVersion = latestVersion
            let currentVersion = normalizedVersion(ytDLP.version)
            ytDLP.updateAvailable = currentVersion.map { $0 != latestVersion } ?? false
            if ytDLP.updateAvailable == true {
                ytDLP.detail += "；可更新至 \(latestVersion)"
            }
        }
        let ffmpeg = inspectFFmpeg()
        let components = [operatingSystem, downloadsDirectory, network, ytDLP, ffmpeg]
        let missingIds = components
            .filter { $0.required && !$0.installed }
            .map(\.id)
        let recommendedIds = components
            .filter { $0.updateAvailable == true }
            .map(\.id)
        let ready = missingIds.isEmpty
        let diagnostics = components.map { component in
            "\(component.name)：\(component.installed ? "通过" : "未通过")；\(component.version ?? component.detail)"
        }
        let message: String
        if !ready {
            message = "检测到运行条件未满足，请根据结果处理"
        } else if !recommendedIds.isEmpty {
            message = "✅当前环境可用，建议更新 yt-dlp 以保持平台兼容性"
        } else {
            message = "✅当前设备环境齐全，功能自检通过"
        }
        DiagnosticLogStore.shared.append("环境检查", message)

        return RuntimeEnvironmentReport(
            ready: ready,
            components: components,
            missingComponentIds: missingIds,
            recommendedComponentIds: recommendedIds,
            message: message,
            managedToolsDirectory: RuntimeToolPaths.managedDirectoryPathIfAvailable() ?? "当前用户的应用支持目录",
            checkedAt: ISO8601DateFormatter().string(from: Date()),
            diagnostics: diagnostics
        )
    }

    func installMissingComponents(
        progress: @escaping (RuntimeEnvironmentProgressEvent) -> Void
    ) async throws -> RuntimeEnvironmentReport {
        let initialReport = await checkEnvironment()
        let unsupported = initialReport.components.filter { $0.required && !$0.installed && !$0.installable }
        if let component = unsupported.first {
            throw UserFacingError("当前设备不满足 \(component.name) 要求，无法自动配置")
        }

        let missing = initialReport.components.filter {
            $0.installable && (!$0.installed || $0.updateAvailable == true)
        }
        guard !missing.isEmpty else {
            progress(RuntimeEnvironmentProgressEvent(progress: 100, message: "环境已经齐全", componentId: nil))
            return initialReport
        }

        let toolsDirectory = try RuntimeToolPaths.managedToolsDirectory()
        do {
            try fileManager.createDirectory(at: toolsDirectory, withIntermediateDirectories: true)
        } catch {
            throw UserFacingError("无法写入应用专用工具目录，请检查当前用户的磁盘权限")
        }
        if let capacity = try? toolsDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage,
           capacity < 200 * 1_024 * 1_024 {
            throw UserFacingError("可用磁盘空间不足，请至少释放 200 MB 后重试")
        }
        progress(RuntimeEnvironmentProgressEvent(progress: 3, message: "正在准备应用专用工具目录", componentId: nil))

        let totalSpan = 90.0 / Double(missing.count)
        for (index, component) in missing.enumerated() {
            let baseProgress = 5.0 + Double(index) * totalSpan
            switch component.id {
            case "yt-dlp":
                let asset = try await latestYTDLPAsset()
                try await installFirstAvailable(
                    assets: [asset],
                    destination: RuntimeToolPaths.managedYTDLPURL(),
                    versionArguments: ["--version"],
                    versionTimeout: 60,
                    componentId: component.id,
                    componentName: component.name,
                    baseProgress: baseProgress,
                    span: totalSpan,
                    progress: progress
                )
            case "ffmpeg":
                let assets = try await ffmpegAssetsForCurrentArchitecture()
                try await installFirstAvailable(
                    assets: assets,
                    destination: RuntimeToolPaths.managedFFmpegURL(),
                    versionArguments: ["-version"],
                    versionTimeout: 15,
                    componentId: component.id,
                    componentName: component.name,
                    baseProgress: baseProgress,
                    span: totalSpan,
                    progress: progress
                )
            default:
                continue
            }
        }

        progress(RuntimeEnvironmentProgressEvent(progress: 97, message: "正在进行最终验证", componentId: nil))
        let finalReport = await checkEnvironment()
        guard finalReport.ready else {
            let missingNames = finalReport.components
                .filter { $0.required && !$0.installed }
                .map(\.name)
                .joined(separator: "、")
            throw UserFacingError("配置完成后验证未通过：\(missingNames)")
        }
        progress(RuntimeEnvironmentProgressEvent(progress: 100, message: "环境配置完成", componentId: nil))
        return finalReport
    }

    private func inspectDownloadsDirectory() -> RuntimeEnvironmentComponent {
        let directory = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        let probe = directory.appendingPathComponent(".ek-streamdl-write-test-\(UUID().uuidString)")
        let writable: Bool
        do {
            try Data("EK StreamDL".utf8).write(to: probe, options: .atomic)
            try fileManager.removeItem(at: probe)
            writable = true
        } catch {
            try? fileManager.removeItem(at: probe)
            writable = false
        }
        return RuntimeEnvironmentComponent(
            id: "downloads",
            name: "下载目录",
            purpose: "验证默认下载位置可写，确保文件能够正常保存",
            required: true,
            installed: writable,
            installable: false,
            version: nil,
            path: directory.path,
            detail: writable ? "默认下载目录写入测试通过" : "默认下载目录不可写，请检查文件权限"
        )
    }

    private func inspectPlatformNetwork() async -> RuntimeEnvironmentComponent {
        let results = await withTaskGroup(of: (String, Bool).self) { group in
            for (name, url) in platformProbeURLs {
                group.addTask {
                    var request = URLRequest(url: url)
                    request.httpMethod = "HEAD"
                    request.timeoutInterval = 8
                    request.setValue("EKStreamDL/0.1", forHTTPHeaderField: "User-Agent")
                    do {
                        let (_, response) = try await URLSession.shared.data(for: request)
                        return (name, response is HTTPURLResponse)
                    } catch {
                        return (name, false)
                    }
                }
            }
            var values: [(String, Bool)] = []
            for await value in group {
                values.append(value)
            }
            return values
        }
        let failed = results.filter { !$0.1 }.map(\.0).sorted()
        let passedCount = results.count - failed.count
        let detail = failed.isEmpty
            ? "六个已支持平台的 DNS/TLS 连通性均正常"
            : "可连接 \(passedCount)/\(results.count)；未通过：\(failed.joined(separator: "、"))"
        return RuntimeEnvironmentComponent(
            id: "network",
            name: "平台网络",
            purpose: "检查解析所需的 DNS、TLS 与已支持平台基础连通性",
            required: true,
            installed: failed.isEmpty,
            installable: false,
            version: "\(passedCount)/\(results.count) 平台可连接",
            path: nil,
            detail: detail
        )
    }

    private func latestYTDLPVersion() async -> String? {
        struct Release: Decodable { var tag_name: String }
        var request = URLRequest(url: ytDLPReleaseURL)
        request.timeoutInterval = 10
        request.setValue("EKStreamDL/0.1", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let release = try? JSONDecoder().decode(Release.self, from: data) else {
            return nil
        }
        return normalizedVersion(release.tag_name)
    }

    private func normalizedVersion(_ value: String?) -> String? {
        guard let value else { return nil }
        let candidate = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^v", with: "", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .first
        return candidate?.isEmpty == false ? candidate : nil
    }

    private func inspectFFmpeg() -> RuntimeEnvironmentComponent {
        var component = inspectTool(
            id: "ffmpeg",
            name: "FFmpeg",
            purpose: "合并音视频、提取音频并完成下载后的媒体处理",
            candidates: RuntimeToolPaths.ffmpegCandidates(),
            versionArguments: ["-version"],
            versionTimeout: 15
        )
        guard component.installed, let path = component.path else {
            return component
        }
        do {
            try verifyFFmpegMediaPipeline(executable: path)
            component.detail += "；H.264/AAC 转码自检通过"
        } catch {
            component.installed = false
            component.detail = "FFmpeg 可启动，但 H.264/AAC 转码自检未通过"
        }
        return component
    }

    private func verifyFFmpegMediaPipeline(executable: String) throws {
        let output = fileManager.temporaryDirectory
            .appendingPathComponent("ek-streamdl-ffmpeg-self-test-\(UUID().uuidString).mp4")
        defer { try? fileManager.removeItem(at: output) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [
            "-y", "-v", "error",
            "-f", "lavfi", "-i", "color=c=black:s=64x64:r=10",
            "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
            "-t", "0.25", "-c:v", "libx264", "-c:a", "aac", "-shortest",
            output.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        if finished.wait(timeout: .now() + 20) == .timedOut {
            process.terminate()
            throw UserFacingError("FFmpeg 转码自检超时")
        }
        let size = ((try? fileManager.attributesOfItem(atPath: output.path)[.size]) as? NSNumber)?.int64Value ?? 0
        guard process.terminationStatus == 0, size > 1_024 else {
            throw UserFacingError("FFmpeg 转码自检失败")
        }
    }

    private func inspectOperatingSystem() -> RuntimeEnvironmentComponent {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let versionText = "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        let supported = ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0)
        )
        return RuntimeEnvironmentComponent(
            id: "macos",
            name: "macOS 13 或更高版本",
            purpose: "提供应用界面、网络访问与本地文件处理能力",
            required: true,
            installed: supported,
            installable: false,
            version: versionText,
            path: nil,
            detail: supported ? "系统版本符合运行要求" : "系统版本过低，需要升级 macOS"
        )
    }

    private func inspectTool(
        id: String,
        name: String,
        purpose: String,
        candidates: [String],
        versionArguments: [String],
        versionTimeout: TimeInterval
    ) -> RuntimeEnvironmentComponent {
        var discoveredInvalidPath: String?
        for candidate in candidates {
            guard fileManager.fileExists(atPath: candidate) else {
                continue
            }
            guard fileManager.isExecutableFile(atPath: candidate) else {
                discoveredInvalidPath = candidate
                continue
            }
            do {
                let version = try runVersion(
                    executable: candidate,
                    arguments: versionArguments,
                    timeout: versionTimeout
                )
                return RuntimeEnvironmentComponent(
                    id: id,
                    name: name,
                    purpose: purpose,
                    required: true,
                    installed: true,
                    installable: true,
                    version: version,
                    path: candidate,
                    detail: toolLocationDescription(path: candidate)
                )
            } catch {
                discoveredInvalidPath = candidate
            }
        }

        return RuntimeEnvironmentComponent(
            id: id,
            name: name,
            purpose: purpose,
            required: true,
            installed: false,
            installable: true,
            version: nil,
            path: discoveredInvalidPath,
            detail: discoveredInvalidPath == nil ? "尚未发现可用组件" : "发现组件文件，但当前无法正常运行"
        )
    }

    private func toolLocationDescription(path: String) -> String {
        if let managedPath = RuntimeToolPaths.managedDirectoryPathIfAvailable(), path.hasPrefix(managedPath) {
            return "应用专用组件已就绪"
        }
        if path.hasPrefix(Bundle.main.bundlePath) {
            return "应用内置组件已就绪"
        }
        return "已复用本设备现有组件"
    }

    private func runVersion(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 3) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                finished.wait()
            }
            throw UserFacingError("组件响应超时")
        }

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw UserFacingError("组件无法运行")
        }
        let text = [output, errorOutput]
            .compactMap { String(data: $0, encoding: .utf8) }
            .joined(separator: "\n")
        let firstLine = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let firstLine else {
            throw UserFacingError("无法读取组件版本")
        }
        return String(firstLine.prefix(160))
    }

    private func latestYTDLPAsset() async throws -> RuntimeDownloadAsset {
        var request = URLRequest(url: ytDLPChecksumsURL)
        request.timeoutInterval = 25
        request.setValue("EKStreamDL/0.1", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTPResponse(response)
        guard let checksums = String(data: data, encoding: .utf8),
              let matchingLine = checksums
                .components(separatedBy: .newlines)
                .first(where: { $0.trimmingCharacters(in: .whitespaces).hasSuffix("yt-dlp_macos") }),
              let digestToken = matchingLine.split(whereSeparator: { $0.isWhitespace }).first,
              let digest = normalizedSHA256(String(digestToken)) else {
            throw UserFacingError("无法取得 yt-dlp 的可信安装信息")
        }
        return RuntimeDownloadAsset(
            url: ytDLPDownloadURL,
            sha256: digest,
            archiveEntryName: nil,
            checksumTarget: .payload
        )
    }

    private func ffmpegAssetsForCurrentArchitecture() async throws -> [RuntimeDownloadAsset] {
        #if arch(arm64)
        let urlString = "https://www.osxexperts.net/ffmpeg81arm.zip"
        let digest = "9a08d61f9328e8164ba560ee7a79958e357307fcfeea6fe626b7d66cdc287028"
        let alternativeAssets = [
            await githubFFmpegLGPLArchiveAsset(),
            await githubStaticFFmpegAsset(named: "ffmpeg-darwin-arm64")
        ].compactMap { $0 }
        #elseif arch(x86_64)
        let urlString = "https://www.osxexperts.net/ffmpeg80intel.zip"
        let digest = "df3f1e3facdc1ae0ad0bd898cdfb072fbc9641bf47b11f172844525a05db8d11"
        let alternativeAssets = [
            await githubStaticFFmpegAsset(named: "ffmpeg-darwin-x64")
        ].compactMap { $0 }
        #else
        throw UserFacingError("当前 Mac 处理器架构暂不支持自动安装 FFmpeg")
        #endif
        guard let url = URL(string: urlString) else {
            throw UserFacingError("FFmpeg 安装地址无效")
        }
        let primary = RuntimeDownloadAsset(
            url: url,
            sha256: digest,
            archiveEntryName: "ffmpeg",
            checksumTarget: .payload
        )
        return alternativeAssets + [primary]
    }

    private func githubFFmpegLGPLArchiveAsset() async -> RuntimeDownloadAsset? {
        struct Release: Decodable {
            struct Asset: Decodable {
                var name: String
                var browser_download_url: URL
            }
            var assets: [Asset]
        }
        guard let releaseURL = URL(string: "https://api.github.com/repos/myndrai/myndr-ffmpeg-lgpl/releases/latest") else {
            return nil
        }
        var request = URLRequest(url: releaseURL)
        request.timeoutInterval = 15
        request.setValue("EKStreamDL/0.1", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let release = try? JSONDecoder().decode(Release.self, from: data),
              let archive = release.assets.first(where: { $0.name.hasSuffix("macos-arm64.zip") }),
              let checksum = release.assets.first(where: { $0.name == "\(archive.name).sha256" }) else {
            return nil
        }
        var checksumRequest = URLRequest(url: checksum.browser_download_url)
        checksumRequest.timeoutInterval = 15
        checksumRequest.setValue("EKStreamDL/0.1", forHTTPHeaderField: "User-Agent")
        guard let (checksumData, checksumResponse) = try? await URLSession.shared.data(for: checksumRequest),
              let checksumHTTP = checksumResponse as? HTTPURLResponse,
              (200...299).contains(checksumHTTP.statusCode),
              let checksumText = String(data: checksumData, encoding: .utf8),
              let digest = normalizedSHA256(checksumText.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)) else {
            return nil
        }
        return RuntimeDownloadAsset(
            url: archive.browser_download_url,
            sha256: digest,
            archiveEntryName: "ffmpeg",
            checksumTarget: .archive
        )
    }

    private func githubStaticFFmpegAsset(named assetName: String) async -> RuntimeDownloadAsset? {
        struct Release: Decodable {
            struct Asset: Decodable {
                var name: String
                var browser_download_url: URL
                var digest: String?
            }
            var assets: [Asset]
        }
        guard let releaseURL = URL(string: "https://api.github.com/repos/eugeneware/ffmpeg-static/releases/latest") else {
            return nil
        }
        var request = URLRequest(url: releaseURL)
        request.timeoutInterval = 15
        request.setValue("EKStreamDL/0.1", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let release = try? JSONDecoder().decode(Release.self, from: data),
              let asset = release.assets.first(where: { $0.name == assetName }),
              let digestValue = asset.digest?.replacingOccurrences(of: "sha256:", with: ""),
              let digest = normalizedSHA256(digestValue) else {
            return nil
        }
        return RuntimeDownloadAsset(
            url: asset.browser_download_url,
            sha256: digest,
            archiveEntryName: nil,
            checksumTarget: .payload
        )
    }

    private func installFirstAvailable(
        assets: [RuntimeDownloadAsset],
        destination: URL,
        versionArguments: [String],
        versionTimeout: TimeInterval,
        componentId: String,
        componentName: String,
        baseProgress: Double,
        span: Double,
        progress: @escaping (RuntimeEnvironmentProgressEvent) -> Void
    ) async throws {
        var lastError: Error?
        for (index, asset) in assets.enumerated() {
            do {
                if index > 0 {
                    progress(RuntimeEnvironmentProgressEvent(
                        progress: Int(baseProgress.rounded()),
                        message: "主下载源不可用，正在切换 \(componentName) 备用源",
                        componentId: componentId
                    ))
                }
                try await install(
                    asset: asset,
                    destination: destination,
                    versionArguments: versionArguments,
                    versionTimeout: versionTimeout,
                    componentId: componentId,
                    componentName: componentName,
                    baseProgress: baseProgress,
                    span: span,
                    progress: progress
                )
                return
            } catch {
                lastError = error
                DiagnosticLogStore.shared.append("环境安装", "\(componentName) 下载源 \(index + 1) 失败：\(error.localizedDescription)")
            }
        }
        throw lastError ?? UserFacingError("无法取得 \(componentName) 安装文件")
    }

    private func install(
        asset: RuntimeDownloadAsset,
        destination: URL,
        versionArguments: [String],
        versionTimeout: TimeInterval,
        componentId: String,
        componentName: String,
        baseProgress: Double,
        span: Double,
        progress: @escaping (RuntimeEnvironmentProgressEvent) -> Void
    ) async throws {
        progress(
            RuntimeEnvironmentProgressEvent(
                progress: Int(baseProgress.rounded()),
                message: "正在下载 \(componentName)",
                componentId: componentId
            )
        )

        var request = URLRequest(url: asset.url)
        request.timeoutInterval = 180
        request.setValue("EKStreamDL/0.1", forHTTPHeaderField: "User-Agent")
        let downloader = RuntimeToolDownloader { ratio in
            let current = baseProgress + span * 0.78 * ratio
            progress(
                RuntimeEnvironmentProgressEvent(
                    progress: min(94, max(1, Int(current.rounded()))),
                    message: "正在下载 \(componentName) · \(Int((ratio * 100).rounded()))%",
                    componentId: componentId
                )
            )
        }

        let temporaryURL: URL
        do {
            temporaryURL = try await downloader.download(request: request)
        } catch {
            throw networkInstallError(componentName: componentName, error: error)
        }
        defer { try? fileManager.removeItem(at: temporaryURL) }

        if asset.checksumTarget == .archive {
            progress(
                RuntimeEnvironmentProgressEvent(
                    progress: Int((baseProgress + span * 0.79).rounded()),
                    message: "正在校验 \(componentName) 压缩包",
                    componentId: componentId
                )
            )
            let archiveDigest = try sha256(of: temporaryURL)
            guard archiveDigest.caseInsensitiveCompare(asset.sha256) == .orderedSame else {
                throw UserFacingError("\(componentName) 安装文件校验失败，已停止配置")
            }
        }

        let payloadURL: URL
        if let archiveEntryName = asset.archiveEntryName {
            progress(
                RuntimeEnvironmentProgressEvent(
                    progress: Int((baseProgress + span * 0.80).rounded()),
                    message: "正在解压 \(componentName) 安装文件",
                    componentId: componentId
                )
            )
            payloadURL = try extractZipEntry(named: archiveEntryName, from: temporaryURL)
        } else {
            payloadURL = temporaryURL
        }
        defer {
            if payloadURL != temporaryURL {
                try? fileManager.removeItem(at: payloadURL)
            }
        }

        progress(
            RuntimeEnvironmentProgressEvent(
                progress: Int((baseProgress + span * 0.82).rounded()),
                message: "正在校验 \(componentName) 安装文件",
                componentId: componentId
            )
        )
        if asset.checksumTarget == .payload {
            let actualDigest = try sha256(of: payloadURL)
            guard actualDigest.caseInsensitiveCompare(asset.sha256) == .orderedSame else {
                throw UserFacingError("\(componentName) 安装文件校验失败，已停止配置")
            }
        }

        let stagingURL = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).installing")
        defer { try? fileManager.removeItem(at: stagingURL) }
        try fileManager.moveItem(at: payloadURL, to: stagingURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagingURL.path)
        clearQuarantine(at: stagingURL)

        progress(
            RuntimeEnvironmentProgressEvent(
                progress: Int((baseProgress + span * 0.92).rounded()),
                message: "正在验证 \(componentName) 可用性",
                componentId: componentId
            )
        )
        _ = try runVersion(
            executable: stagingURL.path,
            arguments: versionArguments,
            timeout: versionTimeout
        )

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: stagingURL, to: destination)
        progress(
            RuntimeEnvironmentProgressEvent(
                progress: Int((baseProgress + span).rounded()),
                message: "\(componentName) 已配置完成",
                componentId: componentId
            )
        )
    }

    private func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func extractZipEntry(named entryName: String, from archiveURL: URL) throws -> URL {
        let extractedURL = fileManager.temporaryDirectory
            .appendingPathComponent("ek-streamdl-runtime-extracted-\(UUID().uuidString)")
        guard fileManager.createFile(atPath: extractedURL.path, contents: nil) else {
            throw UserFacingError("无法准备 FFmpeg 解压文件")
        }

        do {
            let outputHandle = try FileHandle(forWritingTo: extractedURL)
            defer { try? outputHandle.close() }
            let errorPipe = Pipe()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-p", archiveURL.path, entryName]
            process.standardOutput = outputHandle
            process.standardError = errorPipe

            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            try process.run()
            if finished.wait(timeout: .now() + 60) == .timedOut {
                process.terminate()
                if finished.wait(timeout: .now() + 3) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    finished.wait()
                }
                throw UserFacingError("FFmpeg 安装文件解压超时")
            }
            guard process.terminationStatus == 0 else {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorText = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let errorText, !errorText.isEmpty {
                    throw UserFacingError("FFmpeg 解压失败：\(errorText)")
                }
                throw UserFacingError("FFmpeg 安装文件解压失败")
            }
            let attributes = try fileManager.attributesOfItem(atPath: extractedURL.path)
            let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard fileSize > 0 else {
                throw UserFacingError("FFmpeg 安装文件内容为空")
            }
            return extractedURL
        } catch {
            try? fileManager.removeItem(at: extractedURL)
            throw error
        }
    }

    private func clearQuarantine(at fileURL: URL) {
        fileURL.path.withCString { path in
            "com.apple.quarantine".withCString { attribute in
                _ = removexattr(path, attribute, 0)
            }
        }
    }

    private func validateHTTPResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw UserFacingError("安装信息请求失败，请检查网络后重试")
        }
    }

    private func normalizedSHA256(_ digest: String?) -> String? {
        guard let digest else { return nil }
        let normalized = digest.lowercased().replacingOccurrences(of: "sha256:", with: "")
        guard normalized.count == 64, normalized.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        return normalized
    }

    private func networkInstallError(componentName: String, error: Error) -> UserFacingError {
        if let userFacing = error as? UserFacingError {
            return userFacing
        }
        if let urlError = error as? URLError {
            if urlError.code == .timedOut {
                return UserFacingError("下载 \(componentName) 超时，请检查网络后重试")
            }
            return UserFacingError("无法下载 \(componentName)，请检查网络连接后重试")
        }
        return UserFacingError("\(componentName) 配置失败：\(error.localizedDescription)")
    }
}

private struct RuntimeDownloadAsset {
    var url: URL
    var sha256: String
    var archiveEntryName: String?
    var checksumTarget: RuntimeChecksumTarget
}

private enum RuntimeChecksumTarget {
    case archive
    case payload
}

private final class RuntimeToolDownloader: NSObject, URLSessionDownloadDelegate {
    private let progressHandler: (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var downloadedURL: URL?
    private var completionError: Error?
    private var resumeData: Data?

    init(progressHandler: @escaping (Double) -> Void) {
        self.progressHandler = progressHandler
    }

    func download(request: URLRequest) async throws -> URL {
        var lastError: Error?
        for attempt in 1...3 {
            downloadedURL = nil
            completionError = nil
            do {
                return try await downloadAttempt(request: request)
            } catch {
                lastError = error
                guard attempt < 3 else { break }
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
            }
        }
        throw lastError ?? UserFacingError("安装文件下载失败")
    }

    private func downloadAttempt(request: URLRequest) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 180
            configuration.timeoutIntervalForResource = 300
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            if let resumeData {
                session.downloadTask(withResumeData: resumeData).resume()
            } else {
                session.downloadTask(with: request).resume()
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let ratio = min(1, max(0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        progressHandler(ratio)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let response = downloadTask.response as? HTTPURLResponse,
              (200...299).contains(response.statusCode) else {
            completionError = UserFacingError("下载服务器返回异常状态")
            return
        }
        let retainedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ek-streamdl-runtime-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: retainedURL)
            downloadedURL = retainedURL
        } catch {
            completionError = error
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error = error as NSError?,
           let data = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
           !data.isEmpty {
            resumeData = data
        }
        let result: Result<URL, Error>
        if let error {
            result = .failure(error)
        } else if let completionError {
            result = .failure(completionError)
        } else if let downloadedURL {
            result = .success(downloadedURL)
        } else {
            result = .failure(UserFacingError("安装文件下载不完整"))
        }
        continuation?.resume(with: result)
        continuation = nil
        self.session?.finishTasksAndInvalidate()
        self.session = nil
        if case .success = result {
            resumeData = nil
        }
    }
}
