import XCTest
@testable import Pods

final class AdRemovalStorageTests: XCTestCase {
    private final class FakeAudioDownloader: AdRemovalAudioDownloading {
        let artifact: AdRemovalAudioArtifact
        private(set) var requestedURL: URL?

        init(artifact: AdRemovalAudioArtifact) {
            self.artifact = artifact
        }

        func download(job: AdRemovalJob, sourceURL: URL) async throws -> AdRemovalAudioArtifact {
            requestedURL = sourceURL
            return artifact
        }
    }

    func testArtifactStoreInstallsDownloadedAudioWithChecksumAndBackupExclusion() throws {
        let directory = try makeDirectory()
        let source = directory.appendingPathComponent("download.tmp")
        try Data("audio-bytes".utf8).write(to: source)
        let root = directory.appendingPathComponent("AdRemoval", isDirectory: true)
        let store = try AdRemovalArtifactStore(rootURL: root)

        let artifact = try store.installDownloadedAudio(
            from: source,
            episodeID: 42,
            fileExtension: "mp3"
        )

        XCTAssertEqual(artifact.relativePath, "episodes/42/audio.mp3")
        XCTAssertEqual(artifact.byteCount, 11)
        XCTAssertEqual(artifact.sha256, "15241589c52e7c4a511a160e040d12bab503cf5d0f586cba94889e554d8df241")
        XCTAssertEqual(try Data(contentsOf: store.url(for: artifact.relativePath)), Data("audio-bytes".utf8))
        XCTAssertTrue(try XCTUnwrap(
            store.url(for: artifact.relativePath).resourceValues(forKeys: [.isExcludedFromBackupKey])
                .isExcludedFromBackup
        ))
    }

    func testStoragePolicyBlocksAggregateLimitAndMinimumFreeSpaceWithoutEviction() throws {
        let quotaPolicy = AdRemovalStoragePolicy(
            artifactLimitBytes: 100,
            minimumFreeBytes: 50,
            usedBytes: { 60 },
            availableBytes: { 200 }
        )
        XCTAssertNoThrow(try quotaPolicy.authorizeLargeWrite(anticipatedBytes: 40))
        XCTAssertThrowsError(try quotaPolicy.authorizeLargeWrite(anticipatedBytes: 41)) { error in
            XCTAssertEqual(error as? AdRemovalStorageError, .artifactLimit)
        }

        let freeSpacePolicy = AdRemovalStoragePolicy(
            artifactLimitBytes: 1_000,
            minimumFreeBytes: 50,
            usedBytes: { 0 },
            availableBytes: { 49 }
        )
        XCTAssertThrowsError(try freeSpacePolicy.authorizeLargeWrite(anticipatedBytes: 1)) { error in
            XCTAssertEqual(error as? AdRemovalStorageError, .minimumFreeSpace)
        }
    }

    func testArtifactStoreRejectsUntrustedPathsAndCleansInstalledFilesIdempotently() throws {
        let directory = try makeDirectory()
        let store = try AdRemovalArtifactStore(rootURL: directory.appendingPathComponent("AdRemoval"))
        XCTAssertThrowsError(try store.url(for: "/tmp/audio.mp3"))
        XCTAssertThrowsError(try store.url(for: "episodes/1/../../escape"))
        XCTAssertThrowsError(try store.url(for: "episodes//audio.mp3"))

        let source = directory.appendingPathComponent("download.tmp")
        try Data("audio".utf8).write(to: source)
        let artifact = try store.installDownloadedAudio(from: source, episodeID: 1, fileExtension: "m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try store.url(for: artifact.relativePath).path))

        try store.removeArtifact(relativePath: artifact.relativePath)
        try store.removeArtifact(relativePath: artifact.relativePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.url(for: artifact.relativePath).path))
    }

    func testResumeDataLivesInArtifactStoreAndOnlyItsValidatedPathIsPersisted() throws {
        let directory = try makeDirectory()
        let database = try makeDatabase(in: directory)
        let jobStore = AdRemovalJobStore(database: database, now: { 1_000 })
        let episodeID = try XCTUnwrap(database.scalarInt64("SELECT id FROM episodes LIMIT 1"))
        let job = try jobStore.enqueue(episodeID: episodeID)
        let artifactStore = try AdRemovalArtifactStore(rootURL: directory.appendingPathComponent("AdRemoval"))
        let resumeData = Data(repeating: 0x5a, count: 4_096)

        let relativePath = try artifactStore.writeResumeData(resumeData, jobID: job.id)
        let persisted = try jobStore.recordDownloadResumePath(jobID: job.id, relativePath: relativePath)

        XCTAssertEqual(persisted.downloadResumeRelativePath, relativePath)
        XCTAssertEqual(try artifactStore.resumeData(relativePath: relativePath), resumeData)
        XCTAssertFalse(relativePath.hasPrefix("/"))
        XCTAssertNil(try database.query(
            "SELECT sql FROM sqlite_master WHERE name = 'ad_removal_jobs' AND sql LIKE '%BLOB%'",
            map: { sqliteString($0, 0) }
        ).first)

        try artifactStore.removeArtifact(relativePath: relativePath)
        _ = try jobStore.recordDownloadResumePath(jobID: job.id, relativePath: nil)
        XCTAssertNil(try jobStore.job(id: job.id)?.downloadResumeRelativePath)
    }

    func testAudioDownloadConfigurationAllowsCellularAndBackgroundRecovery() {
        let configuration = AdRemovalAudioDownloadPolicy.configuration(identifier: "dev.mcgiv.pods.tests.audio")
        XCTAssertTrue(configuration.allowsCellularAccess)
        XCTAssertTrue(configuration.waitsForConnectivity)
        XCTAssertFalse(configuration.isDiscretionary)
        XCTAssertTrue(configuration.sessionSendsLaunchEvents)
        XCTAssertEqual(configuration.httpMaximumConnectionsPerHost, 1)
    }

