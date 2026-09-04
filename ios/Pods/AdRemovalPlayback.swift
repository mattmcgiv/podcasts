// DEPRECATED as of 1 October 2026. Do not review, extend, or append to this file.
// See ios/DEPRECATED.md.

import Foundation

struct AdSkipRange: Equatable {
    let id: String
    let startSegmentID: String
    let endSegmentID: String
    let startTime: Double
    let endTime: Double
    let confidence: Double
    let reason: String
    let classifierVersion: String
    let promptVersion: String
    let createdAt: Int64
    let disabled: Bool
}

struct AdCorrection: Equatable {
    let id: String
    let podcastID: Int64
    let sourceEpisodeID: Int64
    let transcriptWindow: String
    let classificationContext: String
    let classifierVersion: String
    let promptVersion: String
    let createdAt: Int64
    let active: Bool
}

struct AdRemovalSkipDecision: Equatable {
    let rangeID: String
    let rangeStart: Double
    let rangeEnd: Double

    var targetPosition: Double { rangeEnd }
    var skippedDuration: Double { rangeEnd - rangeStart }
}

struct AdRemovalMacSkipAttempt: Equatable {
    let token: UInt64
    let lifecycleToken: UInt64
    let decision: AdRemovalSkipDecision
    let startedAt: Date
    let attemptedAt: Date
    let attemptNumber: Int
}

enum AdRemovalMacSkipClockObservation: Equatable {
    case passThrough
    case suppress
    case completed(AdRemovalMacSkipAttempt)
}

enum AdRemovalMacSkipRetryTransition: Equatable {
    case retry(AdRemovalMacSkipAttempt)
    case exhausted(AdRemovalMacSkipAttempt)
    case ignored
}

enum AdRemovalMacSupersedingSeekObservation: Equatable {
    case suppress
    case acknowledged
    case settled
}

/// Fences clocks from a superseded automatic Mac seek while a user/Undo seek settles.
/// The Mac emits the requested target immediately, so one additional near-target clock
/// is required before the fence is removed; an older periodic clock can be queued between
/// those two observations.
struct AdRemovalMacSupersedingSeekFence: Equatable {
    let targetPosition: Double
    private(set) var acknowledged = false

    mutating func observe(
        position: Double,
        acknowledgementTolerance: Double = 1,
        settlementTolerance: Double = 3
    ) -> AdRemovalMacSupersedingSeekObservation {
        guard position.isFinite else { return .suppress }
        let distance = abs(position - targetPosition)
        if !acknowledged {
            guard distance <= max(0, acknowledgementTolerance) else {
                return .suppress
            }
            acknowledged = true
            return .acknowledged
        }
        guard distance <= max(0, settlementTolerance) else {
            return .suppress
        }
        return .settled
    }
}

/// Owns Mac-only automatic-seek acknowledgement, retry, and stale-clock fencing.
///
/// The Mac speaker can acknowledge a seek immediately and still have older periodic
/// clocks queued on the same connection. A completed range is therefore remembered
/// for the playback lifecycle, while its target remains a clock floor until an explicit
/// seek, disconnect, output switch, or other lifecycle boundary clears it.
struct AdRemovalMacSkipState: Equatable {
    private(set) var inFlight: AdRemovalMacSkipAttempt?
    private(set) var completedRangeIDs: Set<String> = []
    private(set) var terminalRangeIDs: Set<String> = []
    private(set) var staleClockFloor: Double?
    private var nextAttemptToken: UInt64 = 0

    mutating func begin(
        decision: AdRemovalSkipDecision,
        lifecycleToken: UInt64,
        now: Date
    ) -> AdRemovalMacSkipAttempt? {
        guard inFlight == nil,
              !completedRangeIDs.contains(decision.rangeID),
              !terminalRangeIDs.contains(decision.rangeID) else {
            return nil
        }
        nextAttemptToken &+= 1
        let attempt = AdRemovalMacSkipAttempt(
            token: nextAttemptToken,
            lifecycleToken: lifecycleToken,
            decision: decision,
            startedAt: now,
            attemptedAt: now,
            attemptNumber: 1
        )
        inFlight = attempt
        return attempt
    }

    mutating func observe(
        position: Double,
        lifecycleToken: UInt64,
        acknowledgementTolerance: Double = 1
    ) -> AdRemovalMacSkipClockObservation {
        guard position.isFinite else {
            return inFlight == nil ? .passThrough : .suppress
        }
        if let attempt = inFlight,
           attempt.lifecycleToken == lifecycleToken {
            let overshoot = position - attempt.decision.targetPosition
            guard overshoot >= 0,
                  overshoot <= max(0, acknowledgementTolerance) else {
                return .suppress
            }
            inFlight = nil
            completedRangeIDs.insert(attempt.decision.rangeID)
            staleClockFloor = max(staleClockFloor ?? 0, attempt.decision.targetPosition)
            return .completed(attempt)
        }
        if let floor = staleClockFloor {
            if position < floor {
                return .suppress
            }
        }
        return .passThrough
    }

