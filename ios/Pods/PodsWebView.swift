import SwiftUI
import UIKit
import WebKit

@MainActor
protocol PodsWebViewLoading: AnyObject {
    var url: URL? { get }

    @discardableResult
    func load(_ request: URLRequest) -> WKNavigation?

    @discardableResult
    func reload() -> WKNavigation?

    func evaluateJavaScript(
        _ javaScriptString: String,
        completionHandler: (@MainActor @Sendable (Any?, Error?) -> Void)?
    )
}

extension WKWebView: PodsWebViewLoading {}

@MainActor
final class PodsWebViewRecovery {
    /// Delay before the post-activation recheck so WebKit/React can settle.
    static let activationRecheckDelay: TimeInterval = 0.75

    /// Schedules delayed work and returns a cancel closure. Injected for deterministic tests.
    typealias ScheduleDelayedWork = (_ work: @escaping @MainActor () -> Void) -> (() -> Void)

    private let rootURL: URL
    private let scheduleDelayedWork: ScheduleDelayedWork
    private var cancelPendingWork: (() -> Void)?
    /// Bumped on every activation/cancel so delayed callbacks that lost a cancel race no-op.
    private var delayedWorkGeneration: UInt = 0

    init(
        rootURL: URL,
        scheduleDelayedWork: ScheduleDelayedWork? = nil
    ) {
        self.rootURL = rootURL
        self.scheduleDelayedWork = scheduleDelayedWork ?? Self.defaultScheduleDelayedWork
    }

    /// Immediate health check plus one delayed recheck. Replaces any prior delayed work.
    func handleActivation(_ webView: PodsWebViewLoading) {
        cancelPendingRecovery()
        PodsDebugLog("Pods webview activation health check requested")
        reloadIfContentMissing(webView)
        let generation = delayedWorkGeneration
        cancelPendingWork = scheduleDelayedWork { [weak self, weak webView] in
            guard let self, let webView else {
                return
            }
            guard self.delayedWorkGeneration == generation else {
                return
            }
            self.cancelPendingWork = nil
            PodsDebugLog("Pods webview delayed activation recheck requested")
            self.reloadIfContentMissing(webView)
        }
    }

    /// Cancels any scheduled delayed recheck (teardown / replacement).
    func cancelPendingRecovery() {
        delayedWorkGeneration &+= 1
        cancelPendingWork?()
        cancelPendingWork = nil
    }

    func loadRoot(_ webView: PodsWebViewLoading) {
        webView.load(URLRequest(url: rootURL))
    }

    func recoverFromWebContentTermination(_ webView: PodsWebViewLoading) {
        PodsLog("Pods webview content process terminated; reloading \(rootURL.absoluteString)")
        loadRoot(webView)
    }

    func reloadIfContentMissing(_ webView: PodsWebViewLoading) {
        guard isServingRoot(webView.url) else {
            PodsLog("Pods webview foreground URL missing or unexpected; reloading \(rootURL.absoluteString)")
            loadRoot(webView)
            return
        }

        webView.evaluateJavaScript(Self.renderedContentCheckScript) { [weak self] result, error in
            guard let self else {
                return
            }
            if let error {
                PodsLog("Pods webview foreground health check failed: \(error.localizedDescription); reloading \(self.rootURL.absoluteString)")
                self.loadRoot(webView)
                return
            }
            if (result as? Bool) != true {
                PodsLog("Pods webview foreground content empty; reloading \(self.rootURL.absoluteString)")
                self.loadRoot(webView)
            } else {
                PodsDebugLog("Pods webview foreground content present")
            }
        }
    }

    private func isServingRoot(_ url: URL?) -> Bool {
        guard let url else {
            return false
        }
        return url.scheme == rootURL.scheme
            && url.host == rootURL.host
            && url.port == rootURL.port
    }

