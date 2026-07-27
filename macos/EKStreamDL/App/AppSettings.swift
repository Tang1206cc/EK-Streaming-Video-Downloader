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
    case japanese = "ja"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .english: return "English"
        case .japanese: return "日本語"
        }
    }
}

private enum JapaneseText {
    private static let values: [String: String] = [
        "跟随系统": "システム",
        "浅色": "ライト",
        "深色": "ダーク",
        "当前版本：—": "現在のバージョン：—",
        "偏好设置": "環境設定",
        "偏好设置…": "環境設定…",
        "开机自启动": "ログイン時に起動",
        "无法修改开机自启动：": "ログイン時の起動設定を変更できません：",
        "⚠️ 可能仅在 macOS 13 及以上系统生效": "⚠️ macOS 13 以降でのみ有効になる場合があります",
        "主题模式": "外観",
        "按 Esc 键退出 EK StreamDL": "Esc キーで EK StreamDL を終了",
        "关闭最后一个窗口时退出 EK StreamDL": "最後のウィンドウを閉じたときに EK StreamDL を終了",
        "语言": "言語",
        "恢复默认设置": "デフォルトに戻す",
        "恢复默认设置失败：": "デフォルトに戻せません：",
        "自动检查更新": "アップデートを自動確認",
        "检查更新": "アップデートを確認",
        "微信视频号授权 · 腾讯元宝": "WeChat Channels 認証 · Tencent Yuanbao",
        "未找到前端资源，请先执行 pnpm run build。": "フロントエンドリソースが見つかりません。先に pnpm run build を実行してください。",
        "选择": "選択",
        "选择视频下载保存目录": "動画の保存先を選択",
        "EK StreamDL诊断报告.txt": "EK StreamDL診断レポート.txt",
        "导出": "書き出す",
        "导出运行环境与最近操作诊断信息": "実行環境と最近の操作に関する診断情報を書き出します",
        "解压更新包失败": "アップデートを展開できません",
        "即将安装更新": "アップデートをインストールします",
        "应用将退出，并把新版本安装到“应用程序”文件夹后重新启动。": "アプリを終了し、新しいバージョンを「アプリケーション」フォルダにインストールして再起動します。",
        "继续": "続ける",
        "取消": "キャンセル",
        "未找到更新助手，请重新下载安装完整版本": "アップデートヘルパーが見つかりません。完全版をダウンロードして再インストールしてください。",
        "无法启动更新助手": "アップデートヘルパーを起動できません",
        "提示": "お知らせ",
        "当前已是最新版本！": "現在のバージョンは最新です。",
        "好": "OK",
        "检查结果": "確認結果",
        "检查失败": "確認できませんでした",
        "立即更新": "今すぐアップデート",
        "下次再说": "後で",
        "此版本暂无推版描述。": "このバージョンのリリースノートはありません。",
        "GitHub 推版描述": "GitHub リリースノート",
        "下载失败": "ダウンロードに失敗しました",
        "未在压缩包中找到 EK StreamDL.app": "アーカイブ内に EK StreamDL.app が見つかりません",
        "安装失败": "インストールに失敗しました",
        "更新包中的应用身份与 EK StreamDL 不匹配": "アップデート内のアプリ識別情報が EK StreamDL と一致しません",
        "更新包版本与 GitHub Release 标签不一致": "アップデートのバージョンが GitHub Release タグと一致しません",
        "下载进度：0%": "ダウンロード進捗：0%",
        "剩余时间：—": "残り時間：—",
        "正在下载更新": "アップデートをダウンロード中",
        "下载进度：%.0f%%": "ダウンロード進捗：%.0f%%",
        "剩余时间：": "残り時間：",
        "GitHub 仓库尚未发布可用版本": "GitHub リポジトリに利用可能なリリースがありません",
        "GitHub API 返回异常": "GitHub API から予期しない応答が返されました",
        "无法解析 GitHub Releases 信息": "GitHub Releases の情報を解析できません",
        "未找到符合 EK StreamDL 命名规范的 macOS 更新包": "EK StreamDL の命名規則に合う macOS アップデートが見つかりません",
    ]

    static func text(_ simplifiedChinese: String, fallback: String) -> String {
        if let value = values[simplifiedChinese] {
            return value
        }
        if simplifiedChinese.hasPrefix("当前版本：v") {
            return simplifiedChinese.replacingOccurrences(of: "当前版本：", with: "現在のバージョン：")
        }
        if simplifiedChinese.hasSuffix(" 有新版本可用") {
            return simplifiedChinese.replacingOccurrences(of: " 有新版本可用", with: " の新しいバージョンを利用できます")
        }
        if simplifiedChinese.hasPrefix("版本：") {
            return simplifiedChinese
                .replacingOccurrences(of: "版本：", with: "バージョン：")
                .replacingOccurrences(of: "可立即下载并安装更新。", with: "アップデートを今すぐダウンロードしてインストールできます。")
        }
        return fallback
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
        case .japanese: return JapaneseText.text(simplifiedChinese, fallback: english)
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
