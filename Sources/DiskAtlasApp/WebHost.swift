import AppKit
import WebKit
import DiskAtlasCore

/// `WKWebView` + `diskatlas://` şeması + köprü. Yalnızca paketteki arayüzü yükler; harici gezinme iptal edilir.
final class WebHost: NSObject, WKNavigationDelegate, WKUIDelegate, WKURLSchemeHandler, WKScriptMessageHandlerWithReply, WKScriptMessageHandler {
    static let scheme = "diskatlas"
    static let entryURL = URL(string: "diskatlas://app/index.html")!

    private(set) var webView: WKWebView!
    private let resolver: AssetResolver
    private var router: BridgeRouter!
    private(set) var consoleErrors: [String] = []
    var onLoadFinished: (() -> Void)?

    init(webRoot: URL, rulesURL: URL, store: ReportStore, roots: ScanRoots) throws {
        resolver = AssetResolver(root: webRoot)
        super.init()
        // Yapılandırma, WKWebView oluşturulmadan önce tamamlanmalıdır; sonradan yapılan değişiklikler yok sayılır.
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(self, forURLScheme: Self.scheme)
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "diskatlas")
        configuration.userContentController.add(self, name: "hostLog")
        configuration.userContentController.addUserScript(WKUserScript(source: Self.errorForwarder, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")

        let info = ProcessInfo.processInfo.operatingSystemVersion
        let appInfo = AppInfo(version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "geliştirme",
                              macOS: "\(info.majorVersion).\(info.minorVersion).\(info.patchVersion)")
        router = BridgeRouter(
            store: store, rules: try RuleSet.load(from: rulesURL), roots: roots, appInfo: appInfo,
            permission: { PermissionProbe().fullDiskAccess() },
            openFullDiskAccess: {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            },
            emit: { [weak self] event in
                DispatchQueue.main.async { self?.deliver(event) }
            })
    }

    func load() {
        webView.load(URLRequest(url: Self.entryURL))
    }

    private func deliver(_ event: Data) {
        let script = "window.diskAtlasEvent && window.diskAtlasEvent(\(String(decoding: event, as: UTF8.self)))"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    // MARK: Köprü (JS -> Swift)

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.protocol == Self.scheme,
              let body = message.body as? String else {
            replyHandler(nil, "Geçersiz köprü mesajı.")
            return
        }
        debug("bridge \(body.prefix(80))")
        let router = self.router!
        DispatchQueue.global(qos: .userInitiated).async {
            let response = String(decoding: router.handle(Data(body.utf8)), as: UTF8.self)
            DispatchQueue.main.async { replyHandler(response, nil) }
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "hostLog", let text = message.body as? String { consoleErrors.append(text) }
    }

    private static let errorForwarder = """
    (function () {
      const send = text => window.webkit.messageHandlers.hostLog.postMessage(text);
      window.addEventListener('error', e => send('error: ' + e.message + ' @' + e.filename + ':' + e.lineno));
      window.addEventListener('unhandledrejection', e => send('rejection: ' + String(e.reason)));
      window.addEventListener('securitypolicyviolation', e => send('csp: ' + e.violatedDirective + ' ' + e.blockedURI));
      const original = console.error;
      console.error = function () { send('console.error: ' + Array.from(arguments).join(' ')); original.apply(console, arguments); };
    })();
    """

    // MARK: Şema işleyici (paketteki dosyalar)

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        debug("asset \(task.request.url?.absoluteString ?? "?")")
        guard let url = task.request.url, let asset = resolver.resolve(path: url.path),
              let data = try? Data(contentsOf: asset.url) else {
            let missing = HTTPURLResponse(url: task.request.url ?? Self.entryURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            task.didReceive(missing)
            task.didFinish()
            return
        }
        let textual = asset.mimeType.hasPrefix("text/") || asset.mimeType == "application/json"
        let headers = ["Content-Type": textual ? asset.mimeType + "; charset=utf-8" : asset.mimeType,
                       "Content-Length": String(data.count), "Cache-Control": "no-store"]
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    // MARK: Gezinme politikası

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.scheme == Self.scheme ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        debug("didFinish")
        onLoadFinished?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { debug("didFail \(error)") }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { debug("didFailProvisional \(error)") }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { debug("web content process terminated") }

    private func debug(_ text: String) {
        if ProcessInfo.processInfo.environment["DISKATLAS_DEBUG"] != nil { FileHandle.standardError.write(Data(("[debug] " + text + "\n").utf8)) }
    }
}
