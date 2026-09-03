import Foundation

enum RefreshSource: String {
    case manual
    case foreground
    case background
}

enum FeedRefreshPolicy {
    static let automaticInterval: TimeInterval = 12 * 60 * 60
    static let retryInterval: TimeInterval = 2 * 60 * 60
    static let feedRequestTimeout: TimeInterval = 15

    static func isForegroundRefreshDue(status: LoopbackRefreshStatus, now: Date = Date()) -> Bool {
        if status.last_errors > 0, let lastAttempt = status.last_attempt_at {
            return now.timeIntervalSince1970 >= TimeInterval(lastAttempt) + retryInterval
        }
        guard let lastSuccess = status.last_success_at else {
            return true
        }
        return now.timeIntervalSince1970 >= TimeInterval(lastSuccess) + automaticInterval
    }
}

struct LoopbackRefreshStatus: Codable {
    var last_attempt_at: Int64?
    var last_success_at: Int64?
    var last_source: String?
    var last_refreshed: Int64
    var last_errors: Int64
}

struct LoopbackRefreshResult: Codable {
    var refreshed: Int64
    var errors: Int64
}

@MainActor
final class ForegroundFeedRefreshLifecycle {
    typealias RefreshHandler = () async -> LoopbackRefreshResult

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

actor LoopbackRefreshCoordinator {
    func refreshWhenForegrounded() async -> LoopbackRefreshResult {
        await refreshNow(source: "foreground")
    }

    func refreshNow(source: String) async -> LoopbackRefreshResult {
        guard let url = URL(string: "http://127.0.0.1:18180/api/refresh") else {
            return LoopbackRefreshResult(refreshed: 0, errors: 1)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return try JSONDecoder().decode(LoopbackRefreshResult.self, from: data)
        } catch {
            return LoopbackRefreshResult(refreshed: 0, errors: 1)
        }
    }
}

extension Notification.Name {
    static let podsFeedRefreshStateChanged = Notification.Name("dev.mcgiv.pods.feed-refresh-state-changed")
    static let podsFeedRefreshCompleted = Notification.Name("dev.mcgiv.pods.feed-refresh-completed")
}
