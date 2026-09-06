import SwiftUI
import WebKit

/// Access の SSO / OTP を in-app WebView で完了し、`CF_Authorization` を取り出す。
/// `api.*` 直叩きは 403 interstitial なので App Launcher から入る。途中で healthz には飛ばさない。
struct AccessLoginView: View {
    let baseURL: URL
    let onComplete: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                AccessLoginWebView(baseURL: baseURL) { result in
                    switch result {
                    case .success(let jwt):
                        onComplete(jwt)
                        dismiss()
                    case .failure(let error):
                        errorMessage = error.localizedDescription
                    }
                }
                .ignoresSafeArea(edges: .bottom)
                if let errorMessage {
                    VStack(spacing: 12) {
                        Text(errorMessage)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Theme.text)
                        Button("閉じる") { dismiss() }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.shell.opacity(0.92))
                }
            }
            .navigationTitle("ログイン")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .bltChrome()
        }
    }
}

private struct AccessLoginWebView: UIViewControllerRepresentable {
    let baseURL: URL
    let onResult: (Result<String?, Error>) -> Void

    func makeUIViewController(context: Context) -> AccessLoginController {
        let controller = AccessLoginController(
            apiHost: baseURL.host ?? "",
            onResult: onResult)
        return controller
    }

    func updateUIViewController(_ uiViewController: AccessLoginController, context: Context) {}
}

final class AccessLoginController: UIViewController, WKNavigationDelegate, WKUIDelegate,
    WKHTTPCookieStoreObserver
{
    let apiHost: String
    let onResult: (Result<String?, Error>) -> Void
    private var webView: WKWebView?
    private var finished = false

    init(apiHost: String, onResult: @escaping (Result<String?, Error>) -> Void) {
        self.apiHost = apiHost
        self.onResult = onResult
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.customUserAgent =
            "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isInspectable = true
        self.webView = webView
        view.addSubview(webView)
        webView.configuration.websiteDataStore.httpCookieStore.add(self)
        webView.load(URLRequest(url: APIConfiguration.accessLauncherURL))
    }

    deinit {
        webView?.configuration.websiteDataStore.httpCookieStore.remove(self)
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        cookieStore.getAllCookies { [weak self] cookies in
            self?.captureAPICookie(cookies)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            self?.captureAPICookie(cookies)
        }
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        let urlError = error as NSError
        if urlError.domain == NSURLErrorDomain, urlError.code == NSURLErrorCancelled { return }
        complete(.failure(error))
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    private func captureAPICookie(_ cookies: [HTTPCookie]) {
        guard let jwt = cookies.first(where: isAPICookie)?.value else { return }
        complete(.success(jwt))
    }

    private func isAPICookie(_ cookie: HTTPCookie) -> Bool {
        guard cookie.name == AccessSession.cookieName, !cookie.value.isEmpty else { return false }
        let domain = String(cookie.domain.lowercased().trimmingPrefix("."))
        let host = apiHost.lowercased()
        return host == domain || host.hasSuffix(".\(domain)")
    }

    private func complete(_ result: Result<String?, Error>) {
        guard !finished else { return }
        finished = true
        DispatchQueue.main.async { self.onResult(result) }
    }
}
