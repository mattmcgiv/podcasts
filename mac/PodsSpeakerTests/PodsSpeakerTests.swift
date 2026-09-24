import XCTest
import SQLite3
@testable import Pods_Speaker

@MainActor
final class PodsSpeakerTests: XCTestCase {
    func testPipelineSummaryMatchesThreeBuckets() {
        func episode(_ id: Int, _ stage: String, error: String? = nil) -> PipelineEpisode {
            PipelineEpisode(id: String(id), episodeId: id, title: "Episode", podcastTitle: "Show", stage: stage,
                            blockingReason: nil, lastErrorMessage: error, completedUnits: 64, totalUnits: 128)
        }
        let presentation = PipelinePresentation(items: [episode(1, "show_notes"), episode(2, "queued")])
        XCTAssertEqual(presentation.statusSummary, "1 processing · 1 queued · 0 stuck")
        XCTAssertEqual(presentation.processing.map(\.episodeId), [1])
        XCTAssertEqual(presentation.queued.map(\.episodeId), [2])
        XCTAssertEqual(presentation.stuck.map(\.episodeId), [])
        XCTAssertEqual(presentation.processing.first?.progress, 0.5)
        let paused = PipelinePresentation(items: [episode(1, "show_notes", error: "omlx_busy")])
        XCTAssertEqual(paused.processing.map(\.episodeId), [])
        XCTAssertEqual(paused.queued.map(\.episodeId), [1])
        XCTAssertEqual(paused.statusSummary, "0 processing · 1 queued · 0 stuck")
        let battery = PipelineEpisode(id: "3", episodeId: 3, title: "Episode", podcastTitle: "Show", stage: "show_notes",
                                      blockingReason: nil, lastErrorMessage: "power_unplugged", completedUnits: 64, totalUnits: 128)
        XCTAssertTrue(battery.isWaiting)
        XCTAssertEqual(battery.displayStage(power: .battery), "Show Notes · paused until plugged in")
        XCTAssertEqual(battery.displayStage(power: .external), "Show Notes")
        XCTAssertEqual(battery.displayStage(power: .unknown), "Show Notes")
        XCTAssertEqual(PipelinePresentation(items: []).statusSummary, "0 processing · 0 queued · 0 stuck")
    }

    func testPipelinePresentationPutsPausedWorkInTheQueueBucket() {
        func episode(_ id: Int, stage: String, error: String? = nil) -> PipelineEpisode {
            PipelineEpisode(id: String(id), episodeId: id, title: "Episode", podcastTitle: "Show", stage: stage,
                            blockingReason: nil, lastErrorMessage: error, completedUnits: nil, totalUnits: nil)
        }
        let items = [episode(1, stage: "transcribing", error: "memory_busy"),
                     episode(2, stage: "classifying"), episode(3, stage: "transcribing", error: "memory_busy"),
                     episode(4, stage: "queued"), episode(5, stage: "blocked"),
                     episode(6, stage: "transcribing", error: "memory_busy")]
        let presentation = PipelinePresentation(items: items)
        XCTAssertEqual(presentation.processing.map(\.episodeId), [2])
        XCTAssertEqual(presentation.queued.map(\.episodeId), [1, 3, 4, 6])
        XCTAssertEqual(presentation.stuck.map(\.episodeId), [5])
        XCTAssertEqual(presentation.statusSummary, "1 processing · 4 queued · 1 stuck")
        XCTAssertEqual(items[0].displayStage(power: .external), "Transcribing · paused for memory")
        XCTAssertTrue(presentation.queued.allSatisfy { $0.progress == nil })
    }

    func testMemoryPausedShowNotesMatchLiveQueueCounts() {
        func episode(_ id: Int, stage: String, error: String) -> PipelineEpisode {
            PipelineEpisode(id: String(id), episodeId: id, title: "Episode", podcastTitle: "Show", stage: stage,
                            blockingReason: nil, lastErrorMessage: error, completedUnits: nil, totalUnits: nil)
        }
        let presentation = PipelinePresentation(items: [
            episode(24394, stage: "show_notes", error: "memory_busy"),
            episode(24395, stage: "show_notes", error: "memory_busy"),
            episode(24371, stage: "blocked", error: "invalid audio"),
            episode(24396, stage: "blocked", error: "audio download transport: Dns"),
            episode(24397, stage: "blocked", error: "audio download transport: Dns"),
        ])
        XCTAssertEqual(presentation.statusSummary, "0 processing · 2 queued · 3 stuck")
        XCTAssertEqual(presentation.statusSummary(visibleStuckCount: 2), "0 processing · 2 queued · 2 stuck")
        XCTAssertEqual(presentation.processing.map(\.episodeId), [])
        XCTAssertEqual(presentation.queued.map(\.episodeId), [24394, 24395])
        XCTAssertEqual(presentation.stuck.map(\.episodeId), [24371, 24396, 24397])
        XCTAssertEqual(
            PipelineAttentionDismissals.visibleAttention(in: presentation.items, dismissedEpisodeIDs: []).map(\.episodeId),
            [24371, 24396, 24397]
        )
    }