    mutating func retry(
        attemptToken: UInt64,
        lifecycleToken: UInt64,
        now: Date,
        maximumAttempts: Int
    ) -> AdRemovalMacSkipRetryTransition {
        guard let current = inFlight,
              current.token == attemptToken,
              current.lifecycleToken == lifecycleToken else {
            return .ignored
        }
        guard current.attemptNumber < max(1, maximumAttempts) else {
            inFlight = nil
            terminalRangeIDs.insert(current.decision.rangeID)
            return .exhausted(current)
        }
        nextAttemptToken &+= 1
        let retry = AdRemovalMacSkipAttempt(
            token: nextAttemptToken,
            lifecycleToken: lifecycleToken,
            decision: current.decision,
            startedAt: current.startedAt,
            attemptedAt: now,
            attemptNumber: current.attemptNumber + 1
        )
        inFlight = retry
        return .retry(retry)
    }

    func acceptsDelivery(attemptToken: UInt64, lifecycleToken: UInt64) -> Bool {
        guard let inFlight else { return false }
        return inFlight.token == attemptToken && inFlight.lifecycleToken == lifecycleToken
    }

    mutating func invalidate() {
        inFlight = nil
        completedRangeIDs = []
        terminalRangeIDs = []
        staleClockFloor = nil
    }
}

struct AdRemovalSkipLifecycle: Equatable {
    private(set) var generation: UInt64 = 0

    mutating func invalidate() {
        generation &+= 1
    }

    func accepts(_ token: UInt64) -> Bool {
        token == generation
    }
}

enum AdRemovalSkipPolicy {
    static func decision(position: Double, ranges: [AdSkipRange]) -> AdRemovalSkipDecision? {
        guard position.isFinite, position >= 0 else { return nil }
        guard let range = ranges.first(where: {
            !$0.disabled && position >= $0.startTime && position < $0.endTime
        }) else {
            return nil
        }
        return AdRemovalSkipDecision(
            rangeID: range.id,
            rangeStart: range.startTime,
            rangeEnd: range.endTime
        )
    }
}

struct AdRemovalSkipSession {
    private(set) var ranges: [AdSkipRange]
    private(set) var pending: AdRemovalSkipDecision?

    init(ranges: [AdSkipRange] = []) {
        self.ranges = ranges
    }

    mutating func replaceRanges(_ ranges: [AdSkipRange]) {
        self.ranges = ranges
        if let pending, ranges.first(where: { $0.id == pending.rangeID })?.disabled != false {
            self.pending = nil
        }
    }

    @discardableResult
    mutating func enter(position: Double) -> AdRemovalSkipDecision? {
        AdRemovalSkipPolicy.decision(position: position, ranges: ranges)
    }

    mutating func enterMacTransportEvent(type: String, position: Double) -> AdRemovalSkipDecision? {
        guard type == "timeupdate" else { return nil }
        return enter(position: position)
    }

    mutating func didComplete(_ decision: AdRemovalSkipDecision) {
        guard ranges.first(where: { $0.id == decision.rangeID })?.disabled == false else {
            return
        }
        pending = decision
    }

    mutating func didUndo(rangeID: String) {
        ranges = ranges.map { range in
            guard range.id == rangeID else { return range }
            return AdSkipRange(
                id: range.id,
                startSegmentID: range.startSegmentID,
                endSegmentID: range.endSegmentID,
                startTime: range.startTime,
                endTime: range.endTime,
                confidence: range.confidence,
                reason: range.reason,
                classifierVersion: range.classifierVersion,
                promptVersion: range.promptVersion,
                createdAt: range.createdAt,
                disabled: true
            )
        }
        if pending?.rangeID == rangeID {
            pending = nil
        }
    }

    mutating func clear() {
        ranges = []
        pending = nil
    }
}

struct AdRemovalDownloadedEpisode: Equatable {
    let episodeID: Int64
    let podcastID: Int64
    let audioURL: URL
    let originalDuration: Double?
    let ranges: [AdSkipRange]
    let manifestReady: Bool
}

enum AdRemovalPlaybackSourcePolicy {
    static func localSource(publisher: URL, downloaded: AdRemovalDownloadedEpisode?) -> URL {
        downloaded?.audioURL ?? publisher
    }

    static func macSource(
        publisher: URL,
        downloaded: AdRemovalDownloadedEpisode?,
        authenticatedStream: URL?
    ) -> URL? {
        downloaded == nil ? publisher : authenticatedStream
    }
}

struct AdRemovalUndoResult: Equatable {
    let disabledRangeID: String
    let seekPosition: Double
    let correction: AdCorrection
}

protocol AdRemovalPlaybackProviding: AnyObject {
    func downloadedEpisode(episodeID: Int64) throws -> AdRemovalDownloadedEpisode?
    func undoSkip(episodeID: Int64, rangeID: String) throws -> AdRemovalUndoResult
}


