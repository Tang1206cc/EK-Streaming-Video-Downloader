import Foundation

struct InstallPlan: Codable {
    let newAppPath: String
    let targetAppPath: String
    let backupDir: String
    let removeQuarantine: Bool
    let relaunchBundleID: String
    let logFile: String
}

enum HelperError: LocalizedError {
    case invalidPlan
    case newAppMissing
    case appDidNotQuit
    case restoreFailed

    var errorDescription: String? {
        switch self {
        case .invalidPlan: return "更新计划无效"
        case .newAppMissing: return "待安装的新版本不存在"
        case .appDidNotQuit: return "主应用未能在规定时间内退出，已取消更新"
        case .restoreFailed: return "更新失败，且无法自动恢复旧版本"
        }
    }
}
