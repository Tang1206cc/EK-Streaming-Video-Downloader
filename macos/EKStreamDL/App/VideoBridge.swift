import Foundation
import AppKit
import UniformTypeIdentifiers
import WebKit

final class VideoBridge: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    private let service = YTDLPService()
    private let environmentService = RuntimeEnvironmentService()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let completionSound = NSSound(named: NSSound.Name("Tink"))

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let id = body["id"] as? String,
              let action = body["action"] as? String,
              let payload = body["payload"] as? [String: Any] else {
            return
        }

        Task {
            do {
                switch action {
                case "openPreferences":
                    _ = await MainActor.run {
                        NSApp.sendAction(
                            #selector(AppDelegate.showPreferencesWindow(_:)),
                            to: nil,
                            from: nil
                        )
                    }
                    try await MainActor.run {
                        try resolve(id: id, value: ["opened": true])
                    }
                case "openToolWindow":
                    let toolId = payload["toolId"] as? String ?? ""
                    guard toolId == WebAppRoute.videoDownloader.rawValue else {
                        throw UserFacingError("未知工具")
                    }
                    await MainActor.run {
                        ToolWindowManager.shared.openVideoDownloader()
                    }
                    try await MainActor.run {
                        try resolve(id: id, value: ["opened": true])
                    }
                case "parseVideo":
                    let inputText = payload["inputText"] as? String ?? ""
                    DiagnosticLogStore.shared.append("解析", "开始识别视频链接")
                    let metadata = try await service.parse(inputText: inputText)
                    DiagnosticLogStore.shared.append("解析", "\(metadata.platformName) 解析成功：\(metadata.title)")
                    try await MainActor.run {
                        try resolve(id: id, value: metadata)
                    }
                case "downloadVideo":
                    let metadata = try decodePayload(VideoMetadata.self, from: payload["metadata"])
                    let downloadDirectoryPath = payload["downloadDirectoryPath"] as? String
                    let downloadMode = DownloadMode(rawValue: payload["downloadMode"] as? String ?? "") ?? .complete
                    let taskIdentifier = payload["taskIdentifier"] as? String ?? id
                    DiagnosticLogStore.shared.append("下载", "开始下载 \(metadata.platformName) 内容，模式：\(downloadMode.rawValue)")
                    let savedPath = try await service.download(
                        metadata: metadata,
                        downloadDirectoryPath: downloadDirectoryPath,
                        mode: downloadMode,
                        taskIdentifier: taskIdentifier
                    ) { [weak self] event in
                        Task { @MainActor in
                            try? self?.emitProgress(id: id, event: event)
                        }
                    }
                    DiagnosticLogStore.shared.append("下载", "媒体校验通过，已保存：\(savedPath)")
                    try await MainActor.run {
                        try resolve(id: id, value: ["savedPath": savedPath])
                    }
                case "cancelDownload":
                    let taskIdentifier = payload["taskIdentifier"] as? String ?? ""
                    guard !taskIdentifier.isEmpty else {
                        throw UserFacingError("任务标识无效")
                    }
                    let deletePartialFiles = payload["deletePartialFiles"] as? Bool ?? true
                    await service.cancelDownload(
                        taskIdentifier: taskIdentifier,
                        deletePartialFiles: deletePartialFiles
                    )
                    DiagnosticLogStore.shared.append(
                        "下载",
                        deletePartialFiles ? "任务已取消，临时文件已清理" : "任务已取消，临时文件已保留"
                    )
                    try await MainActor.run {
                        try resolve(id: id, value: ["cancelled": true])
                    }
                case "pauseDownload":
                    let taskIdentifier = payload["taskIdentifier"] as? String ?? ""
                    try service.pauseDownload(taskIdentifier: taskIdentifier)
                    try await MainActor.run {
                        try resolve(id: id, value: ["paused": true])
                    }
                case "resumeDownload":
                    let taskIdentifier = payload["taskIdentifier"] as? String ?? ""
                    try service.resumeDownload(taskIdentifier: taskIdentifier)
                    try await MainActor.run {
                        try resolve(id: id, value: ["resumed": true])
                    }
                case "downloadCover":
                    let metadata = try decodePayload(VideoMetadata.self, from: payload["metadata"])
                    let downloadDirectoryPath = payload["downloadDirectoryPath"] as? String
                    let savedPath = try await service.downloadCover(
                        metadata: metadata,
                        downloadDirectoryPath: downloadDirectoryPath
                    )
                    try await MainActor.run {
                        try resolve(id: id, value: ["savedPath": savedPath])
                    }
                case "playCompletionSound":
                    await MainActor.run {
                        playCompletionSound()
                    }
                    try await MainActor.run {
                        try resolve(id: id, value: ["played": true])
                    }
                case "checkRuntimeEnvironment":
                    let report = await environmentService.checkEnvironment()
                    try await MainActor.run {
                        try resolve(id: id, value: report)
                    }
                case "installRuntimeEnvironment":
                    let report = try await environmentService.installMissingComponents { [weak self] event in
                        Task { @MainActor in
                            try? self?.emitProgress(id: id, event: event)
                        }
                    }
                    try await MainActor.run {
                        try resolve(id: id, value: report)
                    }
                case "getWeChatAuthorizationStatus":
                    let authorized = await WeChatChannelsAuthorization.shared.currentAuthorizationStatus()
                    try await MainActor.run {
                        try resolve(id: id, value: ["authorized": authorized])
                    }
                case "clearWeChatAuthorization":
                    await WeChatChannelsAuthorization.shared.clearAuthorization()
                    DiagnosticLogStore.shared.append("微信视频号", "用户主动清理当前授权")
                    try await MainActor.run {
                        try resolve(id: id, value: ["cleared": true])
                    }
                case "exportDiagnosticReport":
                    let savedPath = await MainActor.run {
                        exportDiagnosticReport(environmentReport: payload["report"])
                    }
                    try await MainActor.run {
                        try resolve(id: id, value: ["savedPath": savedPath ?? ""])
                    }
                case "selectDownloadDirectory":
                    let directoryPath = await MainActor.run {
                        selectDownloadDirectory()
                    }
                    try await MainActor.run {
                        try resolve(id: id, value: ["directoryPath": directoryPath ?? ""])
                    }
                default:
                    throw UserFacingError("未知操作")
                }
            } catch {
                DiagnosticLogStore.shared.append(action, "失败：(userMessage(from: error))")
                await MainActor.run {
                    reject(id: id, message: userMessage(from: error))
                }
            }
        }
    }

    private func decodePayload<T: Decodable>(_ type: T.Type, from payload: Any?) throws -> T {
        guard let payload else {
            throw UserFacingError("请求数据不完整")
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try decoder.decode(type, from: data)
    }

    @MainActor
    private func playCompletionSound() {
        if let completionSound {
            completionSound.stop()
            completionSound.currentTime = 0
            if completionSound.play() {
                return
            }
        }
        NSSound.beep()
    }

    @MainActor
    private func resolve<T: Encodable>(id: String, value: T) throws {
        let data = try encoder.encode(value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw UserFacingError("响应数据编码失败")
        }
        webView?.evaluateJavaScript("window.__ekStreamDLNativeResolve(\(jsString(id)), \(json));")
    }

    @MainActor
    private func reject(id: String, message: String) {
        webView?.evaluateJavaScript("window.__ekStreamDLNativeReject(\(jsString(id)), \(jsString(message)));")
    }

    @MainActor
    private func emitProgress<T: Encodable>(id: String, event: T) throws {
        let data = try encoder.encode(event)
        guard let json = String(data: data, encoding: .utf8) else {
            return
        }
        webView?.evaluateJavaScript("window.__ekStreamDLNativeProgress(\(jsString(id)), \(json));")
    }

    private func jsString(_ value: String) -> String {
        let data = try? encoder.encode(value)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    private func userMessage(from error: Error) -> String {
        if let localized = error as? LocalizedError,
           let message = localized.errorDescription {
            return message
        }
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "操作失败" : message
    }

    @MainActor
    private func selectDownloadDirectory() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = "选择视频下载保存目录"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    @MainActor
    private func exportDiagnosticReport(environmentReport: Any?) -> String? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "EK StreamDL诊断报告.txt"
        panel.prompt = "导出"
        panel.message = "导出运行环境与最近操作诊断信息"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }

        let process = ProcessInfo.processInfo
        var sections = [
            "EK StreamDL诊断报告",
            "生成时间：\(ISO8601DateFormatter().string(from: Date()))",
            "应用版本：\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.8.0")",
            "系统：\(process.operatingSystemVersionString)",
            "处理器：\(systemArchitecture())"
        ]
        if let environmentReport,
           JSONSerialization.isValidJSONObject(environmentReport),
           let data = try? JSONSerialization.data(withJSONObject: environmentReport, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            sections.append("\n--- 环境检查 ---\n\(text)")
        }
        let logs = DiagnosticLogStore.shared.text()
        sections.append("\n--- 最近诊断记录 ---\n\(logs.isEmpty ? "暂无记录" : logs)")
        do {
            try sections.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url.path
        } catch {
            return nil
        }
    }

    private func systemArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
