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

enum PodsBootDocument {
    private static let tokenQueryName = "pods_boot"

    static func url(rootURL: URL, token: String) -> URL? {
        guard var components = URLComponents(url: rootURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == tokenQueryName }
        queryItems.append(URLQueryItem(name: tokenQueryName, value: token))
        components.queryItems = queryItems
        return components.url
    }

    static func matches(_ url: URL?, rootURL: URL, token: String) -> Bool {
        guard let url, isLocalOrigin(url, rootURL: rootURL) else {
            return false
        }
        let values = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .filter { $0.name == tokenQueryName }
            .compactMap(\.value) ?? []
        return values == [token]
    }

    static func isLocalOrigin(_ url: URL, rootURL: URL) -> Bool {
        url.scheme?.lowercased() == rootURL.scheme?.lowercased()
            && url.host?.lowercased() == rootURL.host?.lowercased()
            && url.port == rootURL.port
    }
}

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

/// Coordinates the two dependencies that must both succeed before the native
/// recovery surface can be removed: the loopback server and the React UI.
@MainActor
final class PodsWebViewBootRecovery {
    enum State: Equatable {
        case idle
        case recovering
        case waitingForUI
        case ready
        case failed(String)
    }

    typealias EnsureServerReady = @MainActor () async throws -> Void
    typealias LoadRoot = @MainActor () -> Void
    typealias StateDidChange = @MainActor (State) -> Void

    private let ensureServerReady: EnsureServerReady
    private let loadRoot: LoadRoot
    private let stateDidChange: StateDidChange
    private var generation: UInt = 0

    private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            stateDidChange(state)
        }
    }

    init(
        ensureServerReady: @escaping EnsureServerReady,
        loadRoot: @escaping LoadRoot,
        stateDidChange: @escaping StateDidChange = { _ in }
    ) {
        self.ensureServerReady = ensureServerReady
        self.loadRoot = loadRoot
        self.stateDidChange = stateDidChange
    }

    func recover(reason: String) async {
        generation &+= 1
        let currentGeneration = generation
        state = .recovering
        PodsLog("Pods boot recovery started reason=\(reason)")
        do {
            try await ensureServerReady()
            try Task.checkCancellation()
            guard generation == currentGeneration else { return }
            loadRoot()
            state = .waitingForUI
        } catch is CancellationError {
            return
        } catch {
            guard generation == currentGeneration else { return }
            state = .failed(error.localizedDescription)
            PodsLog("Pods boot recovery failed reason=\(reason) error=\(error.localizedDescription)")
        }
    }

    func beginVisibleRecovery() {
        generation &+= 1
        state = .recovering
    }

    func markUIReady() {
        generation &+= 1
        state = .ready
    }

    func markUIFailed(_ message: String) {
        generation &+= 1
        state = .failed(message)
    }

    func cancel() {
        generation &+= 1
    }
}

@MainActor
final class PodsWebViewHealthCheckFence {
    struct Attempt: Equatable {
        fileprivate let generation: UInt
        fileprivate let token: String
        fileprivate let webViewID: ObjectIdentifier
    }

    typealias ScheduleTimeout = (_ work: @escaping @MainActor () -> Void) -> (() -> Void)

    private let scheduleTimeout: ScheduleTimeout
    private var generation: UInt = 0
    private var cancelTimeout: (() -> Void)?

    init(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        scheduleTimeout: ScheduleTimeout? = nil
    ) {
        self.scheduleTimeout = scheduleTimeout ?? { work in
            let task = Task { @MainActor in
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                } catch {
                    return
                }
                work()
            }
            return { task.cancel() }
        }
    }

    func begin(
        token: String,
        webViewID: ObjectIdentifier,
        onTimeout: @escaping @MainActor () -> Void
    ) -> Attempt {
        cancel()
        let attempt = Attempt(generation: generation, token: token, webViewID: webViewID)
        cancelTimeout = scheduleTimeout { [weak self] in
            guard let self, self.generation == attempt.generation else { return }
            self.finishCurrentAttempt()
            onTimeout()
        }
        return attempt
    }

    func accept(
        _ attempt: Attempt,
        currentToken: String?,
        currentWebViewID: ObjectIdentifier
    ) -> Bool {
        guard generation == attempt.generation,
              currentToken == attempt.token,
              currentWebViewID == attempt.webViewID else {
            return false
        }
        finishCurrentAttempt()
        return true
    }

    func cancel() {
        generation &+= 1
        cancelTimeout?()
        cancelTimeout = nil
    }

    private func finishCurrentAttempt() {
        generation &+= 1
        cancelTimeout?()
        cancelTimeout = nil
    }
}

