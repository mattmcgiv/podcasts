import SwiftUI
import WebKit

let podsOrigin = URL(string: "https://pods.mcgiv.dev/")!

struct WebShell: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // App-bound mode is what gives this web view a service worker and
        // durable storage for pods.mcgiv.dev (see WKAppBoundDomains in Info.plist).
        configuration.limitsNavigationsToAppBoundDomains = true
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(context.coordinator, name: "podsShell")
        configuration.userContentController.addUserScript(WKUserScript(
            source: Coordinator.consoleForwarder, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.isInspectable = true
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = UIColor(named: "PodsLaunchBackground") ?? .systemBackground
        context.coordinator.webView = webView
        ShellLog.write("shell start build=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "?")")
        webView.load(URLRequest(url: podsOrigin))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?

        static let consoleForwarder = """
        (() => {
          const post = (level, args) => { try {
            window.webkit.messageHandlers.podsShell.postMessage({ kind: "console", level, text: args.map(a => { try { return typeof a === "string" ? a : JSON.stringify(a); } catch { return String(a); } }).join(" ").slice(0, 2000) });
          } catch {} };
          for (const level of ["warn", "error"]) { const original = console[level].bind(console); console[level] = (...args) => { post(level, args); original(...args); }; }
          window.addEventListener("error", e => post("uncaught", [e.message, e.filename + ":" + e.lineno]));
          window.addEventListener("unhandledrejection", e => post("rejection", [String(e.reason)]));
        })();
        """

        static let probe = """
        const registration = navigator.serviceWorker ? await navigator.serviceWorker.getRegistration() : null;
        const estimate = navigator.storage?.estimate ? await navigator.storage.estimate() : null;
        return {
          href: location.href,
          title: document.title,
          serviceWorkerApi: !!navigator.serviceWorker,
          serviceWorkerActive: !!registration?.active,
          serviceWorkerControls: !!navigator.serviceWorker?.controller,
          storagePersisted: navigator.storage?.persisted ? await navigator.storage.persisted() : null,
          storageQuota: estimate?.quota ?? null,
          storageUsage: estimate?.usage ?? null,
          indexedDb: !!window.indexedDB,
          passkeyApi: !!window.PublicKeyCredential,
          mediaSession: !!navigator.mediaSession,
          rootChildren: document.getElementById("root")?.childElementCount ?? -1,
          bodyText: document.body.innerText.slice(0, 300),
          at: Date.now(),
        };
        """

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
            if kind == "console" {
                ShellLog.write("js \(body["level"] as? String ?? "?"): \(body["text"] as? String ?? "")")
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ShellLog.write("didFinish \(webView.url?.absoluteString ?? "?")")
            for delay in [3.0, 15.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.runProbe() }
            }
        }

        private func runProbe() {
            webView?.callAsyncJavaScript(Self.probe, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value):
                    if let status = value as? [String: Any] { ShellLog.writeStatus(status) }
                case .failure(let error):
                    ShellLog.write("probe failed: \(error.localizedDescription)")
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            ShellLog.write("didFail \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            ShellLog.write("didFailProvisional \(error.localizedDescription)")
            // Offline with no installed shell yet: try again shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { webView.load(URLRequest(url: podsOrigin)) }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ShellLog.write("web content process terminated; reloading")
            webView.reload()
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            if action.targetFrame?.isMainFrame == false { return .allow }
            if url.host == podsOrigin.host || url.scheme == "about" { return .allow }
            // Anything else (show-note links, YouTube) opens in the system browser.
            await UIApplication.shared.open(url)
            return .cancel
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url { UIApplication.shared.open(url) }
            return nil
        }
    }
}
