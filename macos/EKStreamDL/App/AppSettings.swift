import AppKit
import Foundation
import ServiceManagement

enum ThemeMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
}

enum AppSettings {
    static let applicationAppearanceDidChangeNotification = Notification.Name(
        "EKStreamDLApplicationAppearanceDidChange"
    )

    static let launchAtLoginKey = "launchAtLogin"
    static let themeModeKey = "themeMode"
    static let escToQuitKey = "escToQuit"
    static let quitWhenLastWindowClosedKey = "quitWhenLastWindowClosed"
    static let autoCheckForUpdatesKey = "autoCheckForUpdates"

    static let launchAtLoginDefault = false
    static let themeModeDefault = ThemeMode.system.rawValue
    static let escToQuitDefault = false
    static let quitWhenLastWindowClosedDefault = true
    static let autoCheckForUpdatesDefault = true

    static var themeMode: ThemeMode {
        ThemeMode(rawValue: UserDefaults.standard.string(forKey: themeModeKey) ?? themeModeDefault) ?? .system
    }

    static var shouldQuitWhenLastWindowClosed: Bool {
        UserDefaults.standard.object(forKey: quitWhenLastWindowClosedKey) as? Bool
            ?? quitWhenLastWindowClosedDefault
    }

    static var shouldAutoCheckForUpdates: Bool {
        UserDefaults.standard.object(forKey: autoCheckForUpdatesKey) as? Bool
            ?? autoCheckForUpdatesDefault
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            launchAtLoginKey: launchAtLoginDefault,
            themeModeKey: themeModeDefault,
            escToQuitKey: escToQuitDefault,
            quitWhenLastWindowClosedKey: quitWhenLastWindowClosedDefault,
            autoCheckForUpdatesKey: autoCheckForUpdatesDefault,
        ])
    }

    static func applyLaunchAtLogin(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            switch service.status {
            case .enabled, .requiresApproval:
                return
            case .notRegistered, .notFound:
                try service.register()
            @unknown default:
                return
            }
        } else {
            switch service.status {
            case .enabled, .requiresApproval:
                try service.unregister()
            case .notRegistered, .notFound:
                return
            @unknown default:
                return
            }
        }
    }

    @MainActor
    static func applyApplicationAppearance(_ mode: ThemeMode? = nil) {
        switch mode ?? themeMode {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        NotificationCenter.default.post(name: applicationAppearanceDidChangeNotification, object: nil)
    }

    static func reset() throws {
        try applyLaunchAtLogin(false)

        let defaults = UserDefaults.standard
        [
            launchAtLoginKey,
            themeModeKey,
            escToQuitKey,
            quitWhenLastWindowClosedKey,
            autoCheckForUpdatesKey,
        ].forEach { defaults.removeObject(forKey: $0) }
    }
}