enum PodsWebViewActivationPolicy {
    enum Action: Equatable {
        case verifyReadyUI
        case beginRecovery(resetAttempts: Bool)
        case none
    }

    static func action(
        state: PodsWebViewBootRecovery.State,
        recoveryAttempt: Int,
        maximumAttempts: Int
    ) -> Action {
        switch state {
        case .idle:
            return .beginRecovery(resetAttempts: true)
        case .ready:
            return .verifyReadyUI
        case .failed where recoveryAttempt < maximumAttempts:
            return .beginRecovery(resetAttempts: false)
        case .recovering, .waitingForUI, .failed:
            return .none
        }
    }
}

private enum PodsUIReadyMarker {
    private static func markerURL(createDirectory: Bool) throws -> URL {
        let directory = try FileManager.default
            .url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: createDirectory
            )
            .appendingPathComponent("Pods", isDirectory: true)
        if createDirectory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent("ui-ready.txt")
    }

    static var buildID: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "PodsBuildID") as? String
        if let value, !value.isEmpty, value != "$(PODS_BUILD_ID)" {
            return value
        }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }

    static var refreshNonce: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "PodsRefreshNonce") as? String
        if let value, !value.isEmpty, value != "$(PODS_REFRESH_NONCE)" {
            return value
        }
        return "unknown"
    }

    static func record(now: Date = Date()) throws {
        let epoch = Int(now.timeIntervalSince1970)
        try Data("\(epoch) \(buildID) \(refreshNonce)\n".utf8)
            .write(to: markerURL(createDirectory: true), options: .atomic)
    }

    static func invalidate() {
        do {
            let url = try markerURL(createDirectory: false)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            PodsLog("Pods ui-ready marker invalidation failed: \(error.localizedDescription)")
        }
    }
}

private final class PodsLifecycleMessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: PodsWebViewController?

    init(owner: PodsWebViewController) {
        self.owner = owner
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let event = (message.body as? [String: Any])?["event"] as? String
        let sourceURL = message.frameInfo.request.url
        let sourceWebViewID = message.webView.map(ObjectIdentifier.init)
        let isMainFrame = message.frameInfo.isMainFrame
        Task { @MainActor [weak self] in
            self?.owner?.handleLifecycleEvent(
                event,
                sourceURL: sourceURL,
                sourceWebViewID: sourceWebViewID,
                isMainFrame: isMainFrame
            )
        }
    }
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
    let appDelegate: AppDelegate

    func makeUIViewController(context: Context) -> PodsWebViewController {
        PodsWebViewController(appDelegate: appDelegate)
    }

    func updateUIViewController(_ uiViewController: PodsWebViewController, context: Context) {}
}

final class PodsWebViewController: UIViewController {
    private static let localRootURL = URL(string: "http://127.0.0.1:18180/?ui=progress-v1")!
    private static let retiredRemoteHost = "pods.mcgiv.dev"
    private static let maximumAutomaticRecoveryAttempts = 3
    private static let uiReadyTimeoutNanoseconds: UInt64 = 8_000_000_000