    func testDownloadFinalizerPersistsArtifactAndAdvancesDurableStage() throws {
        let directory = try makeDirectory()
        let database = try makeDatabase(in: directory)
        let jobStore = AdRemovalJobStore(database: database, now: { 1_000 })
        let episodeID = try XCTUnwrap(database.scalarInt64("SELECT id FROM episodes LIMIT 1"))
        let queued = try jobStore.enqueue(episodeID: episodeID)
        let downloading = try jobStore.transition(jobID: queued.id, to: .downloading)
        let artifactStore = try AdRemovalArtifactStore(rootURL: directory.appendingPathComponent("AdRemoval"))
        let policy = AdRemovalStoragePolicy(
            usedBytes: { try artifactStore.episodeArtifactBytes() },
            availableBytes: { Int64.max }
        )
        let finalizer = AdRemovalDownloadFinalizer(
            jobStore: jobStore,
            artifactStore: artifactStore,
            storagePolicy: policy
        )
        let temporaryURL = directory.appendingPathComponent("episode-download.tmp")
        try Data("downloaded-audio".utf8).write(to: temporaryURL)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://example.com/episode.mp3")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "audio/mpeg"]
        ))

        let artifact = try finalizer.finalize(
            temporaryURL: temporaryURL,
            response: response,
            job: downloading
        )

        XCTAssertEqual(artifact.relativePath, "episodes/\(episodeID)/audio.mp3")
        let persisted = try jobStore.job(id: queued.id)
        XCTAssertEqual(persisted?.stage, .downloaded)
        XCTAssertEqual(persisted?.audioArtifact, artifact)
    }

    func testDownloadFinalizerRejectsHTTPFailureWithoutFalseDownloadedState() throws {
        let directory = try makeDirectory()
        let database = try makeDatabase(in: directory)
        let jobStore = AdRemovalJobStore(database: database, now: { 1_000 })
        let episodeID = try XCTUnwrap(database.scalarInt64("SELECT id FROM episodes LIMIT 1"))
        let queued = try jobStore.enqueue(episodeID: episodeID)
        let downloading = try jobStore.transition(jobID: queued.id, to: .downloading)
        let artifactStore = try AdRemovalArtifactStore(rootURL: directory.appendingPathComponent("AdRemoval"))
        let finalizer = AdRemovalDownloadFinalizer(
            jobStore: jobStore,
            artifactStore: artifactStore,
            storagePolicy: AdRemovalStoragePolicy(
                usedBytes: { 0 },
                availableBytes: { Int64.max }
            )
        )
        let temporaryURL = directory.appendingPathComponent("failed.tmp")
        try Data("error page".utf8).write(to: temporaryURL)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://example.com/episode.mp3")!,
            statusCode: 503,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html"]
        ))

        XCTAssertThrowsError(try finalizer.finalize(
            temporaryURL: temporaryURL,
            response: response,
            job: downloading
        ))
        XCTAssertEqual(try jobStore.job(id: queued.id)?.stage, .downloading)
        XCTAssertNil(try jobStore.job(id: queued.id)?.audioArtifact)
    }

    func testPipelineExecutorDownloadsAndValidatesExactEpisodeAudioBeforeAdvancing() async throws {
        let directory = try makeDirectory()
        let database = try makeDatabase(in: directory)
        let jobStore = AdRemovalJobStore(database: database, now: { 1_000 })
        let episodeID = try XCTUnwrap(database.scalarInt64("SELECT id FROM episodes LIMIT 1"))
        let queued = try jobStore.enqueue(episodeID: episodeID)
        let artifactStore = try AdRemovalArtifactStore(rootURL: directory.appendingPathComponent("AdRemoval"))
        let temporaryAudio = directory.appendingPathComponent("download.tmp")
        try Data("pipeline audio".utf8).write(to: temporaryAudio)
        let artifact = try artifactStore.installDownloadedAudio(
            from: temporaryAudio,
            episodeID: episodeID,
            fileExtension: "mp3"
        )
        let downloader = FakeAudioDownloader(artifact: artifact)
        let executor = AdRemovalPipelineExecutor(
            database: database,
            jobStore: jobStore,
            artifactStore: artifactStore,
            audioDownloader: downloader
        )
        let coordinator = AdRemovalCoordinator(store: jobStore, executor: executor)

        let completed = try await coordinator.runNextStage()

        XCTAssertEqual(completed?.stage, .downloaded)
        XCTAssertEqual(completed?.audioArtifact, artifact)
        XCTAssertEqual(downloader.requestedURL?.absoluteString, "https://example.com/episode.mp3")
        XCTAssertEqual(try jobStore.job(id: queued.id)?.audioArtifact, artifact)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdRemovalStorageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeDatabase(in directory: URL) throws -> PodsDatabase {
        let database = try PodsDatabase(url: directory.appendingPathComponent("test.sqlite"))
        try database.execute(
            "INSERT INTO podcasts (feed_url, title, created_at) VALUES (?, ?, ?)",
            [.text("https://example.com/feed"), .text("Example"), .int(1)]
        )
        let podcastID = database.lastInsertRowID()
        try database.execute(
            "INSERT INTO episodes (podcast_id, guid, title, audio_url, published_at) VALUES (?, ?, ?, ?, ?)",
            [
                .int(podcastID),
                .text("episode-1"),
                .text("Episode"),
                .text("https://example.com/episode.mp3"),
                .int(100)
            ]
        )
        return database
    }
}
