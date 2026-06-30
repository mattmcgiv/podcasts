import SwiftUI
import UIKit
import WebKit

struct PodsWebView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> PodsWebViewController {
        PodsWebViewController()
    }

    func updateUIViewController(_ uiViewController: PodsWebViewController, context: Context) {}
}

final class PodsWebViewController: UIViewController {
    private var webView: WKWebView!

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.addUserScript(WKUserScript(
            source: "window.PODS_API_BASE = 'http://127.0.0.1:18180';",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        config.userContentController.addUserScript(WKUserScript(
            source: Self.diagnosticsScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        config.userContentController.add(AudioBridge.shared, name: "podsAudio")
        config.userContentController.add(PodsJavaScriptLogHandler.shared, name: "podsLog")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        AudioBridge.shared.attach(webView: webView)
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadBundledWebApp()
    }

    private func loadBundledWebApp() {
        if let url = URL(string: "http://127.0.0.1:18180/") {
            PodsLog("Pods webview loading \(url.absoluteString)")
            webView.load(URLRequest(url: url))
            return
        }

        let html = """
        <!doctype html>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Pods</title>
        <style>
          body { margin: 0; min-height: 100vh; display: grid; place-items: center; font: -apple-system-body; background: #101418; color: white; }
          main { max-width: 320px; padding: 24px; text-align: center; }
        </style>
        <main>
          <h1>Pods</h1>
          <p>Web assets are missing. Run ios/prepare-web-assets.sh before building the app.</p>
        </main>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    private static let diagnosticsScript = """
    (function() {
      function stringify(value) {
        try {
          if (value instanceof Error) {
            return value.name + ": " + value.message + (value.stack ? "\\n" + value.stack : "");
          }
          if (typeof value === "object") {
            return JSON.stringify(value);
          }
          return String(value);
        } catch (error) {
          return String(value);
        }
      }

      function send(level, message) {
        try {
          window.webkit.messageHandlers.podsLog.postMessage({ level: level, message: message });
        } catch (error) {}
      }

      ["log", "warn", "error"].forEach(function(level) {
        var original = console[level];
        console[level] = function() {
          send("console." + level, Array.prototype.map.call(arguments, stringify).join(" "));
          if (original) {
            original.apply(console, arguments);
          }
        };
      });

      window.addEventListener("error", function(event) {
        send("error", event.message + " @ " + event.filename + ":" + event.lineno + ":" + event.colno);
      });

      window.addEventListener("unhandledrejection", function(event) {
        send("unhandledrejection", stringify(event.reason));
      });
    })();
    """
}

extension PodsWebViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        PodsLog("Pods webview finished \(webView.url?.absoluteString ?? "unknown URL")")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        PodsLog("Pods webview navigation failed: \(error)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        PodsLog("Pods webview provisional navigation failed: \(error)")
    }
}

final class PodsJavaScriptLogHandler: NSObject, WKScriptMessageHandler {
    static let shared = PodsJavaScriptLogHandler()

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] {
            let level = body["level"] as? String ?? "log"
            let text = body["message"] as? String ?? "\(body)"
            PodsLog("Pods web \(level): \(text)")
        } else {
            PodsLog("Pods web log: \(message.body)")
        }
    }
}
