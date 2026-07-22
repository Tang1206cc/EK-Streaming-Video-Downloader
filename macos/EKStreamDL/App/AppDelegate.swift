import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settingsWindow: NSWindow?
    private var escMonitor: Any?
    private var defaultsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.registerDefaults()
        AppSettings.applyApplicationAppearance()
        AppSettings.applyApplicationLanguage()

        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 && UserDefaults.standard.bool(forKey: AppSettings.escToQuitKey) {
                NSApp.terminate(nil)
                return nil
            }
            return event
        }

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                AppSettings.applyApplicationAppearance()
                self?.settingsWindow?.title = AppText.text("偏好设置", "偏好設定", "Preferences")
            }
        }

        try? AppSettings.applyLaunchAtLogin(UserDefaults.standard.bool(forKey: AppSettings.launchAtLoginKey))

        if AppSettings.shouldAutoCheckForUpdates {
            UpdateManager.shared.checkForUpdate(interactive: false)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
        }
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        AppSettings.shouldQuitWhenLastWindowClosed
    }

    @objc func showPreferencesWindow(_ sender: Any?) {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = AppText.text("偏好设置", "偏好設定", "Preferences")
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentMinSize = NSSize(width: 520, height: 400)
        window.contentMaxSize = NSSize(width: 520, height: 400)
        window.contentView = NSHostingView(rootView: SettingsView())
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        settingsWindow = window
    }
}
