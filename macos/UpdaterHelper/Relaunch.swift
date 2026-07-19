import Foundation

func relaunch(appPath: String, bundleID: String) {
    let openByPath = Process()
    openByPath.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    openByPath.arguments = [appPath]

    do {
        try openByPath.run()
        openByPath.waitUntilExit()
        if openByPath.terminationStatus == 0 {
            return
        }
    } catch {}

    let openByBundleIdentifier = Process()
    openByBundleIdentifier.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    openByBundleIdentifier.arguments = ["-b", bundleID]
    try? openByBundleIdentifier.run()
}
