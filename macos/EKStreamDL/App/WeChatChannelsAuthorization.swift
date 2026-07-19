import AppKit
import WebKit

private struct YuanbaoWebResponse: Decodable {
    var status: Int
    var body: String
}

@MainActor
final class WeChatChannelsAuthorization: NSObject, NSWindowDelegate, WKNavigationDelegate {
    static let shared = WeChatChannelsAuthorization()

    private let yuanbaoURL = URL(
        string: "https://yuanbao.tencent.com/chat/naQivTmsDa/cf4d0079-ed1b-4c55-a3f3-2ca1379727d1"
    )!
    private let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"
    private var authorizationWindow: NSWindow?
    private var webView: WKWebView?
    private var navigationError: Error?
    private var userCancelledAuthorization = false
    private var authorizationWaiterCount = 0
    private var needsFreshAuthorization = false

    func parseIfAuthorized(shareURL: String) async -> WeChatChannelsYuanbaoParseResponse? {
        guard !needsFreshAuthorization else {
            return nil
        }
        do {
            let webView = try await preparedWebView()
            guard try await isLoggedIn(webView: webView) else {
                return nil
            }
            let webResponse = try await requestParseResult(shareURL: shareURL, webView: webView)
            let response = try decodeParseResponse(webResponse)
            guard (200..<300).contains(webResponse.status), response.code == 0 else {
                if isAuthorizationFailure(webResponse: webResponse, response: response) {
                    needsFreshAuthorization = true
                }
                return nil
            }
            return response
        } catch {
            return nil
        }
    }

    func authorizedParse(
        shareURL: String,
        shouldCancel: @escaping () -> Bool
    ) async throws -> WeChatChannelsYuanbaoParseResponse {
        authorizationWaiterCount += 1
        defer {
            authorizationWaiterCount -= 1
            if authorizationWaiterCount == 0 {
                authorizationWindow?.orderOut(nil)
            }
        }
        if shouldCancel() {
            throw UserFacingError("下载已取消")
        }
        let webView = try await preparedWebView()
        for attempt in 0..<2 {
            if shouldCancel() {
                throw UserFacingError("下载已取消")
            }

            if needsFreshAuthorization {
                try await resetAuthorizationSession(webView: webView)
                needsFreshAuthorization = false
            }
            if try await isLoggedIn(webView: webView) == false {
                try await waitForAuthorization(webView: webView, shouldCancel: shouldCancel)
            }

            let webResponse = try await requestParseResult(shareURL: shareURL, webView: webView)
            let response = try decodeParseResponse(webResponse)
            if (200..<300).contains(webResponse.status), response.code == 0 {
                needsFreshAuthorization = false
                return response
            }
            if isAuthorizationFailure(webResponse: webResponse, response: response) {
                needsFreshAuthorization = true
                if attempt == 0 {
                    continue
                }
                break
            }
            throw parseFailure(response: response, status: webResponse.status)
        }

        throw UserFacingError("下载失败：微信登录状态未生效，再次点击下载将重新发起授权")
    }

    func clearAuthorization() async {
        needsFreshAuthorization = true
        userCancelledAuthorization = true
        if let webView {
            _ = try? await callJavaScript(
                "localStorage.clear(); sessionStorage.clear(); return true;",
                arguments: [:],
                in: webView
            )
        }
        await deleteYuanbaoCookies()
        authorizationWindow?.orderOut(nil)
        DiagnosticLogStore.shared.append("微信视频号", "用户已清理当前腾讯元宝授权")
    }

    func currentAuthorizationStatus() async -> Bool {
        guard !needsFreshAuthorization else {
            return false
        }
        do {
            let webView = try await preparedWebView()
            return try await isLoggedIn(webView: webView)
        } catch {
            return false
        }
    }

    private func preparedWebView() async throws -> WKWebView {
        if let webView,
           isYuanbaoHost(webView.url?.host),
           !webView.isLoading {
            return webView
        }

        let webView = makeWebViewIfNeeded()
        navigationError = nil
        if !isYuanbaoHost(webView.url?.host) {
            webView.load(URLRequest(url: yuanbaoURL))
        }

        try await waitForWebView(webView)
        return webView
    }

