import XCTest
@testable import Pods

final class AdRemovalDiagnosticsTests: XCTestCase {
    func testStructuredEventIsRedactedBeforeItIsPersisted() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdRemovalDiagnosticsTests-\(UUID().uuidString)", isDirectory: true)
        let diagnostics = try AdRemovalDiagnostics(configuration: .init(
            rootDirectory: root,
            maximumLogFileBytes: 10_000,
            retainedLogFileCount: 5,
            retainedSnapshotCount: 10,
            appVersion: "1.2.3",
            buildVersion: "45"
        ))

        try diagnostics.record(
            eventName: "audio_download_response",
            severity: .info,
            context: .init(
                jobID: "job-7",
                episodeID: 42,
                podcastID: 9,
                stage: "downloading",
                attempt: 2,
                playbackSessionID: "session-a"
            ),
            fields: [
                "request_url": "https://cdn.example/episode.mp3?token=super-secret&expires=42",
                "authorization": "Bearer also-secret",
                "cookie": "session=private",
                "response_status": "206"
            ]
        )

        let event = try XCTUnwrap(diagnostics.readPersistedEvents().only)
        XCTAssertEqual(event.eventName, "audio_download_response")
        XCTAssertEqual(event.severity, .info)
        XCTAssertEqual(event.appVersion, "1.2.3")
        XCTAssertEqual(event.buildVersion, "45")
        XCTAssertEqual(event.context.jobID, "job-7")
        XCTAssertEqual(event.context.episodeID, 42)
        XCTAssertEqual(event.context.podcastID, 9)
        XCTAssertEqual(event.context.stage, "downloading")
        XCTAssertEqual(event.context.attempt, 2)
        XCTAssertEqual(event.context.playbackSessionID, "session-a")
        XCTAssertEqual(event.fields["request_url"], "https://cdn.example/episode.mp3")
        XCTAssertEqual(event.fields["authorization"], "[REDACTED]")
        XCTAssertEqual(event.fields["cookie"], "[REDACTED]")
        XCTAssertEqual(event.fields["response_status"], "206")