    private static let defaultScheduleDelayedWork: ScheduleDelayedWork = { work in
        let item = DispatchWorkItem {
            Task { @MainActor in
                work()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + activationRecheckDelay, execute: item)
        return {
            item.cancel()
        }
    }

    private static let renderedContentCheckScript = """
    (function() {
      var root = document.getElementById("root");
      if (!root) {
        return false;
      }
      if (root.childElementCount > 0) {
        return true;
      }
      return Boolean((root.textContent || "").trim());
    })();
    """
}

/// Maps UIKit/app lifecycle events onto recovery activation and cancellation.
@MainActor
final class PodsWebViewRecoveryLifecycle {
    private let recovery: PodsWebViewRecovery

    init(recovery: PodsWebViewRecovery) {
        self.recovery = recovery
    }

    func handleAppear(_ webView: PodsWebViewLoading) {
        recovery.handleActivation(webView)
    }

    func handleDisappear() {
        recovery.cancelPendingRecovery()
    }

    func handleBecomeActive(_ webView: PodsWebViewLoading) {
        recovery.handleActivation(webView)
    }
}

struct PodsWebView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> PodsWebViewController {
        PodsWebViewController()
    }

    func updateUIViewController(_ uiViewController: PodsWebViewController, context: Context) {}
}

final class PodsWebViewController: UIViewController {
    private static let localRootURL = URL(string: "http://127.0.0.1:18180/")!
    private static let retiredRemoteHost = "pods.mcgiv.dev"

    private var webView: WKWebView!
    private let recovery = PodsWebViewRecovery(rootURL: localRootURL)
    private lazy var recoveryLifecycle = PodsWebViewRecoveryLifecycle(recovery: recovery)

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        PodsDebugLog("Webview loadView configuring loopback API base")
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
        PodsDebugLog("Webview viewDidLoad")
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(feedRefreshCompleted),
            name: .podsFeedRefreshCompleted,
            object: nil
        )
        loadBundledWebApp()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        recoveryLifecycle.handleAppear(webView)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        recoveryLifecycle.handleDisappear()
    }

    private func loadBundledWebApp() {
        PodsLog("Pods webview loading \(Self.localRootURL.absoluteString)")
        recovery.loadRoot(webView)
    }

    @objc private func applicationDidBecomeActive() {
        recoveryLifecycle.handleBecomeActive(webView)
    }

    @objc private func feedRefreshCompleted() {
        DispatchQueue.main.async { [weak self] in
            self?.webView.evaluateJavaScript(
                "window.dispatchEvent(new Event('pods-episodes-changed'));",
                completionHandler: nil
            )
        }
    }

    private func redirectRetiredRemoteHostIfNeeded(_ url: URL) -> Bool {
        guard url.host?.lowercased() == Self.retiredRemoteHost else {
            return false
        }
        PodsLog("Pods webview blocked retired remote host \(url.absoluteString); loading \(Self.localRootURL.absoluteString)")
        webView.load(URLRequest(url: Self.localRootURL))
        return true
    }

    private static func navigationTypeName(_ type: WKNavigationType) -> String {
        switch type {
        case .linkActivated:
            return "linkActivated"
        case .formSubmitted:
            return "formSubmitted"
        case .backForward:
            return "backForward"
        case .reload:
            return "reload"
        case .formResubmitted:
            return "formResubmitted"
        case .other:
            return "other"
        @unknown default:
            return "unknown"
        }
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
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        PodsDebugLog(
            "Webview navigation policy url=\(url?.absoluteString ?? "nil") type=\(Self.navigationTypeName(navigationAction.navigationType)) mainFrame=\(navigationAction.targetFrame?.isMainFrame == true)"
        )
        if let url, redirectRetiredRemoteHostIfNeeded(url) {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        PodsLog("Pods webview finished \(webView.url?.absoluteString ?? "unknown URL")")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        PodsLog("Pods webview navigation failed: \(error)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        PodsLog("Pods webview provisional navigation failed: \(error)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        recovery.recoverFromWebContentTermination(webView)
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
