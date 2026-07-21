import Foundation

enum RefreshSource: String {
    case manual
    case foreground
    case background
}

enum FeedRefreshPolicy {
    /// At most two automatic complete-feed passes per day. Manual refreshes bypass this.
    static let automaticInterval: TimeInterval = 12 * 60 * 60
    static let retryInterval: TimeInterval = 2 * 60 * 60
    /// A single stalled publisher must not hold the serial refresh pass open.
    static let feedRequestTimeout: TimeInterval = 15

    static func isForegroundRefreshDue(status: RefreshStatus, now: Date = Date()) -> Bool {
        if status.last_errors > 0, let lastAttempt = status.last_attempt_at {
            return now.timeIntervalSince1970 >= TimeInterval(lastAttempt) + retryInterval
        }
        guard let lastSuccess = status.last_success_at else {
            return true
        }
        return now.timeIntervalSince1970 >= TimeInterval(lastSuccess) + automaticInterval
    }

    static func nextBackgroundRefreshDate(status: RefreshStatus, now: Date = Date()) -> Date {
        if status.last_errors > 0, let lastAttempt = status.last_attempt_at {
            return max(now, Date(timeIntervalSince1970: TimeInterval(lastAttempt) + retryInterval))
        }
        guard let lastSuccess = status.last_success_at else {
            return now
        }
        return max(now, Date(timeIntervalSince1970: TimeInterval(lastSuccess) + automaticInterval))
    }
}

/// Bridges UIKit lifecycle notifications to a refresh handler that may not yet
/// exist during cold launch. Activations received while a refresh is already
/// running join that pass, so duplicate cold-start notifications cannot cause
/// a second full feed pass.
@MainActor
final class ForegroundFeedRefreshLifecycle {
    typealias RefreshHandler = () async -> RefreshResult

    private var refreshHandler: RefreshHandler?
    private var refreshRequested = false
    private var activeGeneration: UInt = 0
    private var activeRefreshGeneration: UInt?

    func applicationDidBecomeActive() {
        guard activeRefreshGeneration == nil else { return }
        refreshRequested = true
        startRefreshIfPossible()
    }

    func install(_ handler: @escaping RefreshHandler) {
        refreshHandler = handler
        startRefreshIfPossible()
    }

    private func startRefreshIfPossible() {
        guard refreshRequested,
              activeRefreshGeneration == nil,
              let refreshHandler else { return }

        refreshRequested = false
        activeGeneration &+= 1
        let generation = activeGeneration
        activeRefreshGeneration = generation
        Task { [weak self] in
            _ = await refreshHandler()
            await MainActor.run {
                guard self?.activeRefreshGeneration == generation else { return }
                self?.activeRefreshGeneration = nil
                self?.startRefreshIfPossible()
            }
        }
    }
}

/// The single automatic-refresh gate for foreground, background, and manual callers.
/// It keeps one native request in flight so the same feeds are never fetched twice at once.
actor FeedRefreshCoordinator {
    private let backend: PodsBackend
    private var inFlight: Task<RefreshResult, Never>?

    init(backend: PodsBackend) {
        self.backend = backend
    }

    func refreshIfDue(now: Date = Date()) async -> RefreshResult? {
        guard FeedRefreshPolicy.isForegroundRefreshDue(status: backend.refreshStatus(), now: now) else {
            return nil
        }
        return await refreshNow(source: .foreground)
    }

    /// A user foregrounding Pods is an explicit request for current feeds.
    /// The shared in-flight task still coalesces overlapping lifecycle events.
    func refreshWhenForegrounded() async -> RefreshResult {
        await refreshNow(source: .foreground)
    }

    func refreshNow(source: RefreshSource) async -> RefreshResult {
        if let inFlight {
            return await inFlight.value
        }

        let work = Task { [backend] in
            await backend.performRefresh(source: source)
        }
        inFlight = work
        let result = await withTaskCancellationHandler(
            operation: { await work.value },
            onCancel: { work.cancel() }
        )
        inFlight = nil
        return result
    }

    func nextBackgroundRefreshDate(now: Date = Date()) -> Date {
        FeedRefreshPolicy.nextBackgroundRefreshDate(status: backend.refreshStatus(), now: now)
    }
}

extension Notification.Name {
    static let podsFeedRefreshStateChanged = Notification.Name("dev.mcgiv.pods.feed-refresh-state-changed")
    static let podsFeedRefreshCompleted = Notification.Name("dev.mcgiv.pods.feed-refresh-completed")
}
