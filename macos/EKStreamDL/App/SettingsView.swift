import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.launchAtLoginKey) private var launchAtLogin = AppSettings.launchAtLoginDefault
    @AppStorage(AppSettings.themeModeKey) private var themeMode = AppSettings.themeModeDefault
    @AppStorage(AppSettings.escToQuitKey) private var escToQuit = AppSettings.escToQuitDefault
    @AppStorage(AppSettings.quitWhenLastWindowClosedKey) private var quitWhenLastWindowClosed = AppSettings.quitWhenLastWindowClosedDefault
    @AppStorage(AppSettings.autoCheckForUpdatesKey) private var autoCheckForUpdates = AppSettings.autoCheckForUpdatesDefault

    @State private var launchAtLoginError = ""
    @State private var resetError = ""
    @State private var isRevertingLaunchAtLogin = false

    private var currentVersionText: String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !version.isEmpty {
            return "当前版本：v\(version)"
        }
        return "当前版本：—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("偏好设置")
                .font(.title2)
                .bold()
            Divider()

            Toggle("开机自启动", isOn: $launchAtLogin)
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
                        launchAtLoginError = "无法修改开机自启动：\(error.localizedDescription)"
                    }
                }

            Text(launchAtLoginError.isEmpty ? "⚠️ 可能仅在 macOS 13 及以上系统生效" : launchAtLoginError)
                .font(.caption)
                .foregroundColor(launchAtLoginError.isEmpty ? .gray : .red)
                .padding(.leading, 4)

            HStack {
                Text("主题模式")
                Picker("", selection: $themeMode) {
                    ForEach(ThemeMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
                .onChange(of: themeMode) { value in
                    AppSettings.applyApplicationAppearance(ThemeMode(rawValue: value) ?? .system)
                }
            }

            Toggle("按 Esc 键退出 EK StreamDL", isOn: $escToQuit)
            Toggle("关闭最后一个窗口时退出 EK StreamDL", isOn: $quitWhenLastWindowClosed)

            if !resetError.isEmpty {
                Text(resetError)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Spacer()

            HStack(alignment: .center, spacing: 12) {
                Button("恢复默认设置") {
                    do {
                        try AppSettings.reset()
                        launchAtLogin = AppSettings.launchAtLoginDefault
                        themeMode = AppSettings.themeModeDefault
                        escToQuit = AppSettings.escToQuitDefault
                        quitWhenLastWindowClosed = AppSettings.quitWhenLastWindowClosedDefault
                        autoCheckForUpdates = AppSettings.autoCheckForUpdatesDefault
                        launchAtLoginError = ""
                        resetError = ""
                        AppSettings.applyApplicationAppearance(.system)
                    } catch {
                        resetError = "恢复默认设置失败：\(error.localizedDescription)"
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                    Toggle("自动检查更新", isOn: $autoCheckForUpdates)

                    HStack(alignment: .center, spacing: 12) {
                        Text(currentVersionText)
                            .font(.footnote)
                            .foregroundColor(.secondary)

                        Button("检查更新") {
                            UpdateManager.shared.checkForUpdate(interactive: true)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .padding(24)
        .frame(width: 480, height: 350, alignment: .topLeading)
    }
}