    func testPowerPauseLabelFollowsLivePmsetNotStaleJobError() {
        XCTAssertEqual(PipelinePower.parsePmset("Now drawing from 'AC Power'\n"), .external)
        XCTAssertEqual(PipelinePower.parsePmset("Now drawing from 'UPS Power'\n"), .external)
        XCTAssertEqual(PipelinePower.parsePmset("Now drawing from 'Battery Power'\n"), .battery)
        XCTAssertEqual(PipelinePower.parsePmset("pmset unavailable"), .unknown)
        let paused = PipelineEpisode(id: "24989", episodeId: 24989, title: "Mini Ep. 123: Differential Learning",
                                     podcastTitle: "BJJ Mental Models", stage: "transcribing", blockingReason: nil,
                                     lastErrorMessage: "power_unplugged", completedUnits: nil, totalUnits: nil)
        XCTAssertTrue(paused.isWaiting)
        XCTAssertEqual(paused.displayStage(power: .battery), "Transcribing · paused until plugged in")
        XCTAssertEqual(paused.displayStage(power: .external), "Transcribing")
        let checking = PipelineEpisode(id: "24987", episodeId: 24987, title: "Will the uptrend in global liquidity be sustained?",
                                       podcastTitle: "The Macro Minute with Darius Dale", stage: "transcribing",
                                       blockingReason: nil, lastErrorMessage: "power_status_unavailable",
                                       completedUnits: nil, totalUnits: nil)
        XCTAssertEqual(checking.displayStage(power: .external), "Transcribing")
        XCTAssertEqual(checking.displayStage(power: .unknown), "Transcribing · paused while checking power")
        XCTAssertEqual(checking.displayStage(power: .battery), "Transcribing · paused while checking power")
    }

    func testPipelineProgressAndWaitingAreHonest() throws {
        func episode(_ stage: String, error: String? = nil, completed: Int? = nil, total: Int? = nil) -> PipelineEpisode {
            PipelineEpisode(id: "1", episodeId: 1, title: "Episode", podcastTitle: "Podcast", stage: stage,
                            blockingReason: nil, lastErrorMessage: error, completedUnits: completed, totalUnits: total)
        }
        XCTAssertNil(episode("transcribing").progress)
        XCTAssertNil(episode("classifying", completed: 3, total: 2).progress)
        XCTAssertNil(episode("classifying", completed: 0, total: 0).progress)
        XCTAssertEqual(episode("classifying", completed: 2, total: 4).progress, 0.5)
        XCTAssertTrue(episode("transcribing", error: "memory_busy").isWaiting)
        XCTAssertTrue(episode("retry").isWaiting)
        XCTAssertTrue(episode("blocked", error: "invalid audio").needsAttention)
        XCTAssertFalse(episode("transcribing").needsAttention)
    }

    func testAttentionDismissalPersistsAndFiltersOnlyDismissedEpisode() {
        let suiteName = "PodsSpeakerTests.PipelineAttentionDismissals.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated user defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = PipelineEpisode(id: "101", episodeId: 101, title: "First", podcastTitle: "Show",
                                    stage: "blocked", blockingReason: nil, lastErrorMessage: "invalid audio",
                                    completedUnits: nil, totalUnits: nil)
        let second = PipelineEpisode(id: "102", episodeId: 102, title: "Second", podcastTitle: "Show",
                                     stage: "failed", blockingReason: nil, lastErrorMessage: "network error",
                                     completedUnits: nil, totalUnits: nil)
        let active = PipelineEpisode(id: "103", episodeId: 103, title: "Active", podcastTitle: "Show",
                                     stage: "transcribing", blockingReason: nil, lastErrorMessage: nil,
                                     completedUnits: nil, totalUnits: nil)

