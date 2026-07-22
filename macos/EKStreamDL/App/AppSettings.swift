import AppKit
import Foundation
import ServiceManagement

enum ThemeMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    func displayName(language: AppLanguage) -> String {
        switch self {
        case .system: return AppText.text("跟随系统", "跟隨系統", "System", language: language)
        case .light: return AppText.text("浅色", "淺色", "Light", language: language)
        case .dark: return AppText.text("深色", "深色", "Dark", language: language)
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .english: return "English"
        }
    }
}

enum AppText {
    static func text(
        _ simplifiedChinese: String,
        _ traditionalChinese: String,
        _ english: String,
        language: AppLanguage = AppSettings.language
    ) -> String {
        switch language {
        case .simplifiedChinese: return simplifiedChinese
        case .traditionalChinese: return traditionalChinese
        case .english: return english
        }
    }
}

enum AppSettings {
    static let applicationAppearanceDidChangeNotification = Notification.Name(
        "EKStreamDLApplicationAppearanceDidChange"
    )
    static let applicationLanguageDidChangeNotification = Notification.Name(
        "EKStreamDLApplicationLanguageDidChange"
    )

    static let launchAtLoginKey = "launchAtLogin"
    static let themeModeKey = "themeMode"
    static let escToQuitKey = "escToQuit"
    static let quitWhenLastWindowClosedKey = "quitWhenLastWindowClosed"
    static let autoCheckForUpdatesKey = "autoCheckForUpdates"
    static let languageKey = "appLanguage"

    static let launchAtLoginDefault = false
    static let themeModeDefault = ThemeMode.system.rawValue
    static let escToQuitDefault = false
    static let quitWhenLastWindowClosedDefault = true
    static let autoCheckForUpdatesDefault = true
    static let languageDefault = AppLanguage.simplifiedChinese.rawValue

    static var themeMode: ThemeMode {
        ThemeMode(rawValue: UserDefaults.standard.string(forKey: themeModeKey) ?? themeModeDefault) ?? .system
    }

    static var language: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: languageKey) ?? languageDefault)
            ?? .simplifiedChinese
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
            languageKey: languageDefault,
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

    @MainActor
    static func applyApplicationLanguage(_ language: AppLanguage? = nil) {
        NotificationCenter.default.post(
            name: applicationLanguageDidChangeNotification,
            object: language ?? self.language
        )
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