    private var webView: WKWebView!
    private let containerView = UIView()
    private let recoveryOverlay = UIView()
    private let recoverySpinner = UIActivityIndicatorView(style: .large)
    private let recoveryLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private var lifecycleMessageHandler: PodsLifecycleMessageHandler?
    private var recoveryTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var uiReadyTimeoutTask: Task<Void, Never>?
    private var uiReadyValidationTask: Task<Void, Never>?
    private var foregroundHealthTask: Task<Void, Never>?
    private let uiHealthCheckFence = PodsWebViewHealthCheckFence()
    private var recoveryWasCancelledForDisappearance = false
    private var recoveryAttempt = 0
    private var currentBootToken: String?
    private let appDelegate: AppDelegate
    private let recovery = PodsWebViewRecovery(rootURL: localRootURL)
    private lazy var bootRecovery = PodsWebViewBootRecovery(
        ensureServerReady: { [weak self] in
            guard let self else {
                throw NSError(
                    domain: "dev.mcgiv.pods.webview-recovery",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Pods app services are unavailable"]
                )
            }
            _ = try await self.appDelegate.ensureLocalServerReady()
        },
        loadRoot: { [weak self] in
            self?.loadBundledWebAppNow()
        },
        stateDidChange: { [weak self] state in
            self?.renderBootState(state)
        }
    )

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        recoveryTask?.cancel()
        retryTask?.cancel()
        uiReadyTimeoutTask?.cancel()
        uiReadyValidationTask?.cancel()
        foregroundHealthTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        PodsDebugLog("Webview loadView configuring loopback API base")
        containerView.backgroundColor = UIColor(red: 11 / 255, green: 13 / 255, blue: 16 / 255, alpha: 1)
        view = containerView
        installWebView()
        installRecoveryOverlay()
    }

    private func installWebView(replacing existingWebView: WKWebView? = nil) {
        if let existingWebView {
            existingWebView.stopLoading()
            existingWebView.navigationDelegate = nil
            existingWebView.configuration.userContentController.removeScriptMessageHandler(forName: "podsAudio")
            existingWebView.configuration.userContentController.removeScriptMessageHandler(forName: "podsLog")
            existingWebView.configuration.userContentController.removeScriptMessageHandler(forName: "podsLifecycle")
            existingWebView.removeFromSuperview()
        }

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
        let lifecycleMessageHandler = PodsLifecycleMessageHandler(owner: self)
        config.userContentController.add(lifecycleMessageHandler, name: "podsLifecycle")
        self.lifecycleMessageHandler = lifecycleMessageHandler

        let nextWebView = WKWebView(frame: .zero, configuration: config)
        nextWebView.navigationDelegate = self
        nextWebView.isOpaque = false
        nextWebView.backgroundColor = containerView.backgroundColor
        nextWebView.scrollView.backgroundColor = containerView.backgroundColor
        nextWebView.underPageBackgroundColor = containerView.backgroundColor
        nextWebView.scrollView.contentInsetAdjustmentBehavior = .never
        nextWebView.translatesAutoresizingMaskIntoConstraints = false
        containerView.insertSubview(nextWebView, at: 0)
        NSLayoutConstraint.activate([
            nextWebView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            nextWebView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            nextWebView.topAnchor.constraint(equalTo: containerView.topAnchor),
            nextWebView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])
        webView = nextWebView
        AudioBridge.shared.attach(webView: nextWebView)
    }

    private func installRecoveryOverlay() {
        recoveryOverlay.translatesAutoresizingMaskIntoConstraints = false
        recoveryOverlay.backgroundColor = UIColor(red: 11 / 255, green: 13 / 255, blue: 16 / 255, alpha: 1)
        recoveryOverlay.accessibilityIdentifier = "pods-native-recovery"

        recoveryLabel.text = "Starting Pods…"
        recoveryLabel.textColor = UIColor(red: 232 / 255, green: 236 / 255, blue: 241 / 255, alpha: 1)
        recoveryLabel.font = .preferredFont(forTextStyle: .body)
        recoveryLabel.textAlignment = .center
        recoveryLabel.numberOfLines = 0

        recoverySpinner.color = UIColor(red: 79 / 255, green: 156 / 255, blue: 249 / 255, alpha: 1)
        recoverySpinner.startAnimating()

        retryButton.setTitle("Retry", for: .normal)
        retryButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        retryButton.accessibilityIdentifier = "pods-native-retry"
        retryButton.addTarget(self, action: #selector(retryBoot), for: .touchUpInside)
        retryButton.isHidden = true

        let stack = UIStackView(arrangedSubviews: [recoverySpinner, recoveryLabel, retryButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        recoveryOverlay.addSubview(stack)
        containerView.addSubview(recoveryOverlay)
        NSLayoutConstraint.activate([
            recoveryOverlay.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            recoveryOverlay.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            recoveryOverlay.topAnchor.constraint(equalTo: containerView.topAnchor),
            recoveryOverlay.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: recoveryOverlay.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: recoveryOverlay.trailingAnchor, constant: -24),
            stack.centerXAnchor.constraint(equalTo: recoveryOverlay.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: recoveryOverlay.centerYAnchor)
        ])
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
        beginBootRecovery(reason: "initial-load", resetAttempts: true)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        recoveryWasCancelledForDisappearance = true
        recovery.cancelPendingRecovery()
        recoveryTask?.cancel()
        retryTask?.cancel()
        uiReadyTimeoutTask?.cancel()
        uiReadyValidationTask?.cancel()
        foregroundHealthTask?.cancel()
        uiHealthCheckFence.cancel()
        bootRecovery.cancel()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard recoveryWasCancelledForDisappearance else { return }
        recoveryWasCancelledForDisappearance = false
        if bootRecovery.state == .ready {
            applicationDidBecomeActive()
        } else {
            beginBootRecovery(reason: "view-appeared", resetAttempts: bootRecovery.state == .idle)
        }
    }

    private func loadBundledWebAppNow() {
        let token = UUID().uuidString.lowercased()
        guard let url = PodsBootDocument.url(rootURL: Self.localRootURL, token: token) else {
            bootRecovery.markUIFailed("Pods could not construct its local UI address.")
            return
        }
        currentBootToken = token
        PodsLog("Pods webview loading \(url.absoluteString)")
        webView.load(URLRequest(url: url))
    }

    @objc private func applicationDidBecomeActive() {
        switch PodsWebViewActivationPolicy.action(
            state: bootRecovery.state,
            recoveryAttempt: recoveryAttempt,
            maximumAttempts: Self.maximumAutomaticRecoveryAttempts
        ) {
        case .beginRecovery(let resetAttempts):
            beginBootRecovery(reason: "became-active-before-ready", resetAttempts: resetAttempts)
            return
        case .none:
            PodsDebugLog("Pods webview activation joined active recovery")
            return
        case .verifyReadyUI:
            break
        }

        guard let expectedToken = currentBootToken else {
            beginBootRecovery(reason: "foreground-missing-boot-token", resetAttempts: true)
            return
        }
        let expectedWebView = webView!
        bootRecovery.beginVisibleRecovery()
        PodsUIReadyMarker.invalidate()
        foregroundHealthTask?.cancel()
        uiHealthCheckFence.cancel()
        foregroundHealthTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let restarted = try await self.appDelegate.ensureLocalServerReady()
                guard !Task.isCancelled,
                      self.bootRecovery.state == .recovering,
                      self.currentBootToken == expectedToken,
                      self.webView === expectedWebView else { return }
                if restarted {
                    self.beginBootRecovery(reason: "foreground-server-restarted", resetAttempts: false)
                    return
                }
                self.validateRenderedUI(
                    expectedToken: expectedToken,
                    expectedWebView: expectedWebView,
                    expectedState: .recovering,
                    failureReason: "foreground-ui-not-ready"
                ) { [weak self] in
                    self?.finishUIReady()
                }
            } catch {
                guard !Task.isCancelled,
                      self.bootRecovery.state == .recovering,
                      self.currentBootToken == expectedToken,
                      self.webView === expectedWebView else { return }
                self.beginBootRecovery(reason: "foreground-server-unavailable", resetAttempts: false)
            }
        }
    }

    @objc private func retryBoot() {
        recoveryAttempt = 0
        beginBootRecovery(reason: "user-retry", resetAttempts: false)
    }

    private func beginBootRecovery(reason: String, resetAttempts: Bool) {
        if resetAttempts && (bootRecovery.state == .idle || bootRecovery.state == .ready) {
            recoveryAttempt = 0
        }
        currentBootToken = nil
        PodsUIReadyMarker.invalidate()
        bootRecovery.beginVisibleRecovery()
        recoveryTask?.cancel()
        retryTask?.cancel()
        uiReadyTimeoutTask?.cancel()
        uiReadyValidationTask?.cancel()
        foregroundHealthTask?.cancel()
        uiHealthCheckFence.cancel()
        guard recoveryAttempt < Self.maximumAutomaticRecoveryAttempts else {
            bootRecovery.markUIFailed("Pods could not restore its local server. Tap Retry to try again.")
            return
        }

        recoveryAttempt += 1
        if recoveryAttempt > 1 {
            PodsLog("Pods webview replacing content process recovery_attempt=\(recoveryAttempt)")
            installWebView(replacing: webView)
        }
        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.bootRecovery.recover(reason: reason)
            guard !Task.isCancelled else { return }
            switch self.bootRecovery.state {
            case .waitingForUI:
                self.startUIReadyTimeout(reason: reason)
            case .failed:
                self.scheduleAutomaticRecovery(after: reason)
            default:
                break
            }
        }
    }

    private func startUIReadyTimeout(reason: String) {
        uiReadyTimeoutTask?.cancel()
        uiReadyTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.uiReadyTimeoutNanoseconds)
            } catch {
                return
            }
            guard let self, self.bootRecovery.state == .waitingForUI else { return }
            self.bootRecovery.markUIFailed("Pods UI did not become ready in time.")
            self.scheduleAutomaticRecovery(after: "\(reason)-ui-timeout")
        }
    }

    private func scheduleAutomaticRecovery(after reason: String) {
        guard recoveryAttempt < Self.maximumAutomaticRecoveryAttempts else { return }
        let delay: UInt64 = recoveryAttempt == 1 ? 250_000_000 : 750_000_000
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            self?.beginBootRecovery(reason: "\(reason)-retry", resetAttempts: false)
        }
    }

    private func renderBootState(_ state: PodsWebViewBootRecovery.State) {
        switch state {
        case .idle, .recovering:
            recoveryOverlay.isHidden = false
            recoveryLabel.text = "Recovering Pods…"
            retryButton.isHidden = true
            recoverySpinner.startAnimating()
        case .waitingForUI:
            recoveryOverlay.isHidden = false
            recoveryLabel.text = "Starting Pods…"
            retryButton.isHidden = true
            recoverySpinner.startAnimating()
        case .ready:
            recoveryOverlay.isHidden = true
            recoverySpinner.stopAnimating()
            retryButton.isHidden = true
        case .failed(let message):
            recoveryOverlay.isHidden = false
            recoveryLabel.text = message
            retryButton.isHidden = recoveryAttempt < Self.maximumAutomaticRecoveryAttempts
            if retryButton.isHidden {
                recoverySpinner.startAnimating()
            } else {
                recoverySpinner.stopAnimating()
            }
        }
    }

    fileprivate func handleLifecycleEvent(
        _ event: String?,
        sourceURL: URL?,
        sourceWebViewID: ObjectIdentifier?,
        isMainFrame: Bool
    ) {
        guard let event else {
            PodsLog("Pods lifecycle bridge ignored malformed message")
            return
        }
        guard isMainFrame,
              sourceWebViewID == ObjectIdentifier(webView),
              let currentBootToken,
              PodsBootDocument.matches(sourceURL, rootURL: Self.localRootURL, token: currentBootToken) else {
            PodsLog("Pods lifecycle bridge ignored stale or untrusted event=\(event)")
            return
        }
        switch event {
        case "ui-ready":
            guard bootRecovery.state == .waitingForUI else {
                PodsLog("Pods lifecycle bridge ignored ui-ready outside waiting state")
                return
            }
            validateServerAndAcceptUIReady(expectedToken: currentBootToken)
        case "ui-failed":
            guard bootRecovery.state == .recovering
                    || bootRecovery.state == .waitingForUI
                    || bootRecovery.state == .ready else {
                PodsLog("Pods lifecycle bridge ignored ui-failed outside active document state")
                return
            }
            PodsUIReadyMarker.invalidate()
            beginBootRecovery(reason: "react-failure", resetAttempts: bootRecovery.state == .ready)
        default:
            PodsLog("Pods lifecycle bridge ignored event=\(event)")
        }
    }

    private func validateServerAndAcceptUIReady(expectedToken: String) {
        let expectedWebView = webView!
        uiReadyValidationTask?.cancel()
        uiReadyValidationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let restarted = try await self.appDelegate.ensureLocalServerReady()
                guard !Task.isCancelled,
                      self.bootRecovery.state == .waitingForUI,
                      self.currentBootToken == expectedToken,
                      self.webView === expectedWebView else { return }
                if restarted {
                    self.beginBootRecovery(reason: "ui-ready-server-restarted", resetAttempts: false)
                } else {
                    self.validateRenderedUI(
                        expectedToken: expectedToken,
                        expectedWebView: expectedWebView,
                        expectedState: .waitingForUI,
                        failureReason: "ui-ready-ui-not-ready"
                    ) { [weak self] in
                        self?.finishUIReady()
                    }
                }
            } catch {
                guard !Task.isCancelled,
                      self.bootRecovery.state == .waitingForUI,
                      self.currentBootToken == expectedToken,
                      self.webView === expectedWebView else { return }
                self.beginBootRecovery(reason: "ui-ready-server-unavailable", resetAttempts: false)
            }
        }
    }

    private func validateRenderedUI(
        expectedToken: String,
        expectedWebView: WKWebView,
        expectedState: PodsWebViewBootRecovery.State,
        failureReason: String,
        onReady: @escaping @MainActor () -> Void
    ) {
        let attempt = uiHealthCheckFence.begin(
            token: expectedToken,
            webViewID: ObjectIdentifier(expectedWebView)
        ) { [weak self, weak expectedWebView] in
            guard let self, let expectedWebView,
                  self.bootRecovery.state == expectedState,
                  self.currentBootToken == expectedToken,
                  self.webView === expectedWebView else { return }
            self.beginBootRecovery(reason: "\(failureReason)-timeout", resetAttempts: false)
        }
        expectedWebView.evaluateJavaScript(Self.uiReadyHealthCheckScript) { [weak self, weak expectedWebView] result, error in
            guard let self, let expectedWebView,
                  self.bootRecovery.state == expectedState,
                  self.webView === expectedWebView,
                  self.uiHealthCheckFence.accept(
                    attempt,
                    currentToken: self.currentBootToken,
                    currentWebViewID: ObjectIdentifier(self.webView)
                  ) else { return }
            if error != nil || (result as? Bool) != true {
                self.beginBootRecovery(reason: failureReason, resetAttempts: false)
            } else {
                onReady()
            }
        }
    }

    private func finishUIReady() {
        recoveryAttempt = 0
        retryTask?.cancel()
        uiReadyTimeoutTask?.cancel()
        uiHealthCheckFence.cancel()
        bootRecovery.markUIReady()
        do {
            try PodsUIReadyMarker.record()
            PodsLog("Pods ui ready build_id=\(PodsUIReadyMarker.buildID)")
        } catch {
            PodsLog("Pods ui-ready marker failed: \(error.localizedDescription)")
        }
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
        PodsLog("Pods webview blocked retired remote host \(url.absoluteString); recovering local UI")
        beginBootRecovery(reason: "retired-remote-host", resetAttempts: true)
        return true
    }

    private func handleNavigationFailure(_ error: Error, stage: String) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            PodsDebugLog("Pods webview ignored cancelled \(stage) navigation")
            return
        }
        PodsLog("Pods webview \(stage) navigation failed: \(error)")
        currentBootToken = nil
        PodsUIReadyMarker.invalidate()
        uiReadyTimeoutTask?.cancel()
        bootRecovery.markUIFailed("Pods could not load its local UI.")
        scheduleAutomaticRecovery(after: "\(stage)-navigation-failure")
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

    private static let uiReadyHealthCheckScript = """
    (function() {
      if (window.__PODS_UI_READY !== true) {
        return false;
      }
      var root = document.getElementById("root");
      if (!root) {
        return false;
      }
      return root.childElementCount > 0 || Boolean((root.textContent || "").trim());
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
        if let url, !PodsBootDocument.isLocalOrigin(url, rootURL: Self.localRootURL) {
            let isMainFrame = navigationAction.targetFrame?.isMainFrame != false
            PodsLog("Pods webview blocked external navigation url=\(url.absoluteString) mainFrame=\(isMainFrame)")
            if isMainFrame && navigationAction.navigationType == .linkActivated {
                UIApplication.shared.open(url)
            } else if isMainFrame {
                beginBootRecovery(reason: "blocked-external-navigation", resetAttempts: true)
            }
            decisionHandler(.cancel)
            return
        }
        if let url, navigationAction.targetFrame?.isMainFrame != false {
            guard let currentBootToken,
                  PodsBootDocument.matches(url, rootURL: Self.localRootURL, token: currentBootToken) else {
                PodsLog("Pods webview blocked unexpected local main-frame navigation url=\(url.absoluteString)")
                beginBootRecovery(reason: "unexpected-local-navigation", resetAttempts: true)
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        PodsLog("Pods webview finished \(webView.url?.absoluteString ?? "unknown URL")")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else {
            PodsDebugLog("Pods webview ignored stale committed navigation failure")
            return
        }
        handleNavigationFailure(error, stage: "committed")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else {
            PodsDebugLog("Pods webview ignored stale provisional navigation failure")
            return
        }
        handleNavigationFailure(error, stage: "provisional")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else {
            PodsDebugLog("Pods webview ignored stale content-process termination")
            return
        }
        PodsLog("Pods webview content process terminated; recovering server and UI")
        beginBootRecovery(reason: "web-content-terminated", resetAttempts: true)
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
