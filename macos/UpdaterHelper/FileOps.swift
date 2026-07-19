import Foundation

@discardableResult
func runProcess(_ executablePath: String, arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    } catch {
        return -1
    }
}

func ensureDirectory(_ path: String) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

func installAppUsingRecoverableMove(plan: InstallPlan) throws -> String? {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: plan.newAppPath) else {
        throw HelperError.newAppMissing
    }

    try ensureDirectory(plan.backupDir)
    let backupPath = (plan.backupDir as NSString)
        .appendingPathComponent("EKStreamDL-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).app")

    var didMoveExistingApp = false
    if fileManager.fileExists(atPath: plan.targetAppPath) {
        try fileManager.moveItem(atPath: plan.targetAppPath, toPath: backupPath)
        didMoveExistingApp = true
    }

    do {
        try fileManager.moveItem(atPath: plan.newAppPath, toPath: plan.targetAppPath)
    } catch {
        if didMoveExistingApp {
            do {
                try fileManager.moveItem(atPath: backupPath, toPath: plan.targetAppPath)
            } catch {
                throw HelperError.restoreFailed
            }
        }
        throw error
    }

    return didMoveExistingApp ? backupPath : nil
}

func removeQuarantineIfNeeded(_ path: String) {
    _ = runProcess("/usr/bin/xattr", arguments: ["-dr", "com.apple.quarantine", path])
}
