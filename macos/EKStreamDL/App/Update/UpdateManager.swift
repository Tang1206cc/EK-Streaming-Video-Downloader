import AppKit
import Foundation

@MainActor
final class UpdateManager {
    static let shared = UpdateManager()

    private struct LatestInfo {
        let latestVersion: Version
        let assetURL: URL
    }

    private var downloadController: DownloadWindowController?
    private var isChecking = false

    private init() {}

    func checkForUpdate(interactive: Bool = true) {
        guard !isChecking else { return }
        isChecking = true

        Task { [weak self] in
            guard let self else { return }
            defer { isChecking = false }

            do {
                let localVersion = Bundle.main.shortVersion ?? Version("0.0.0")!
                let release = try await GitHubAPI.fetchLatestRelease()
                guard let latestVersion = Version(release.tag_name) else {
                    throw GitHubReleaseError.invalidRelease
                }

                if localVersion >= latestVersion {
                    if interactive {
                        showAlert(
                            title: AppText.text("提示", "提示", "Up to Date"),
                            message: AppText.text("当前已是最新版本！", "目前已是最新版本！", "You’re using the latest version."),
                            buttonTitles: [AppText.text("好", "好", "OK")]
                        )
                    }
                    return
                }

                guard let zipAsset = ReleaseAssetSelector.macOSAsset(
                    in: release.assets,
                    version: latestVersion
                ) else {
                    throw GitHubReleaseError.missingZipAsset
                }

                let response = showUpdateAlert(
                    localVersion: localVersion,
                    latestVersion: latestVersion,
                    releaseBody: release.body
                )
                if response == .alertFirstButtonReturn {
                    beginDownloadAndInstall(
                        with: LatestInfo(
                            latestVersion: latestVersion,
                            assetURL: zipAsset.browser_download_url
                        )
                    )
                }
            } catch {
                if interactive {
                    let title = error is GitHubReleaseError
                        ? AppText.text("检查结果", "檢查結果", "Update Check")
                        : AppText.text("检查失败", "檢查失敗", "Unable to Check for Updates")
                    showAlert(title: title, message: error.localizedDescription, buttonTitles: [AppText.text("好", "好", "OK")])
                }
            }
        }
    }

    @discardableResult
    private func showAlert(
        title: String,
        message: String,
        buttonTitles: [String]
    ) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        buttonTitles.forEach { alert.addButton(withTitle: $0) }
        return alert.runModalWithSystemStyle()
    }

    @discardableResult
    private func showUpdateAlert(
        localVersion: Version,
        latestVersion: Version,
        releaseBody: String?
    ) -> NSApplication.ModalResponse {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "EK StreamDL"

        let alert = NSAlert()
        alert.messageText = AppText.text("\(appName) 有新版本可用", "\(appName) 有新版本可用", "A new version of \(appName) is available")
        alert.informativeText = AppText.text(
            "版本：v\(localVersion.description) - v\(latestVersion.description)\n可立即下载并安装更新。",
            "版本：v\(localVersion.description) - v\(latestVersion.description)\n可立即下載並安裝更新。",
            "Version: v\(localVersion.description) → v\(latestVersion.description)\nDownload and install the update now."
        )
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.accessoryView = makeReleaseNotesView(releaseBody)
        alert.addButton(withTitle: AppText.text("立即更新", "立即更新", "Update Now"))
        alert.addButton(withTitle: AppText.text("下次再说", "下次再說", "Later"))
        return alert.runModalWithSystemStyle()
    }

    private func makeReleaseNotesView(_ releaseBody: String?) -> NSView {
        let trimmedBody = (releaseBody ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let notesText = trimmedBody.isEmpty ? AppText.text("此版本暂无推版描述。", "此版本尚無發佈說明。", "No release notes are available for this version.") : trimmedBody

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 430, height: 190))
        let titleField = NSTextField(labelWithString: AppText.text("GitHub 推版描述", "GitHub 發佈說明", "GitHub Release Notes"))
        titleField.font = .boldSystemFont(ofSize: 13)
        titleField.frame = NSRect(x: 0, y: 166, width: 430, height: 18)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 430, height: 156))
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: scrollView.contentSize.width, height: 156)
        )
        textView.string = notesText
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 12)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.documentView = textView
        container.addSubview(titleField)
        container.addSubview(scrollView)
        return container
    }

    private func beginDownloadAndInstall(with info: LatestInfo) {
        let controller = DownloadWindowController()
        downloadController = controller
        controller.startDownload(from: info.assetURL) { [weak self] result in
            guard let self else { return }
            self.downloadController = nil
            switch result {
            case .success(let zipURL):
                self.install(from: zipURL, info: info)
            case .failure(let error):
                self.showAlert(title: AppText.text("下载失败", "下載失敗", "Download Failed"), message: error.localizedDescription, buttonTitles: [AppText.text("好", "好", "OK")])
            }
        }
    }

    private func install(from zipURL: URL, info: LatestInfo) {
        do {
            let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent(
                    "EKStreamDL-Update-\(info.latestVersion.description)-\(UUID().uuidString)",
                    isDirectory: true
                )
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

            try Installer.unzip(zipURL, to: temporaryDirectory)
            try FileManager.default.removeItem(at: zipURL)

            guard let appURL = locateApp(in: temporaryDirectory) else {
                throw NSError(
                    domain: "Update",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: AppText.text("未在压缩包中找到 EK StreamDL.app", "在壓縮檔中找不到 EK StreamDL.app", "EK StreamDL.app was not found in the archive")]
                )
            }
            try validate(appURL: appURL, expectedVersion: info.latestVersion)
            try Installer.installAndRelaunch(newAppURL: appURL)
        } catch {
            showAlert(title: AppText.text("安装失败", "安裝失敗", "Installation Failed"), message: error.localizedDescription, buttonTitles: [AppText.text("好", "好", "OK")])
        }
    }

    private func locateApp(in directory: URL) -> URL? {
        if directory.pathExtension.lowercased() == "app" { return directory }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        for item in contents {
            if item.pathExtension.lowercased() == "app" {
                return item
            }
            let resourceValues = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if resourceValues?.isDirectory == true,
               resourceValues?.isSymbolicLink != true,
               let found = locateApp(in: item) {
                return found
            }
        }
        return nil
    }

    private func validate(appURL: URL, expectedVersion: Version) throws {
        guard let bundle = Bundle(url: appURL),
              bundle.bundleIdentifier == "com.tang1206cc.ekstreamdl" else {
            throw NSError(
                domain: "Update",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: AppText.text("更新包中的应用身份与 EK StreamDL 不匹配", "更新套件中的應用程式身分與 EK StreamDL 不符", "The app identity in the update does not match EK StreamDL")]
            )
        }
        guard bundle.shortVersion == expectedVersion else {
            throw NSError(
                domain: "Update",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: AppText.text("更新包版本与 GitHub Release 标签不一致", "更新套件版本與 GitHub Release 標籤不一致", "The update version does not match the GitHub Release tag")]
            )
        }
    }
}
