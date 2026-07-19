import AppKit
import Foundation

func appendLog(_ message: String, to file: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }

    if FileManager.default.fileExists(atPath: file),
       let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: file)) {
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
        }
    } else {
        try? data.write(to: URL(fileURLWithPath: file), options: .atomic)
    }
}

func waitUntilAppQuits(bundleID: String, timeout: TimeInterval = 60) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
            return true
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
    return false
}

func readPlan() throws -> InstallPlan {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--plan"), index + 1 < arguments.count else {
        throw HelperError.invalidPlan
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: arguments[index + 1]))
    return try JSONDecoder().decode(InstallPlan.self, from: data)
}

var currentLogFile: String?

do {
    let plan = try readPlan()
    currentLogFile = plan.logFile
    appendLog("UpdaterHelper started.", to: plan.logFile)
    appendLog("New app: \(plan.newAppPath)", to: plan.logFile)
    appendLog("Target app: \(plan.targetAppPath)", to: plan.logFile)

    if !plan.relaunchBundleID.isEmpty {
        appendLog("Waiting for the running app to quit.", to: plan.logFile)
        guard waitUntilAppQuits(bundleID: plan.relaunchBundleID) else {
            throw HelperError.appDidNotQuit
        }
    }

    let backupPath = try installAppUsingRecoverableMove(plan: plan)
    if let backupPath {
        appendLog("Previous version moved to recoverable backup: \(backupPath)", to: plan.logFile)
    } else {
        appendLog("No previous version was installed at the target path.", to: plan.logFile)
    }
    appendLog("New version installed.", to: plan.logFile)

    if plan.removeQuarantine {
        removeQuarantineIfNeeded(plan.targetAppPath)
        appendLog("Quarantine attributes processed.", to: plan.logFile)
    }

    if !plan.relaunchBundleID.isEmpty {
        relaunch(appPath: plan.targetAppPath, bundleID: plan.relaunchBundleID)
        appendLog("Relaunch requested.", to: plan.logFile)
    }

    appendLog("UpdaterHelper finished successfully.", to: plan.logFile)
    exit(0)
} catch {
    let message = "UpdaterHelper failed: \(error.localizedDescription)"
    if let currentLogFile {
        appendLog(message, to: currentLogFile)
    }
    fputs(message + "\n", stderr)
    exit(1)
}
