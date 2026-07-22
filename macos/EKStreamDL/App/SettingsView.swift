import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.launchAtLoginKey) private var launchAtLogin = AppSettings.launchAtLoginDefault
    @AppStorage(AppSettings.themeModeKey) private var themeMode = AppSettings.themeModeDefault
    @AppStorage(AppSettings.escToQuitKey) private var escToQuit = AppSettings.escToQuitDefault
    @AppStorage(AppSettings.quitWhenLastWindowClosedKey) private var quitWhenLastWindowClosed = AppSettings.quitWhenLastWindowClosedDefault
    @AppStorage(AppSettings.autoCheckForUpdatesKey) private var autoCheckForUpdates = AppSettings.autoCheckForUpdatesDefault
    @AppStorage(AppSettings.languageKey) private var language = AppSettings.languageDefault

    @State private var launchAtLoginError = ""
    @State private var resetError = ""
    @State private var isRevertingLaunchAtLogin = false

    private var currentVersionText: String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !version.isEmpty {
            return AppText.text("当前版本：v\(version)", "目前版本：v\(version)", "Current version: v\(version)", language: selectedLanguage)
        }
        return AppText.text("当前版本：—", "目前版本：—", "Current version: —", language: selectedLanguage)
    }

    private var selectedLanguage: AppLanguage {
        AppLanguage(rawValue: language) ?? .simplifiedChinese
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(AppText.text("偏好设置", "偏好設定", "Preferences", language: selectedLanguage))
                .font(.title2)
                .bold()
            Divider()

            Toggle(AppText.text("开机自启动", "開機時自動啟動", "Launch at Login", language: selectedLanguage), isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { enabled in
                    if isRevertingLaunchAtLogin {
                        isRevertingLaunchAtLogin = false
                        return
                    }
                    do {
                        try AppSettings.applyLaunchAtLogin(enabled)
                        launchAtLoginError = ""
                    } catch {
                        isRevertingLaunchAtLogin = true
                        launchAtLogin = !enabled
                        launchAtLoginError = AppText.text("无法修改开机自启动：", "無法修改開機時自動啟動：", "Unable to change Launch at Login: ", language: selectedLanguage) + error.localizedDescription
                    }
                }

            Text(launchAtLoginError.isEmpty ? AppText.text("⚠️ 可能仅在 macOS 13 及以上系统生效", "⚠️ 可能僅在 macOS 13 或更新版本生效", "⚠️ May only take effect on macOS 13 or later", language: selectedLanguage) : launchAtLoginError)
                .font(.caption)
                .foregroundColor(launchAtLoginError.isEmpty ? .gray : .red)
                .padding(.leading, 4)

            HStack {
                Text(AppText.text("主题模式", "主題模式", "Appearance", language: selectedLanguage))
                Picker("", selection: $themeMode) {
                    ForEach(ThemeMode.allCases) { mode in
                        Text(mode.displayName(language: selectedLanguage)).tag(mode.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
                .onChange(of: themeMode) { value in
                    AppSettings.applyApplicationAppearance(ThemeMode(rawValue: value) ?? .system)
                }
            }

            Toggle(AppText.text("按 Esc 键退出 EK StreamDL", "按 Esc 鍵退出 EK StreamDL", "Quit EK StreamDL with the Esc key", language: selectedLanguage), isOn: $escToQuit)
            Toggle(AppText.text("关闭最后一个窗口时退出 EK StreamDL", "關閉最後一個視窗時退出 EK StreamDL", "Quit EK StreamDL when the last window is closed", language: selectedLanguage), isOn: $quitWhenLastWindowClosed)

            HStack {
                Text(AppText.text("语言", "語言", "Language", language: selectedLanguage))
                Picker("", selection: $language) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option.displayName).tag(option.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
                .onChange(of: language) { value in
                    AppSettings.applyApplicationLanguage(AppLanguage(rawValue: value) ?? .simplifiedChinese)
                }
            }

            if !resetError.isEmpty {
                Text(resetError)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Spacer()

            HStack(alignment: .center, spacing: 12) {
                Button(AppText.text("恢复默认设置", "恢復預設值", "Restore Defaults", language: selectedLanguage)) {
                    do {
                        try AppSettings.reset()
                        launchAtLogin = AppSettings.launchAtLoginDefault
                        themeMode = AppSettings.themeModeDefault
                        escToQuit = AppSettings.escToQuitDefault
                        quitWhenLastWindowClosed = AppSettings.quitWhenLastWindowClosedDefault
                        autoCheckForUpdates = AppSettings.autoCheckForUpdatesDefault
                        language = AppSettings.languageDefault
                        launchAtLoginError = ""
                        resetError = ""
                        AppSettings.applyApplicationAppearance(.system)
                        AppSettings.applyApplicationLanguage(.simplifiedChinese)
                    } catch {
                        resetError = AppText.text("恢复默认设置失败：", "恢復預設值失敗：", "Unable to restore defaults: ", language: selectedLanguage) + error.localizedDescription
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                    Toggle(AppText.text("自动检查更新", "自動檢查更新", "Automatically Check for Updates", language: selectedLanguage), isOn: $autoCheckForUpdates)

                    HStack(alignment: .center, spacing: 12) {
                        Text(currentVersionText)
                            .font(.footnote)
                            .foregroundColor(.secondary)

                        Button(AppText.text("检查更新", "檢查更新", "Check for Updates", language: selectedLanguage)) {
                            UpdateManager.shared.checkForUpdate(interactive: true)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .padding(24)
        .frame(width: 520, height: 400, alignment: .topLeading)
    }
}
