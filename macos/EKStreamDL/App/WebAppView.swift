import AppKit
import SwiftUI
import WebKit

enum WebAppRoute: String {
    case videoDownloader = "video-downloader"
}

struct WebAppView: NSViewRepresentable {
    let route: WebAppRoute

    init(route: WebAppRoute = .videoDownloader) {
        self.route = route
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator.bridge, name: "ekStreamDLNative")
        userContentController.addUserScript(
            WKUserScript(
                source: "window.__ekStreamDLInitialRoute = \"\(route.rawValue)\";",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        userContentController.addUserScript(
            WKUserScript(
                source: NativeThemeScript.source(mode: AppSettings.themeMode.rawValue),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        userContentController.addUserScript(
            WKUserScript(
                source: NativeBridgeScript.source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        userContentController.addUserScript(
            WKUserScript(
                source: NativeDiagnosticsScript.source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContentController
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        context.coordinator.webView = webView
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")

        if let indexURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "dist") {
            let distURL = indexURL.deletingLastPathComponent()
            if let html = try? makeInlineHTML(indexURL: indexURL, distURL: distURL) {
                webView.loadHTMLString(html, baseURL: distURL)
            } else {
                webView.loadFileURL(indexURL, allowingReadAccessTo: distURL)
            }
        } else {
            webView.loadHTMLString(
                "<main style='font-family:-apple-system;padding:32px'>未找到前端资源，请先执行 pnpm run build。</main>",
                baseURL: nil
            )
        }

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    private func makeInlineHTML(indexURL: URL, distURL: URL) throws -> String {
        var html = try String(contentsOf: indexURL, encoding: .utf8)
        html = html
            .replacingOccurrences(of: "src=\"/assets", with: "src=\"./assets")
            .replacingOccurrences(of: "href=\"/assets", with: "href=\"./assets")

        let scriptPattern = #"<script[^>]*src=\"\.\/assets\/([^\"]+\.js)\"[^>]*></script>"#
        let stylePattern = #"<link[^>]*href=\"\.\/assets\/([^\"]+\.css)\"[^>]*>"#

        if let scriptMatch = firstMatch(in: html, pattern: scriptPattern),
           let scriptName = capturedGroup(in: html, match: scriptMatch, index: 1) {
            let scriptURL = distURL.appendingPathComponent("assets").appendingPathComponent(scriptName)
            let script = try String(contentsOf: scriptURL, encoding: .utf8)
            html = html.replacingCharacters(
                in: Range(scriptMatch.range, in: html)!,
                with: ""
            )
            html = html.replacingOccurrences(
                of: "</body>",
                with: "<script>\n\(script)\n</script>\n</body>"
            )
        }

        if let styleMatch = firstMatch(in: html, pattern: stylePattern),
           let styleName = capturedGroup(in: html, match: styleMatch, index: 1) {
            let styleURL = distURL.appendingPathComponent("assets").appendingPathComponent(styleName)
            let style = try String(contentsOf: styleURL, encoding: .utf8)
            html = html.replacingCharacters(
                in: Range(styleMatch.range, in: html)!,
                with: "<style>\n\(style)\n</style>"
            )
        }

        return html
    }

    private func firstMatch(in text: String, pattern: String) -> NSTextCheckingResult? {
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex?.firstMatch(in: text, range: range)
    }

    private func capturedGroup(in text: String, match: NSTextCheckingResult, index: Int) -> String? {
        guard match.numberOfRanges > index,
              let range = Range(match.range(at: index), in: text) else {
            return nil
        }
        return String(text[range])
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let bridge = VideoBridge()
        private var appearanceObserver: NSObjectProtocol?

        weak var webView: WKWebView? {
            didSet {
                bridge.webView = webView
                applyTheme()
            }
        }

        override init() {
            super.init()
            appearanceObserver = NotificationCenter.default.addObserver(
                forName: AppSettings.applicationAppearanceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.applyTheme()
            }
        }

        deinit {
            if let appearanceObserver {
                NotificationCenter.default.removeObserver(appearanceObserver)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            applyTheme()
        }

        private func applyTheme() {
            let mode = AppSettings.themeMode.rawValue
            webView?.evaluateJavaScript("window.__ekStreamDLApplyThemeMode?.('\(mode)');")

            // 解除应用级深色外观后，WebKit 的系统配色查询会在下一轮主循环完成更新。
            // 再同步一次可避免“跟随系统”短暂沿用先前的深色结果。
            if mode == ThemeMode.system.rawValue {
                DispatchQueue.main.async { [weak self] in
                    self?.webView?.evaluateJavaScript("window.__ekStreamDLApplyThemeMode?.('\(mode)');")
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                decisionHandler(.allow)
                return
            }

            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }
}

@MainActor
final class ToolWindowManager: NSObject, NSWindowDelegate {
    static let shared = ToolWindowManager()

    private var videoDownloaderWindow: NSWindow?

    func openVideoDownloader() {
        if let videoDownloaderWindow {
            videoDownloaderWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let sourceWindow = NSApp.keyWindow
        let sourceSize = sourceWindow?.contentView?.bounds.size ?? NSSize(width: 920, height: 700)
        let windowSize = NSSize(width: max(920, sourceSize.width), height: max(700, sourceSize.height))
        let contentView = WebAppView(route: .videoDownloader)
            .frame(minWidth: 920, minHeight: 700)
        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = "EK流媒体视频下载器"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 920, height: 700)
        window.backgroundColor = NSColor(red: 0.96, green: 0.97, blue: 0.98, alpha: 1)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self

        if let sourceWindow {
            window.setFrameTopLeftPoint(
                NSPoint(x: sourceWindow.frame.minX + 28, y: sourceWindow.frame.maxY - 28)
            )
        } else {
            window.center()
        }

        videoDownloaderWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === videoDownloaderWindow else {
            return
        }
        videoDownloaderWindow = nil
    }
}

enum NativeThemeScript {
    static func source(mode: String) -> String {
        """
        (() => {
          const systemDarkMode = window.matchMedia("(prefers-color-scheme: dark)");
          let requestedMode = "\(mode)";

          function applyTheme() {
            const normalizedMode = ["system", "light", "dark"].includes(requestedMode)
              ? requestedMode
              : "system";
            const resolvedMode = normalizedMode === "system"
              ? (systemDarkMode.matches ? "dark" : "light")
              : normalizedMode;
            document.documentElement.dataset.ekStreamdlTheme = normalizedMode;
            document.documentElement.dataset.ekStreamdlResolvedTheme = resolvedMode;
            document.documentElement.style.colorScheme = resolvedMode;
          }

          window.__ekStreamDLApplyThemeMode = (mode) => {
            requestedMode = mode;
            applyTheme();
          };

          const handleSystemThemeChange = () => {
            if (requestedMode === "system") applyTheme();
          };
          if (typeof systemDarkMode.addEventListener === "function") {
            systemDarkMode.addEventListener("change", handleSystemThemeChange);
          } else if (typeof systemDarkMode.addListener === "function") {
            systemDarkMode.addListener(handleSystemThemeChange);
          }
          applyTheme();
        })();
        """
    }
}

enum NativeBridgeScript {
    static let source = """
    (() => {
      const callbacks = new Map();
      const progressCallbacks = new Map();
      let nextId = 1;

      function post(action, payload, onProgress) {
        const id = String(nextId++);
        return new Promise((resolve, reject) => {
          callbacks.set(id, { resolve, reject });
          if (onProgress) progressCallbacks.set(id, onProgress);
          window.webkit.messageHandlers.ekStreamDLNative.postMessage({ id, action, payload });
        });
      }

      window.__ekStreamDLNativeResolve = (id, result) => {
        const callback = callbacks.get(id);
        if (!callback) return;
        callbacks.delete(id);
        progressCallbacks.delete(id);
        callback.resolve(result);
      };

      window.__ekStreamDLNativeReject = (id, message) => {
        const callback = callbacks.get(id);
        if (!callback) return;
        callbacks.delete(id);
        progressCallbacks.delete(id);
        callback.reject(new Error(message || "操作失败"));
      };

      window.__ekStreamDLNativeProgress = (id, event) => {
        const callback = progressCallbacks.get(id);
        if (callback) callback(event);
      };

      window.ekStreamDLDesktop = {
        platform: "darwin",
        nativeBridge: {
          openPreferences() {
            return post("openPreferences", {});
          },
          openToolWindow(toolId) {
            return post("openToolWindow", { toolId });
          },
          parseVideo(inputText) {
            return post("parseVideo", { inputText });
          },
          selectDownloadDirectory() {
            return post("selectDownloadDirectory", {});
          },
          downloadVideo(metadata, downloadDirectoryPath, downloadMode, onProgress, taskIdentifier) {
            const payload = { metadata, taskIdentifier };
            if (downloadDirectoryPath) payload.downloadDirectoryPath = downloadDirectoryPath;
            payload.downloadMode = downloadMode || "complete";
            return post("downloadVideo", payload, onProgress);
          },
          cancelDownload(taskIdentifier, deletePartialFiles) {
            return post("cancelDownload", { taskIdentifier, deletePartialFiles });
          },
          pauseDownload(taskIdentifier) {
            return post("pauseDownload", { taskIdentifier });
          },
          resumeDownload(taskIdentifier) {
            return post("resumeDownload", { taskIdentifier });
          },
          downloadCover(metadata, downloadDirectoryPath) {
            const payload = { metadata };
            if (downloadDirectoryPath) payload.downloadDirectoryPath = downloadDirectoryPath;
            return post("downloadCover", payload);
          },
          playCompletionSound() {
            return post("playCompletionSound", {});
          },
          checkRuntimeEnvironment() {
            return post("checkRuntimeEnvironment", {});
          },
          installRuntimeEnvironment(onProgress) {
            return post("installRuntimeEnvironment", {}, onProgress);
          },
          getWeChatAuthorizationStatus() {
            return post("getWeChatAuthorizationStatus", {});
          },
          clearWeChatAuthorization() {
            return post("clearWeChatAuthorization", {});
          },
          exportDiagnosticReport(report) {
            return post("exportDiagnosticReport", report ? { report } : {});
          }
        }
      };
    })();
    """
}

enum NativeDiagnosticsScript {
    static let source = """
    (() => {
      window.addEventListener("error", (event) => {
        console.error("[EK StreamDL WebView Error]", event.message, event.filename, event.lineno, event.colno);
      });
      window.addEventListener("unhandledrejection", (event) => {
        console.error("[EK StreamDL WebView Promise]", event.reason && (event.reason.stack || event.reason.message || String(event.reason)));
      });
    })();
    """
}