        let logURL = try XCTUnwrap(diagnostics.logFileURLs().only)
        let persistedText = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertFalse(persistedText.contains("super-secret"))
        XCTAssertFalse(persistedText.contains("also-secret"))
        XCTAssertFalse(persistedText.contains("session=private"))
    }

    func testLogRotationRetainsExactlyTheConfiguredNewestFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdRemovalDiagnosticsRotationTests-\(UUID().uuidString)", isDirectory: true)
        let diagnostics = try AdRemovalDiagnostics(configuration: .init(
            rootDirectory: root,
            maximumLogFileBytes: 1,
            retainedLogFileCount: 3,
            retainedSnapshotCount: 10,
            appVersion: "1",
            buildVersion: "1"
        ))

        for index in 1...5 {
            try diagnostics.record(
                eventName: "rotation_probe",
                severity: .debug,
                fields: ["sequence": "\(index)"]
            )
        }

        XCTAssertEqual(
            diagnostics.logFileURLs().map(\.lastPathComponent),
            ["ad-removal-00.jsonl", "ad-removal-01.jsonl", "ad-removal-02.jsonl"]
        )
        XCTAssertEqual(
            try diagnostics.readPersistedEvents().compactMap { $0.fields["sequence"] },
            ["3", "4", "5"]
        )
    }

    func testConcurrentWritesProduceCompleteDecodableEvents() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdRemovalDiagnosticsConcurrencyTests-\(UUID().uuidString)", isDirectory: true)
        let diagnostics = try AdRemovalDiagnostics(configuration: .init(
            rootDirectory: root,
            maximumLogFileBytes: 1_000_000,
            retainedLogFileCount: 5,
            retainedSnapshotCount: 10,
            appVersion: "1",
            buildVersion: "1"
        ))
        let errorLock = NSLock()
        var errors: [Error] = []

        DispatchQueue.concurrentPerform(iterations: 200) { index in
            do {
                try diagnostics.record(
                    eventName: "concurrency_probe",
                    severity: .debug,
                    fields: ["sequence": "\(index)"]
                )
            } catch {
                errorLock.withLock { errors.append(error) }
            }
        }

        XCTAssertTrue(errors.isEmpty)
        let events = try diagnostics.readPersistedEvents()
        XCTAssertEqual(events.count, 200)
        XCTAssertEqual(Set(events.compactMap { $0.fields["sequence"] }).count, 200)
    }

    func testSnapshotRetentionKeepsTheConfiguredNewestJobs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdRemovalDiagnosticsSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        let diagnostics = try AdRemovalDiagnostics(configuration: .init(
            rootDirectory: root,
            maximumLogFileBytes: 10_000,
            retainedLogFileCount: 5,
            retainedSnapshotCount: 2,
            appVersion: "1",
            buildVersion: "1"
        ))

        for index in 1...3 {
            try diagnostics.saveSnapshot(.init(
                schemaVersion: 1,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                jobID: "job-\(index)",
                episodeID: Int64(index),
                podcastID: 9,
                transcriptSegments: [
                    .init(id: "segment-\(index)", startTime: 1, endTime: 2, text: "Text \(index)")
                ],
                classifierPrompt: "prompt-v1",
                classifierInput: "input \(index)",
                selectedCorrectionExamples: ["not an ad"],
                rawClassifierOutput: "{\"labels\":[]}",
                schemaValidationResult: "valid",
                finalLabels: ["segment-\(index)": "content"],
                skipManifest: "[]"
            ))
        }

        XCTAssertEqual(try diagnostics.readSnapshots().map(\.jobID), ["job-2", "job-3"])
        XCTAssertEqual(diagnostics.snapshotFileURLs().count, 2)
    }

    func testExportArchiveContainsVersionedManifestLogsSnapshotsAndStateSummary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdRemovalDiagnosticsExportTests-\(UUID().uuidString)", isDirectory: true)
        let exportDirectory = root.appendingPathComponent("exports", isDirectory: true)
        let diagnostics = try AdRemovalDiagnostics(configuration: .init(
            rootDirectory: root.appendingPathComponent("diagnostics", isDirectory: true),
            maximumLogFileBytes: 10_000,
            retainedLogFileCount: 5,
            retainedSnapshotCount: 10,
            appVersion: "2.0",
            buildVersion: "99"
        ))
        try diagnostics.record(eventName: "job_ready", severity: .notice)
        try diagnostics.saveSnapshot(.init(
            schemaVersion: 1,
            createdAt: Date(timeIntervalSince1970: 10),
            jobID: "job-export",
            episodeID: 5,
            podcastID: 3,
            transcriptSegments: [],
            classifierPrompt: "prompt",
            classifierInput: "input",
            selectedCorrectionExamples: [],
            rawClassifierOutput: "{}",
            schemaValidationResult: "valid",
            finalLabels: [:],
            skipManifest: "[]"
        ))

        let manifest = diagnostics.makeExportManifest(
            stateSummary: ["ready_jobs": "1"],
            schemaVersions: ["database": "4", "classifier_output": "1"],
            now: Date(timeIntervalSince1970: 20)
        )
        XCTAssertEqual(manifest.formatVersion, 1)
        XCTAssertEqual(manifest.appVersion, "2.0")
        XCTAssertEqual(manifest.buildVersion, "99")
        XCTAssertEqual(manifest.stateSummary, ["ready_jobs": "1"])
        XCTAssertEqual(manifest.schemaVersions, ["database": "4", "classifier_output": "1"])
        XCTAssertEqual(manifest.logFiles, ["iphone/logs/ad-removal-00.jsonl"])
        XCTAssertEqual(manifest.snapshotFiles.count, 1)
        XCTAssertTrue(manifest.snapshotFiles[0].hasPrefix("iphone/snapshots/"))

        let archiveURL = try diagnostics.exportArchive(
            to: exportDirectory,
            stateSummary: ["ready_jobs": "1"],
            schemaVersions: ["database": "4", "classifier_output": "1"],
            now: Date(timeIntervalSince1970: 20)
        )
        XCTAssertEqual(archiveURL.pathExtension, "zip")
        let archive = try Data(contentsOf: archiveURL)
        XCTAssertEqual(Array(archive.prefix(4)), [0x50, 0x4b, 0x03, 0x04])
        let archiveText = String(decoding: archive, as: UTF8.self)
        XCTAssertTrue(archiveText.contains("manifest.json"))
        XCTAssertTrue(archiveText.contains("state-summary.json"))
        XCTAssertTrue(archiveText.contains("iphone/logs/ad-removal-00.jsonl"))
        XCTAssertTrue(archiveText.contains("iphone/snapshots/"))
    }

    func testClearRemovesStructuredLogsAndSnapshots() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdRemovalDiagnosticsClearTests-\(UUID().uuidString)", isDirectory: true)
        let diagnostics = try AdRemovalDiagnostics(configuration: .init(
            rootDirectory: root,
            appVersion: "1",
            buildVersion: "1"
        ))
        try diagnostics.record(eventName: "clear_probe", severity: .info)
        try diagnostics.saveSnapshot(.init(
            schemaVersion: 1,
            createdAt: Date(),
            jobID: "job-clear",
            episodeID: 1,
            podcastID: nil,
            transcriptSegments: [],
            classifierPrompt: "prompt",
            classifierInput: "input",
            selectedCorrectionExamples: [],
            rawClassifierOutput: "{}",
            schemaValidationResult: "valid",
            finalLabels: [:],
            skipManifest: "[]"
        ))

        try diagnostics.clear()

        XCTAssertTrue(diagnostics.logFileURLs().isEmpty)
        XCTAssertTrue(diagnostics.snapshotFileURLs().isEmpty)
        XCTAssertTrue(try diagnostics.readPersistedEvents().isEmpty)
    }

    func testMacAndPhoneFactoriesKeepJoinablePlaybackSessionContextInSeparateRoots() throws {
        let applicationSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdRemovalDiagnosticsFactoryTests-\(UUID().uuidString)", isDirectory: true)
        let phone = try AdRemovalDiagnostics.applicationDefault(
            component: .iphone,
            applicationSupportDirectory: applicationSupport,
            appVersion: "3",
            buildVersion: "4"
        )
        let mac = try AdRemovalDiagnostics.applicationDefault(
            component: .mac,
            applicationSupportDirectory: applicationSupport,
            appVersion: "3",
            buildVersion: "4"
        )
        let sessionID = "playback-session-123"

        try phone.record(
            eventName: "range_entry",
            severity: .notice,
            context: .init(playbackSessionID: sessionID)
        )
        try mac.record(
            eventName: "absolute_seek_received",
            severity: .notice,
            context: .init(playbackSessionID: sessionID)
        )

        XCTAssertEqual(try phone.readPersistedEvents().only?.component, .iphone)
        XCTAssertEqual(try mac.readPersistedEvents().only?.component, .mac)
        XCTAssertEqual(try phone.readPersistedEvents().only?.context.playbackSessionID, sessionID)
        XCTAssertEqual(try mac.readPersistedEvents().only?.context.playbackSessionID, sessionID)
        XCTAssertTrue(try XCTUnwrap(phone.logFileURLs().only).path.contains("Pods/AdRemovalDiagnostics"))
        XCTAssertTrue(try XCTUnwrap(mac.logFileURLs().only).path.contains("PodsSpeaker/AdRemovalDiagnostics"))
        XCTAssertEqual(
            mac.makeExportManifest(stateSummary: [:], schemaVersions: [:]).logFiles,
            ["mac/logs/ad-removal-00.jsonl"]
        )
        let archiveURL = try mac.exportArchive(
            to: applicationSupport.appendingPathComponent("exports", isDirectory: true),
            stateSummary: [:],
            schemaVersions: [:]
        )
        let archiveText = String(decoding: try Data(contentsOf: archiveURL), as: UTF8.self)
        XCTAssertTrue(archiveText.contains("mac/logs/ad-removal-00.jsonl"))
        XCTAssertFalse(archiveText.contains("iphone/logs/ad-removal-00.jsonl"))
    }

    func testPlaybackSessionCorrelationRoundTripsAcrossControlPayloads() throws {
        let sessionID = AdRemovalPlaybackSession.makeID()
        let command = AdRemovalPlaybackSession.attaching(
            sessionID: sessionID,
            to: ["cmd": "load", "episodeId": 42]
        )
        let event = AdRemovalPlaybackSession.attaching(
            sessionID: try XCTUnwrap(AdRemovalPlaybackSession.sessionID(from: command)),
            to: ["type": "timeupdate", "position": 15]
        )

        XCTAssertNotNil(UUID(uuidString: sessionID))
        XCTAssertEqual(AdRemovalPlaybackSession.sessionID(from: command), sessionID)
        XCTAssertEqual(AdRemovalPlaybackSession.sessionID(from: event), sessionID)
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