        XCTAssertTrue(PipelineAttentionDismissals.load(from: defaults).isEmpty)
        PipelineAttentionDismissals.save([PipelineAttentionDismissals.signature(first)], to: defaults)
        XCTAssertEqual(PipelineAttentionDismissals.load(from: defaults), [PipelineAttentionDismissals.signature(first)])
        XCTAssertEqual(
            PipelineAttentionDismissals.visibleAttention(
                in: [first, second, active],
                dismissedEpisodeIDs: PipelineAttentionDismissals.load(from: defaults)
            ).map(\.id),
            [second.id]
        )
        let firstDns = PipelineEpisode(id: "101", episodeId: 101, title: "First", podcastTitle: "Show",
                                       stage: "blocked", blockingReason: nil, lastErrorMessage: "audio download transport: Dns",
                                       completedUnits: nil, totalUnits: nil)
        XCTAssertEqual(
            PipelineAttentionDismissals.visibleAttention(
                in: [firstDns, second, active],
                dismissedEpisodeIDs: PipelineAttentionDismissals.load(from: defaults)
            ).map(\.id),
            [firstDns.id, second.id]
        )
        XCTAssertEqual(
            PipelineAttentionDismissals.visibleAttention(
                in: [first, second, active],
                dismissedEpisodeIDs: ["101"]
            ).map(\.id),
            [first.id, second.id]
        )
    }

    func testPipelineRepositoryReadsSnapshotWithoutChangingDatabase() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pipeline-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        let fixture = """
            CREATE TABLE podcasts(id INTEGER, title TEXT);
            CREATE TABLE episodes(id INTEGER, podcast_id INTEGER, title TEXT, published_at INTEGER);
            CREATE TABLE browser_jobs(episode_id INTEGER, stage TEXT, error TEXT, priority INTEGER);
            CREATE VIEW browser_pending_jobs AS SELECT * FROM browser_jobs WHERE stage!='ready';
            INSERT INTO podcasts VALUES(1,'Show');
            INSERT INTO episodes VALUES(1,1,'Active',1),(2,1,'Blocked',2),(3,1,'Done',3);
            INSERT INTO browser_jobs VALUES(1,'transcribing','memory_busy',0),(2,'blocked','invalid audio',0),(3,'ready',NULL,0);
            """
        XCTAssertEqual(sqlite3_exec(database, fixture, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        let before = try Data(contentsOf: url)
        let items = try PipelineRepository(databaseURL: url).snapshot()
        XCTAssertEqual(items.map(\.title), ["Active", "Blocked"])
        XCTAssertTrue(items[0].isWaiting)
        XCTAssertEqual(items[1].attentionLabel, "invalid audio")
        XCTAssertNil(items[0].progress)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "ALTER TABLE browser_jobs ADD COLUMN completed_units INTEGER; ALTER TABLE browser_jobs ADD COLUMN total_units INTEGER; UPDATE browser_jobs SET completed_units=180000,total_units=240000 WHERE episode_id=1;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        let migrated = try PipelineRepository(databaseURL: url).snapshot()
        XCTAssertEqual(migrated[0].progress, 0.75)
    }

    func testPipelineRepositoryDoesNotCreateMissingDatabase() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).sqlite")
        XCTAssertThrowsError(try PipelineRepository(databaseURL: url).snapshot())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testAttentionPagingShowsFiveItemsAndClampsPastTheLastPage() {
        func episode(_ id: Int) -> PipelineEpisode {
            PipelineEpisode(id: String(id), episodeId: id, title: "Episode \(id)", podcastTitle: "Show",
                            stage: "blocked", blockingReason: nil, lastErrorMessage: "invalid audio",
                            completedUnits: nil, totalUnits: nil)
        }
        let items = (1...11).map(episode)
        XCTAssertEqual(PipelineAttentionPaging.pageSize, 5)
        XCTAssertEqual(PipelineAttentionPaging.pageCount(itemCount: 0), 0)
        XCTAssertEqual(PipelineAttentionPaging.pageCount(itemCount: 5), 1)
        XCTAssertEqual(PipelineAttentionPaging.pageCount(itemCount: 6), 2)
        XCTAssertEqual(PipelineAttentionPaging.pageCount(itemCount: 11), 3)
        XCTAssertEqual(PipelineAttentionPaging.clamp(page: -1, itemCount: 11), 0)
        XCTAssertEqual(PipelineAttentionPaging.clamp(page: 9, itemCount: 11), 2)
        XCTAssertEqual(PipelineAttentionPaging.slice(items, page: 0).map(\.episodeId), [1, 2, 3, 4, 5])
        XCTAssertEqual(PipelineAttentionPaging.slice(items, page: 1).map(\.episodeId), [6, 7, 8, 9, 10])
        XCTAssertEqual(PipelineAttentionPaging.slice(items, page: 2).map(\.episodeId), [11])
        XCTAssertEqual(PipelineAttentionPaging.slice(items, page: 9).map(\.episodeId), [11])
        XCTAssertEqual(PipelineAttentionPaging.summary(itemCount: 11, page: 0), "1-5 of 11")
        XCTAssertEqual(PipelineAttentionPaging.summary(itemCount: 11, page: 2), "11-11 of 11")
        XCTAssertEqual(PipelineAttentionPaging.summary(itemCount: 0, page: 0), "0 of 0")
    }

    func testTroubleshootLaunchUsesGrok46HighInPodcastsAndKeepsThePromptInteractive() throws {
        func episode() -> PipelineEpisode {
            PipelineEpisode(id: "24396", episodeId: 24396, title: "Coin Stories with Natalie Brunell",
                            podcastTitle: "Coin Stories", stage: "blocked", blockingReason: nil,
                            lastErrorMessage: "incomplete", completedUnits: 12, totalUnits: 20)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pods-troubleshoot-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let launch = try PipelineTroubleshoot.prepare(for: episode(), directory: folder)
        XCTAssertEqual(PipelineTroubleshoot.model, "grok-4.6")
        XCTAssertEqual(PipelineTroubleshoot.reasoningEffort, "high")
        XCTAssertTrue(launch.prompt.contains("Episode ID: 24396"))
        XCTAssertTrue(launch.prompt.contains("Coin Stories with Natalie Brunell"))
        XCTAssertTrue(launch.prompt.contains("incomplete"))
        XCTAssertTrue(launch.prompt.contains("/Users/matthewmcgivney/projects/podcasts"))
        XCTAssertTrue(launch.prompt.contains("Do not mutate the live SQLite database"))
        let script = try String(contentsOf: launch.scriptURL, encoding: .utf8)
        XCTAssertTrue(script.contains("grok --cwd '/Users/matthewmcgivney/projects/podcasts' --model 'grok-4.6' --reasoning-effort 'high' --"))
        XCTAssertFalse(script.contains("launch.lock"))
        XCTAssertEqual(launch.openArguments, [
            "-na", "Ghostty.app",
            "--args",
            "--working-directory=/Users/matthewmcgivney/projects/podcasts",
            "--window-save-state=never",
            "--quit-after-last-window-closed=true",
            "--initial-command=direct:\(launch.scriptURL.path)",
        ])
        XCTAssertEqual(try String(contentsOf: launch.promptURL, encoding: .utf8), launch.prompt)
        let permissions = try FileManager.default.attributesOfItem(atPath: launch.scriptURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o755)
    }

    func testAdRemovalProtocolAndProgressCadenceAreVersionedForLiveStreaming() {
        XCTAssertEqual(CastProtocol.version, 2)
        XCTAssertEqual(SpeakerPlayer.progressReportInterval, 0.25)
    }

    func testProtocolRejectsMissingOrLegacyControlMessages() {
        XCTAssertTrue(CastProtocol.isSupported(["v": 2]))
        XCTAssertFalse(CastProtocol.isSupported([:]))
        XCTAssertFalse(CastProtocol.isSupported(["v": 1]))
    }

    func testResolvedPositionRetainsConfirmedProgressAcrossUnavailableClock() {
        XCTAssertEqual(SpeakerPlayer.resolvedPosition(candidate: .nan, lastKnown: 125), 125)
        XCTAssertEqual(SpeakerPlayer.resolvedPosition(candidate: 0, lastKnown: 125), 125)
        XCTAssertEqual(SpeakerPlayer.resolvedPosition(candidate: 126, lastKnown: 125), 126)
    }

    func testPipelinePauseCapsAToggleAtFourHoursAndReportsWait() {
        let start = Date(timeIntervalSince1970: 1_000)
        let state = PipelinePauseState(pausedAt: start)
        XCTAssertEqual(PipelinePauseState.limitSeconds, 14_400)
        XCTAssertEqual(state.pausedAt, 1_000)
        XCTAssertEqual(state.pauseUntil, 15_400)
        XCTAssertTrue(state.isActive(at: start))
        XCTAssertTrue(state.isActive(at: Date(timeIntervalSince1970: 15_399)))
        XCTAssertFalse(state.isActive(at: Date(timeIntervalSince1970: 15_400)))

        let encoded = try? JSONEncoder().encode(state)
        let object = encoded.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Int] }
        XCTAssertEqual(object?["paused_at"], 1_000)
        XCTAssertEqual(object?["pause_until"], 15_400)
        XCTAssertEqual(encoded.flatMap(PipelinePauseFile.decode), state)

        XCTAssertEqual(PipelinePauseController.formatRemaining(14_400), "4h")
        XCTAssertEqual(PipelinePauseController.formatRemaining(3_900), "1h 5m")
        XCTAssertEqual(PipelinePauseController.formatRemaining(120), "2m")
        XCTAssertEqual(PipelinePauseController.formatRemaining(0), "1m")

        let paused = PipelineEpisode(id: "9", episodeId: 9, title: "Episode", podcastTitle: "Show",
                                     stage: "classifying", blockingReason: nil,
                                     lastErrorMessage: "pipeline_paused", completedUnits: 1, totalUnits: 4)
        XCTAssertTrue(paused.isWaiting)
        XCTAssertEqual(paused.displayStage(power: .external), "Finding ad breaks · paused")
        XCTAssertEqual(PipelinePresentation(items: [paused]).statusSummary, "0 processing · 1 queued · 0 stuck")
    }

    func testPipelinePauseFileRejectsCorruptStateAndRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pipeline-pause-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(PipelinePauseFile.read(from: url))
        XCTAssertNil(PipelinePauseFile.decode(Data("not json".utf8)))
        XCTAssertNil(PipelinePauseFile.decode(Data(#"{"paused_at":10,"pause_until":10}"#.utf8)))
        let state = PipelinePauseState(pausedAt: Date(timeIntervalSince1970: 500))
        try PipelinePauseFile.write(state, to: url)
        XCTAssertEqual(PipelinePauseFile.read(from: url), state)
    }

    func testPipelinePauseControllerWritesClearsAndExpiresTheToggle() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pipeline-pause-controller-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let start = Date()
        let controller = PipelinePauseController(fileURL: url, now: start)
        XCTAssertFalse(controller.isPaused)

        controller.setPaused(true, now: start)
        XCTAssertTrue(controller.isPaused)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNotNil(controller.remaining)
        XCTAssertEqual(try PipelinePauseFile.read(from: url)?.pauseUntil, Int(start.timeIntervalSince1970) + PipelinePauseState.limitSeconds)

        // A live pause survives a fresh read, as if the menu reopened.
        let reopened = PipelinePauseController(fileURL: url, now: start)
        XCTAssertTrue(reopened.isPaused)

        // Past the deadline the toggle resets and the shared file is removed,
        // so a forgotten pause can never exceed four hours.
        controller.refresh(now: start.addingTimeInterval(TimeInterval(PipelinePauseState.limitSeconds) + 1))
        XCTAssertFalse(controller.isPaused)
        XCTAssertNil(controller.remaining)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        controller.setPaused(true, now: start)
        controller.setPaused(false, now: start)
        XCTAssertFalse(controller.isPaused)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testLibraryLinkClassifiesFeedsChannelsAndVideos() {
        XCTAssertEqual(PipelineLibraryLink.classify("https://www.youtube.com/@t3dotgg"), .channel)
        XCTAssertEqual(PipelineLibraryLink.classify("@t3dotgg"), .channel)
        XCTAssertEqual(PipelineLibraryLink.classify("UCbRP3c757lWg9M-U7TyEkXA"), .channel)
        XCTAssertEqual(PipelineLibraryLink.classify("https://www.youtube.com/channel/UCbRP3c757lWg9M-U7TyEkXA"), .channel)
        XCTAssertEqual(PipelineLibraryLink.classify("https://www.youtube.com/watch?v=F3YXg7AaKWE"), .video)
        XCTAssertEqual(PipelineLibraryLink.classify("https://youtu.be/F3YXg7AaKWE"), .video)
        XCTAssertEqual(PipelineLibraryLink.classify("https://www.youtube.com/shorts/F3YXg7AaKWE"), .video)
        XCTAssertEqual(PipelineLibraryLink.classify("https://feeds.example/show.xml"), .podcast)
        XCTAssertEqual(PipelineLibraryLink.classify("https://www.youtube.com/playlist?list=PL123"), .invalid)
        XCTAssertEqual(PipelineLibraryLink.classify("not a link"), .invalid)
        XCTAssertEqual(
            PipelineLibraryLink.preview(.channel),
            "Subscribe to this channel. The two newest videos will be prepared."
        )
        XCTAssertEqual(PipelineLibraryLink.confirmation(.video), "Added that video to Listen.")
        XCTAssertEqual(PipelineLibraryLink.confirmation(.podcast), "Subscribed.")
    }

    func testLibraryLinkArticleCopyAndStages() {
        // The menu cannot tell feeds from articles; the backend sniffs the fetch.
        XCTAssertEqual(PipelineLibraryLink.classify("https://example.com/story"), .podcast)
        XCTAssertEqual(
            PipelineLibraryLink.preview(.podcast),
            "Subscribe to this podcast, or queue it as an article."
        )
        XCTAssertEqual(PipelineLibraryKind(rawValue: "article"), .article)
        XCTAssertEqual(
            PipelineLibraryLink.confirmation(.article),
            "Added that article to Listen. It will be read aloud after processing."
        )
        let fetching = PipelineEpisode(
            id: "1", episodeId: 1, title: "Story", podcastTitle: "Articles", stage: "fetching",
            blockingReason: nil, lastErrorMessage: "article_pending", completedUnits: nil, totalUnits: nil
        )
        XCTAssertEqual(fetching.stageLabel, "Fetching article")
        XCTAssertFalse(fetching.needsAttention)
        XCTAssertFalse(fetching.isWaiting)
        let synthesizing = PipelineEpisode(
            id: "2", episodeId: 2, title: "Story", podcastTitle: "Articles", stage: "synthesizing",
            blockingReason: nil, lastErrorMessage: nil, completedUnits: 2, totalUnits: 4
        )
        XCTAssertEqual(synthesizing.stageLabel, "Synthesizing audio")
        XCTAssertEqual(synthesizing.progress, 0.5)
    }

    func testPendingYouTubeListenAppearsInTheQueueBeforeAJobExists() throws {
        let episodes = PipelineListenQueue.episodes(
            from: #"[{"url":"https://www.youtube.com/watch?v=O4G5neJScvU","attempts":0,"next_at":0}]"#,
            now: 100
        )
        XCTAssertEqual(episodes.map(\.title), ["https://www.youtube.com/watch?v=O4G5neJScvU"])
        XCTAssertEqual(episodes.map(\.podcastTitle), ["YouTube"])
        XCTAssertEqual(episodes.map(\.stageLabel), ["Waiting to download"])
        XCTAssertTrue(episodes[0].isWaiting)
        let delayed = PipelineListenQueue.episodes(
            from: #"[{"url":"https://youtu.be/abcdefghijk","attempts":1,"next_at":200}]"#,
            now: 100
        )
        XCTAssertEqual(delayed.map(\.stageLabel), ["Waiting to retry"])

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pipeline-listen-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        let fixture = """
            CREATE TABLE podcasts(id INTEGER, title TEXT);
            CREATE TABLE episodes(id INTEGER, podcast_id INTEGER, title TEXT, published_at INTEGER);
            CREATE TABLE browser_jobs(episode_id INTEGER, stage TEXT, error TEXT, priority INTEGER);
            CREATE VIEW browser_pending_jobs AS SELECT * FROM browser_jobs WHERE stage!='ready';
            CREATE TABLE settings(key TEXT, value TEXT);
            INSERT INTO podcasts VALUES(1,'Show');
            INSERT INTO episodes VALUES(1,1,'Active',1);
            INSERT INTO browser_jobs VALUES(1,'show_notes',NULL,0);
            INSERT INTO settings VALUES('browser_youtube_listen','[{\"url\":\"https://www.youtube.com/watch?v=O4G5neJScvU\",\"attempts\":0,\"next_at\":0}]');
            """
        XCTAssertEqual(sqlite3_exec(database, fixture, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        let items = try PipelineRepository(databaseURL: url).snapshot()
        XCTAssertEqual(items.map(\.title), ["Active", "https://www.youtube.com/watch?v=O4G5neJScvU"])
        XCTAssertTrue(items[1].isWaiting)
    }
}
