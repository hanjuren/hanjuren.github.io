import AppKit
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!

    private let launchAt = Date()
    private var firstRenderLogged = false
    private let cooldown: TimeInterval = 3600  // 성공 수집 후 1시간 재수집 금지
    private var isRefreshing = false
    private var lastSuccessAt: Date?
    private var periodicTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()  // localStorage(내 청약) 영구 보존
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.userContentController.add(self, name: "native")

        // 캐시된 공고 데이터가 있으면 페이지 로드 전에 주입 + 쿨다운 기준 시각 복원
        if let cached = DataFetcher.loadCache() {
            inject(config.userContentController, data: cached)
            if let iso = cached["lastUpdatedAt"] as? String {
                lastSuccessAt = ISO8601DateFormatter().date(from: iso)
            }
        }

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        loadUI()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "청약 캘린더"
        window.minSize = NSSize(width: 720, height: 560)
        window.contentView = webView
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 켜둔 채 방치해도 6시간마다 갱신 시도 (쿨다운 규칙은 동일 적용)
        periodicTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.attemptRefresh(reason: "6시간 주기")
        }

        attemptRefresh(reason: "앱 실행")
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // 창이 아직 없는 최초 활성화는 didFinishLaunching이 처리
        guard webView != nil else { return }
        attemptRefresh(reason: "앱 활성화")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - 갱신 상태머신

    private var cooldownRemaining: TimeInterval {
        guard let last = lastSuccessAt else { return 0 }
        return max(0, cooldown - Date().timeIntervalSince(last))
    }

    @objc func refreshData() { attemptRefresh(reason: "수동") }

    func attemptRefresh(reason: String) {
        guard !isRefreshing else { return }
        guard cooldownRemaining == 0 else {
            pushState()
            return
        }
        isRefreshing = true
        pushState()
        DataFetcher.log("갱신 시도 (\(reason))")
        Task { @MainActor in
            do {
                let fresh = try await DataFetcher.refresh()
                lastSuccessAt = Date()
                let controller = webView.configuration.userContentController
                controller.removeAllUserScripts()
                inject(controller, data: fresh)          // 이후 페이지 리로드 대비
                callJS("window.__applyData", arg: fresh) // 현재 화면 즉시 갱신
            } catch {
                DataFetcher.log("갱신 실패(\(reason)): \(error)")
                webView.evaluateJavaScript("window.__onRefreshError && window.__onRefreshError()",
                                           completionHandler: nil)
            }
            isRefreshing = false
            pushState()
        }
    }

    /// 웹 UI에 갱신 상태(진행 중 여부, 마지막 성공 시각, 쿨다운 잔여초) 전달
    private func pushState() {
        let iso = lastSuccessAt.map { ISO8601DateFormatter().string(from: $0) } ?? ""
        let js = "window.__onRefreshState && window.__onRefreshState({refreshing:\(isRefreshing),lastUpdatedAt:'\(iso)',cooldownRemaining:\(Int(cooldownRemaining))})"
        webView.evaluateJavaScript(js)
    }

    // MARK: - JS 브리지

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "native", let body = message.body as? [String: Any] else { return }
        if body["action"] as? String == "refresh" {
            attemptRefresh(reason: "수동")
        } else if body["action"] as? String == "rendered", !firstRenderLogged {
            firstRenderLogged = true
            let ms = Int(Date().timeIntervalSince(launchAt) * 1000)
            DataFetcher.log("첫 화면 렌더 완료: \(ms)ms (캐시 \(DataFetcher.loadCache() == nil ? "없음" : "있음"))")
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pushState()
    }

    /// target="_blank" 링크(공고 원문 보기)는 새 WKWebView 대신 기본 브라우저로 연다.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

    /// 앱 내에서 외부 http(s)로 이동하려는 경우도 기본 브라우저로 (로컬 UI 유지).
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url,
           let scheme = url.scheme, scheme == "http" || scheme == "https" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    private func callJS(_ fn: String, arg: [String: Any]) {
        guard let json = jsonString(arg) else { return }
        webView.evaluateJavaScript("\(fn) && \(fn)(\(json))")
    }

    private func jsonString(_ obj: [String: Any]) -> String? {
        guard let json = try? JSONSerialization.data(withJSONObject: obj),
              var text = String(data: json, encoding: .utf8) else { return nil }
        // U+2028/2029는 JSON에선 유효하지만 JS 리터럴에선 개행으로 해석됨
        text = text.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return text
    }

    private func inject(_ controller: WKUserContentController, data: [String: Any]) {
        guard let text = jsonString(data) else { return }
        controller.addUserScript(WKUserScript(
            source: "window.NOTICES = \(text);",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
    }

    private func loadUI() {
        guard let html = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web") else {
            NSLog("web/index.html 리소스를 찾을 수 없음")
            return
        }
        webView.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
    }
}
