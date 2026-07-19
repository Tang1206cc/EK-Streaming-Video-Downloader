import AppKit
import Foundation

enum Installer {
    private static let appName = "EK StreamDL.app"
    private static let targetDirectory = URL(fileURLWithPath: "/Applications", isDirectory: true)

    private static var targetAppURL: URL {
        targetDirectory.appendingPathComponent(appName)
    }

    static func unzip(_ zipURL: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "Installer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "解压更新包失败"]
            )
        }
    }

    static func installAndRelaunch(newAppURL: URL) throws {
        let alert = NSAlert()
        alert.messageText = "即将安装更新"
        alert.informativeText = "应用将退出，并把新版本安装到“应用程序”文件夹后重新启动。"
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "取消")
        guard alert.runModalWithSystemStyle() == .alertFirstButtonReturn else { return }

        let helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/UpdaterHelper")
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw NSError(
                domain: "Installer",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "未找到更新助手，请重新下载安装完整版本"]
            )
        }

        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let identifier = UUID().uuidString
        let detachedHelperURL = temporaryDirectory.appendingPathComponent("EKStreamDL-UpdaterHelper-\(identifier)")
        let planURL = temporaryDirectory.appendingPathComponent("EKStreamDL-InstallPlan-\(identifier).json")
        let backupDirectory = temporaryDirectory.appendingPathComponent("EKStreamDLBackups", isDirectory: true)
        let logFileURL = temporaryDirectory.appendingPathComponent("EKStreamDLUpdater.log")

        let plan = InstallPlan(
            newAppPath: newAppURL.path,
            targetAppPath: targetAppURL.path,
            backupDir: backupDirectory.path,
            removeQuarantine: true,
            relaunchBundleID: Bundle.main.bundleIdentifier ?? "com.tang1206cc.ekstreamdl",
            logFile: logFileURL.path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        try encoder.encode(plan).write(to: planURL, options: .atomic)

        try FileManager.default.copyItem(at: helperURL, to: detachedHelperURL)
        guard FileManager.default.isExecutableFile(atPath: detachedHelperURL.path) else {
            throw NSError(
                domain: "Installer",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "无法启动更新助手"]
            )
        }

        let launchLog = "[\(ISO8601DateFormatter().string(from: Date()))] Launching detached helper: \(detachedHelperURL.path)\n"
        try launchLog.data(using: .utf8)?.write(to: logFileURL, options: .atomic)
        let logHandle = try FileHandle(forWritingTo: logFileURL)
        try logHandle.seekToEnd()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        process.arguments = [detachedHelperURL.path, "--plan", planURL.path]
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        try? logHandle.close()

        NSApp.terminate(nil)
    }
}

private struct InstallPlan: Codable {
    let newAppPath: String
    let targetAppPath: String
    let backupDir: String
    let removeQuarantine: Bool
    let relaunchBundleID: String
    let logFile: String
}