    private func makeWebViewIfNeeded() -> WKWebView {
        if let webView {
            return webView
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = browserUserAgent
        webView.navigationDelegate = self
        self.webView = webView
        return webView
    }

    private func showAuthorizationWindow(webView: WKWebView) {
        userCancelledAuthorization = false
        let window: NSWindow
        if let authorizationWindow {
            window = authorizationWindow
        } else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 920, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "微信视频号授权 · 腾讯元宝"
            window.minSize = NSSize(width: 760, height: 620)
            window.contentView = webView
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.delegate = self
            window.center()
            authorizationWindow = window
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func waitForAuthorization(
        webView: WKWebView,
        shouldCancel: @escaping () -> Bool
    ) async throws {
        showAuthorizationWindow(webView: webView)
        let deadline = Date().addingTimeInterval(300)
        while !userCancelledAuthorization {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            if shouldCancel() {
                throw UserFacingError("下载已取消")
            }
            if try await isLoggedIn(webView: webView) {
                return
            }
            if Date() >= deadline {
                throw UserFacingError("微信视频号授权等待超时，请重新点击下载后登录")
            }
        }
        throw UserFacingError("微信视频号授权已取消")
    }

    private func isLoggedIn(webView: WKWebView) async throws -> Bool {
        let script = """
        const response = await fetch('/api/getuserinfo', {
          credentials: 'include',
          cache: 'no-store'
        });
        return response.status;
        """
        do {
            let result = try await callJavaScript(script, in: webView)
            if let status = result as? NSNumber {
                return status.intValue == 200
            }
            if let status = result as? Int {
                return status == 200
            }
            if let status = result as? Double {
                return Int(status) == 200
            }
            return false
        } catch {
            if authorizationWindow?.isVisible == true {
                return false
            }
            throw UserFacingError("无法检查微信视频号授权状态：\(error.localizedDescription)")
        }
    }

    private func requestParseResult(
        shareURL: String,
        webView: WKWebView
    ) async throws -> YuanbaoWebResponse {
        let script = """
        const response = await fetch('/api/weixin/get_parse_result', {
          method: 'POST',
          credentials: 'include',
          cache: 'no-store',
          headers: {
            'Accept': 'application/json, text/plain, */*',
            'Content-Type': 'application/json',
            'X-Requested-With': 'XMLHttpRequest',
            'X-Source': 'web',
            'X-Platform': 'mac',
            'X-Language': 'zh-CN',
            'X-Web-Third-Source': 'main',
            'X-AgentId': 'naQivTmsDa/cf4d0079-ed1b-4c55-a3f3-2ca1379727d1'
          },
          body: JSON.stringify({ type: 'video_channel_url', url: shareURL, scene: 1 })
        });
        return JSON.stringify({ status: response.status, body: await response.text() });
        """
        let result = try await callJavaScript(
            script,
            arguments: ["shareURL": shareURL],
            in: webView
        )
        guard let json = result as? String,
              let data = json.data(using: .utf8) else {
            throw UserFacingError("下载失败：腾讯元宝未返回有效响应")
        }
        do {
            return try JSONDecoder().decode(YuanbaoWebResponse.self, from: data)
        } catch {
            throw UserFacingError("下载失败：腾讯元宝返回了无法识别的数据")
        }
    }

    private func decodeParseResponse(
        _ webResponse: YuanbaoWebResponse
    ) throws -> WeChatChannelsYuanbaoParseResponse {
        guard let data = webResponse.body.data(using: .utf8) else {
            throw UserFacingError("下载失败：腾讯元宝响应内容无效")
        }
        do {
            return try JSONDecoder().decode(WeChatChannelsYuanbaoParseResponse.self, from: data)
        } catch {
            throw UserFacingError("下载失败：腾讯元宝返回了无法识别的解析数据")
        }
    }

    private func isAuthorizationFailure(
        webResponse: YuanbaoWebResponse,
        response: WeChatChannelsYuanbaoParseResponse
    ) -> Bool {
        if webResponse.status == 401 || webResponse.status == 403 {
            return true
        }
        let message = response.msg ?? ""
        return message.contains("登录") || message.contains("授权")
    }

    private func parseFailure(
        response: WeChatChannelsYuanbaoParseResponse,
        status: Int
    ) -> UserFacingError {
        let message = response.msg?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message, !message.isEmpty {
            return UserFacingError("下载失败：\(message)")
        }
        return UserFacingError("下载失败：腾讯元宝解析服务响应异常（\(status)）")
    }

    private func resetAuthorizationSession(webView: WKWebView) async throws {
        _ = try? await callJavaScript(
            "localStorage.clear(); sessionStorage.clear(); return true;",
            arguments: [:],
            in: webView
        )

        await deleteYuanbaoCookies()

        navigationError = nil
        webView.load(
            URLRequest(
                url: yuanbaoURL,
                cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                timeoutInterval: 30
            )
        )
        try await waitForWebView(webView)
    }

    private func deleteYuanbaoCookies() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
        let host = "yuanbao.tencent.com"
        for cookie in cookies {
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard host == domain || host.hasSuffix(".\(domain)") else {
                continue
            }
            await withCheckedContinuation { continuation in
                store.delete(cookie) { continuation.resume() }
            }
        }
    }

    private func callJavaScript(
        _ body: String,
        arguments: [String: Any] = [:],
        in webView: WKWebView
    ) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(
                body,
                arguments: arguments,
                in: nil,
                in: .page
            ) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func waitForWebView(_ webView: WKWebView) async throws {
        let deadline = Date().addingTimeInterval(30)
        while webView.isLoading || !isYuanbaoHost(webView.url?.host) {
            if let navigationError {
                throw UserFacingError("微信视频号授权页加载失败：\(navigationError.localizedDescription)")
            }
            if Date() >= deadline {
                throw UserFacingError("微信视频号授权页加载超时，请检查网络后重试")
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    private func isYuanbaoHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else {
            return false
        }
        return host == "yuanbao.tencent.com" || host.hasSuffix(".yuanbao.tencent.com")
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === authorizationWindow else {
            return
        }
        userCancelledAuthorization = true
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        navigationError = error
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        navigationError = error
    }
}
