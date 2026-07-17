import XCTest
@testable import Pods

final class AdRemovalClassificationTests: XCTestCase {
    private final class UnusedDownloader: AdRemovalAudioDownloading {
        func download(job: AdRemovalJob, sourceURL: URL) async throws -> AdRemovalAudioArtifact {
            throw AdRemovalPipelineError.unsupportedStage(.downloading)
        }
    }

    private final class FakeClassifier: AdClassifier {
        let descriptor: AdClassifierDescriptor
        private var responses: [Result<String, Error>]
        private(set) var prompts: [String] = []
        private(set) var unloadCalls = 0

        init(responses: [Result<String, Error>]) {
            descriptor = AdClassifierDescriptor(
                modelID: "test/qwen",
                modelRevision: "revision-abc123",
                quantization: "4-bit",
                promptRevision: "prompt-v1",
                maximumContextTokens: 8_192,
                maximumOutputTokens: 1_024,
                temperature: 0,
                topP: 1
            )
            self.responses = responses
        }

        func classify(window: AdClassificationWindow) async throws -> String {
            prompts.append(window.prompt)
            return try responses.removeFirst().get()
        }

        func unload() async {
            unloadCalls += 1
        }
    }

    func testWindowBuilderBoundsInputAndOverlapsTranscriptSegments() throws {
        let segments = (0..<10).map { index in
            AdTranscriptSegment(
                id: "segment-\(index)",
                index: index,
                language: "en-US",
                startTime: Double(index * 10),
                endTime: Double(index * 10 + 9),
                text: "Transcript segment \(index)"
            )
        }
        let builder = AdClassificationWindowBuilder(
            limits: .init(
                maximumContextTokens: 8_192,
                reservedOutputTokens: 1_024,
                correctionTokenBudget: 1_024,
                maximumSegmentsPerWindow: 5,
                overlapSegmentCount: 2
            )
        )

        let windows = try builder.makeWindows(segments: segments, corrections: [])

        XCTAssertEqual(windows.map(\.segmentIDs), [
            ["segment-0", "segment-1", "segment-2", "segment-3", "segment-4"],
            ["segment-3", "segment-4", "segment-5", "segment-6", "segment-7"],
            ["segment-6", "segment-7", "segment-8", "segment-9"]
        ])
        XCTAssertEqual(windows.map(\.index), [0, 1, 2])
        XCTAssertTrue(windows.allSatisfy { $0.estimatedInputTokens <= $0.maximumInputTokens })
    }

    func testCorrectionSelectionIsRelevantNewestFirstAndBounded() throws {
        let segments = [
            AdTranscriptSegment(
                id: "segment-0",
                index: 0,
                language: "en-US",
                startTime: 0,
                endTime: 10,
                text: "The host answers listener questions about medication safety"
            )
        ]
        let corrections = [
            correction(id: "old-relevant", text: "Listener questions are editorial content", createdAt: 10),
            correction(id: "new-relevant", text: "The medication safety discussion is content", createdAt: 30),
            correction(id: "irrelevant", text: "A completely unrelated sports monologue", createdAt: 40)
        ]
        let builder = AdClassificationWindowBuilder(
            limits: .init(
                maximumContextTokens: 8_192,
                reservedOutputTokens: 1_024,
                correctionTokenBudget: 90,
                maximumSegmentsPerWindow: 20,
                overlapSegmentCount: 2
            )
        )

        let window = try XCTUnwrap(builder.makeWindows(segments: segments, corrections: corrections).first)

        XCTAssertEqual(window.corrections.map(\.id), ["new-relevant"])
        XCTAssertLessThanOrEqual(window.estimatedCorrectionTokens, 90)
        XCTAssertTrue(window.prompt.contains("new-relevant"))
        XCTAssertFalse(window.prompt.contains("irrelevant"))
    }

    func testStructuredOutputParserAcceptsOnlyCompleteKnownSegmentLabels() throws {
        let parser = AdClassifierOutputParser()
        let expectedIDs = ["segment-0", "segment-1"]
        let raw = #"{"labels":[{"segment_id":"segment-0","classification":"content","confidence":0.91,"reason":"editorial discussion"},{"segment_id":"segment-1","classification":"ad","confidence":0.98,"reason":"promo code and sponsor call to action"}]}"#

        let parsed = try parser.parse(raw, expectedSegmentIDs: expectedIDs)

        XCTAssertEqual(parsed, [
            AdClassifierLabel(
                segmentID: "segment-0",
                classification: .content,
                confidence: 0.91,
                reason: "editorial discussion"
            ),
            AdClassifierLabel(
                segmentID: "segment-1",
                classification: .advertisement,
                confidence: 0.98,
                reason: "promo code and sponsor call to action"
            )
        ])
    }

    func testStructuredOutputParserRejectsMalformedInventedAndIncompleteOutput() {
        let parser = AdClassifierOutputParser()
        let expectedIDs = ["segment-0", "segment-1"]
        let cases = [
            "```json\n{\"labels\":[]}\n```",
            #"{"labels":[{"segment_id":"invented","classification":"ad","confidence":0.9,"reason":"ad"}]}"#,
            #"{"labels":[{"segment_id":"segment-0","classification":"content","confidence":0.9,"reason":"content"}]}"#,
            #"{"labels":[{"segment_id":"segment-0","classification":"content","confidence":1.1,"reason":"content"},{"segment_id":"segment-1","classification":"ad","confidence":0.9,"reason":"ad"}]}"#,
            #"{"labels":[{"segment_id":"segment-0","classification":"content","confidence":0.9,"reason":"content","timestamp":123},{"segment_id":"segment-1","classification":"ad","confidence":0.9,"reason":"ad"}]}"#
        ]

        for raw in cases {
            XCTAssertThrowsError(try parser.parse(raw, expectedSegmentIDs: expectedIDs), raw)
        }
    }

    func testClassificationPipelinePersistsEvidenceAndDeterministicManifest() async throws {
        let harness = try makeClassifyingHarness()
        let diagnostics = try AdRemovalDiagnostics(configuration: .init(
            rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(
                "AdRemovalClassificationDiagnostics-\(UUID().uuidString)",
                isDirectory: true
            ),
            retainedSnapshotCount: 10,
            appVersion: "1.0",
            buildVersion: "1"
        ))
        let response = #"{"labels":[{"segment_id":"segment-0","classification":"content","confidence":0.99,"reason":"show introduction"},{"segment_id":"segment-1","classification":"ad","confidence":0.93,"reason":"sponsor offer"},{"segment_id":"segment-2","classification":"ad","confidence":0.88,"reason":"promo call to action"},{"segment_id":"segment-3","classification":"content","confidence":0.96,"reason":"editorial interview"}]}"#
        let classifier = FakeClassifier(responses: [.success(response)])
        let executor = AdRemovalPipelineExecutor(
            database: harness.database,
            jobStore: harness.store,
            artifactStore: harness.artifactStore,
            audioDownloader: UnusedDownloader(),
            classifier: classifier,
            manifestBuilder: AdSkipManifestBuilder(advertisementThreshold: 0.55, now: { 2_000 }),
            diagnostics: diagnostics
        )

        try await executor.execute(stage: .classifying, job: harness.job)

        let persistedJob = try XCTUnwrap(harness.store.job(id: harness.job.id))
        XCTAssertEqual(persistedJob.classifierVersion, "test/qwen@revision-abc123")
        XCTAssertEqual(persistedJob.promptVersion, "prompt-v1")
        XCTAssertEqual(persistedJob.classifierQuantization, "4-bit")
        XCTAssertEqual(persistedJob.classifiedAt, 1_000)
        XCTAssertNotNil(persistedJob.classificationRunID)
        let evidence = try harness.store.classificationEvidence(episodeID: harness.episodeID)
        XCTAssertEqual(evidence.count, 1)
        XCTAssertTrue(evidence[0].schemaValid)
        XCTAssertEqual(evidence[0].rawOutput, response)
        XCTAssertEqual(evidence[0].labels.count, 4)
        XCTAssertEqual(evidence[0].correctionIDs, [])
        XCTAssertEqual(try harness.store.skipRanges(episodeID: harness.episodeID), [
            AdSkipRange(
                id: "ad-segment-1--segment-2",
                startSegmentID: "segment-1",
                endSegmentID: "segment-2",
                startTime: 10,
                endTime: 30,
                confidence: 0.88,
                reason: "sponsor offer; promo call to action",
                classifierVersion: "test/qwen@revision-abc123",
                promptVersion: "prompt-v1",
                createdAt: 2_000,
                disabled: false
            )
        ])
        XCTAssertEqual(classifier.unloadCalls, 1)
        let snapshotURL = try XCTUnwrap(diagnostics.snapshotFileURLs().first)
        let snapshot = try JSONDecoder().decode(
            AdRemovalDiagnosticSnapshot.self,
            from: Data(contentsOf: snapshotURL)
        )
        XCTAssertEqual(snapshot.jobID, harness.job.id)
        XCTAssertEqual(snapshot.rawClassifierOutput, response)
        XCTAssertTrue(snapshot.schemaValidationResult.contains("valid"))
        XCTAssertTrue(snapshot.skipManifest.contains("segment-1"))
    }

    func testMalformedClassificationPersistsInvalidEvidenceButNeverManifest() async throws {
        let harness = try makeClassifyingHarness()
        let classifier = FakeClassifier(responses: [.success(#"{"labels":[]}"#)])
        let executor = AdRemovalPipelineExecutor(
            database: harness.database,
            jobStore: harness.store,
            artifactStore: harness.artifactStore,
            audioDownloader: UnusedDownloader(),
            classifier: classifier
        )

        do {
            try await executor.execute(stage: .classifying, job: harness.job)
            XCTFail("Expected invalid classifier output")
        } catch let error as AdClassifierOutputError {
            XCTAssertEqual(error, .missingSegment("segment-0"))
        }

        XCTAssertTrue(try harness.store.skipRanges(episodeID: harness.episodeID).isEmpty)
        XCTAssertNil(try harness.store.job(id: harness.job.id)?.classificationRunID)
        let evidence = try harness.store.classificationEvidence(episodeID: harness.episodeID)
        XCTAssertEqual(evidence.count, 1)
        XCTAssertFalse(evidence[0].schemaValid)
        XCTAssertNotNil(evidence[0].validationError)
        XCTAssertTrue(evidence[0].labels.isEmpty)
        XCTAssertEqual(classifier.unloadCalls, 1)
    }

    func testPinnedQwenManifestHasExactRevisionChecksumsAndConsentSize() {
        let manifest = AdModelManifest.qwen35FourBitV1

        XCTAssertEqual(AdClassifierDescriptor.qwen35FourBitV1.modelRevision, manifest.revision)
        XCTAssertEqual(manifest.repository, "mlx-community/Qwen3.5-4B-MLX-4bit")
        XCTAssertEqual(manifest.revision, "32f3e8ecf65426fc3306969496342d504bfa13f3")
        XCTAssertEqual(manifest.files.count, 10)
        XCTAssertEqual(manifest.totalByteCount, 3_061_129_077)
        XCTAssertTrue(manifest.files.allSatisfy { file in
            file.sha256.count == 64 && file.byteCount > 0 && !file.relativePath.contains("..")
        })
    }

    func testModelActivationVerifiesEveryFileAndPersistsOnlyValidatedRevision() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdRemovalModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try PodsDatabase(url: directory.appendingPathComponent("test.sqlite"))
        let store = try AdModelAssetStore(rootURL: directory.appendingPathComponent("Models"))
        let manifest = AdModelManifest(
            repository: "test/model",
            revision: "abc123",
            files: [
                AdModelFile(
                    relativePath: "config.json",
                    byteCount: 6,
                    sha256: "b79606fb3afea5bd1609ed40b622142f1c98125abcfe89a76a661b0e8e343910"
                ),
                AdModelFile(
                    relativePath: "weights/model.bin",
                    byteCount: 7,
                    sha256: "9a129038d9a00aed0cf6a7ea059ca50a813449061ab87848cf1a13eafdf33b2c"
                )
            ]
        )
        try store.installForTesting(Data("config".utf8), at: "config.json", manifest: manifest)
        try store.installForTesting(Data("corrupt".utf8), at: "weights/model.bin", manifest: manifest)

        XCTAssertThrowsError(try store.activate(manifest: manifest, database: database))
        XCTAssertNil(try database.query(
            "SELECT value FROM settings WHERE key = 'ad_removal_model_revision'",
            map: { sqliteString($0, 0) }
        ).first)

        try store.installForTesting(Data("weights".utf8), at: "weights/model.bin", manifest: manifest)
        let activated = try store.activate(manifest: manifest, database: database)

        XCTAssertEqual(activated, store.modelDirectory(for: manifest))
        XCTAssertEqual(try database.query(
            "SELECT value FROM settings WHERE key = 'ad_removal_model_revision'",
            map: { sqliteString($0, 0) }
        ).first, "abc123")
        XCTAssertEqual(try database.query(
            "SELECT value FROM settings WHERE key = 'ad_removal_model_byte_count'",
            map: { sqliteString($0, 0) }
        ).first, "13")
    }

    func testModelDownloadsAreWiFiOnlyAndRequireExactSizeConsent() {
        let configuration = AdModelDownloadPolicy.configuration(identifier: "dev.mcgiv.pods.tests.model")
        XCTAssertFalse(configuration.allowsCellularAccess)
        XCTAssertFalse(configuration.allowsExpensiveNetworkAccess)
        XCTAssertFalse(configuration.allowsConstrainedNetworkAccess)
        XCTAssertThrowsError(try AdModelDownloadPolicy.authorize(
            manifest: .qwen35FourBitV1,
            confirmedByteCount: 3_061_129_076
        ))
        XCTAssertNoThrow(try AdModelDownloadPolicy.authorize(
            manifest: .qwen35FourBitV1,
            confirmedByteCount: 3_061_129_077
        ))
    }

    func testModelDownloadURLPinsExactRepositoryRevisionAndEscapesFilePath() throws {
        let manifest = AdModelManifest(
            repository: "owner/model-name",
            revision: "abc123",
            files: [
                AdModelFile(
                    relativePath: "tokenizer files/vocab.json",
                    byteCount: 1,
                    sha256: String(repeating: "0", count: 64)
                )
            ]
        )

        let url = try AdModelDownloadPolicy.remoteURL(
            for: manifest.files[0],
            manifest: manifest
        )

        XCTAssertEqual(
            url.absoluteString,
            "https://huggingface.co/owner/model-name/resolve/abc123/tokenizer%20files/vocab.json?download=true"
        )
    }

    func testPinnedQwenDownloadURLAllowsRepositoryComponentPeriod() throws {
        let file = AdModelManifest.qwen35FourBitV1.files[0]

        let url = try AdModelDownloadPolicy.remoteURL(
            for: file,
            manifest: .qwen35FourBitV1
        )

        XCTAssertEqual(
            url.absoluteString,
            "https://huggingface.co/mlx-community/Qwen3.5-4B-MLX-4bit/resolve/32f3e8ecf65426fc3306969496342d504bfa13f3/chat_template.jinja?download=true"
        )
    }

    func testDownloadedModelFileIsVerifiedBeforeAtomicInstallation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdRemovalModelInstallTests-\(UUID().uuidString)", isDirectory: true)
        let incoming = directory.appendingPathComponent("incoming.bin")
        let validData = Data("verified-model-file".utf8)
        let manifest = AdModelManifest(
            repository: "owner/model",
            revision: "abc123",
            files: [
                AdModelFile(
                    relativePath: "weights/model.bin",
                    byteCount: Int64(validData.count),
                    sha256: "690b827558b9a58429cc1003c914862993f319388e135163aa3c1a1a018a61dc"
                )
            ]
        )
        let store = try AdModelAssetStore(rootURL: directory.appendingPathComponent("Models"))
        let destination = try store.fileURL(for: manifest.files[0], manifest: manifest)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("tampered-model-file".utf8).write(to: incoming)

        XCTAssertThrowsError(try store.installDownloadedFile(
            from: incoming,
            file: manifest.files[0],
            manifest: manifest
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

        try validData.write(to: incoming)
        let installed = try store.installDownloadedFile(
            from: incoming,
            file: manifest.files[0],
            manifest: manifest
        )

        XCTAssertEqual(installed, destination)
        XCTAssertEqual(try Data(contentsOf: installed), validData)
        XCTAssertEqual(try store.downloadedByteCount(manifest: manifest), Int64(validData.count))
    }

    func testModelDownloadPlanSkipsValidatedFilesAndRetriesMissingOrCorruptFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdRemovalModelPlanTests-\(UUID().uuidString)", isDirectory: true)
        let manifest = AdModelManifest(
            repository: "owner/model",
            revision: "abc123",
            files: [
                AdModelFile(
                    relativePath: "config.json",
                    byteCount: 6,
                    sha256: "b79606fb3afea5bd1609ed40b622142f1c98125abcfe89a76a661b0e8e343910"
                ),
                AdModelFile(
                    relativePath: "weights.bin",
                    byteCount: 7,
                    sha256: "9a129038d9a00aed0cf6a7ea059ca50a813449061ab87848cf1a13eafdf33b2c"
                ),
                AdModelFile(
                    relativePath: "tokenizer.json",
                    byteCount: 9,
                    sha256: "55525e31be2392f18c638d95ba6464c7bf92ac7529c46f60ec84b1136877fb79"
                )
            ]
        )
        let store = try AdModelAssetStore(rootURL: directory)
        try store.installForTesting(Data("config".utf8), at: "config.json", manifest: manifest)
        try store.installForTesting(Data("corrupt".utf8), at: "weights.bin", manifest: manifest)

        let pending = try AdModelDownloadPlan.pendingFiles(manifest: manifest, assetStore: store)

        XCTAssertEqual(pending.map(\.relativePath), ["weights.bin", "tokenizer.json"])
    }

    func testModelTaskCompletionAdvancesOnlyValidatedFilesAndIgnoresExplicitCancellation() {
        XCTAssertTrue(AdModelTaskCompletionPolicy.shouldScheduleNext(
            fileValidated: true,
            completionError: nil
        ))
        XCTAssertFalse(AdModelTaskCompletionPolicy.shouldScheduleNext(
            fileValidated: false,
            completionError: nil
        ))
        XCTAssertFalse(AdModelTaskCompletionPolicy.shouldScheduleNext(
            fileValidated: true,
            completionError: URLError(.networkConnectionLost)
        ))
        XCTAssertFalse(AdModelTaskCompletionPolicy.shouldRecordFailure(
            error: URLError(.cancelled),
            cancellationRequested: true
        ))
        XCTAssertTrue(AdModelTaskCompletionPolicy.shouldRecordFailure(
            error: URLError(.cancelled),
            cancellationRequested: false
        ))
    }

    func testModelExistingTaskPolicyCancelsStaleFailedTasksBeforeRetrying() {
        XCTAssertTrue(AdModelExistingTaskPolicy.shouldCancelExistingTasks(downloadState: "failed"))
        XCTAssertFalse(AdModelExistingTaskPolicy.shouldCancelExistingTasks(downloadState: "downloading"))
        XCTAssertFalse(AdModelExistingTaskPolicy.shouldCancelExistingTasks(downloadState: "consented"))
        XCTAssertFalse(AdModelExistingTaskPolicy.shouldCancelExistingTasks(downloadState: "ready"))
    }

    func testMLXClassifierUsesPinnedTextOnlyNonThinkingConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdRemovalMLXTests-\(UUID().uuidString)", isDirectory: true)
        let store = try AdModelAssetStore(rootURL: directory)
        let classifier = MLXQwenAdClassifier(assetStore: store, manifest: .qwen35FourBitV1)

        XCTAssertEqual(classifier.descriptor, AdClassifierDescriptor(
            modelID: "mlx-community/Qwen3.5-4B-MLX-4bit",
            modelRevision: "32f3e8ecf65426fc3306969496342d504bfa13f3",
            quantization: "4-bit",
            promptRevision: "ad-classifier-v1",
            maximumContextTokens: 8_192,
            maximumOutputTokens: 1_024,
            temperature: 0,
            topP: 1
        ))
        XCTAssertFalse(classifier.includesVisionInput)
        XCTAssertFalse(classifier.enablesThinking)
    }

    func testGoldenCorpusEvaluatorEnforcesSecondBasedAccuracyAndSafetyGates() throws {
        let episodes = makeGoldenCorpusEpisodes()

        let report = try AdRemovalGoldenCorpusEvaluator().evaluate(episodes: episodes)

        XCTAssertEqual(report.episodeCount, 10)
        XCTAssertEqual(report.subscriptionCount, 5)
        XCTAssertEqual(report.labeledAdSeconds, 200, accuracy: 0.001)
        XCTAssertEqual(report.skippedAdSeconds, 190, accuracy: 0.001)
        XCTAssertEqual(report.adSecondsRecall, 0.95, accuracy: 0.000_001)
        XCTAssertEqual(report.labeledContentSeconds, 800, accuracy: 0.001)
        XCTAssertEqual(report.incorrectlySkippedContentSeconds, 8, accuracy: 0.001)
        XCTAssertEqual(report.contentSecondsFalseSkipRate, 0.01, accuracy: 0.000_001)
        XCTAssertTrue(report.allRangesTraceable)
        XCTAssertTrue(report.allFalseSkipsReversible)
        XCTAssertTrue(report.passes)
    }

    func testGoldenCorpusEvaluatorFailsUnknownEvidenceAndIrreversibleFalseSkip() throws {
        var episodes = makeGoldenCorpusEpisodes()
        let original = episodes[0]
        episodes[0] = AdRemovalCorpusEpisodeEvaluation(
            episodeID: original.episodeID,
            subscriptionID: original.subscriptionID,
            durationSeconds: original.durationSeconds,
            transcriptSegmentIDs: original.transcriptSegmentIDs,
            labels: original.labels,
            predictedSkipRanges: [
                AdRemovalCorpusPrediction(
                    startTime: 0,
                    endTime: 20.8,
                    sourceSegmentIDs: ["invented-segment"],
                    reversibleByUndo: false
                )
            ]
        )

        let report = try AdRemovalGoldenCorpusEvaluator().evaluate(episodes: episodes)

        XCTAssertFalse(report.allRangesTraceable)
        XCTAssertFalse(report.allFalseSkipsReversible)
        XCTAssertFalse(report.passes)
    }

    func testGoldenCorpusLoaderRejectsPathsOutsideLocalCorpusRoot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdRemovalCorpusLoaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let index = AdRemovalCorpusIndex(
            schemaVersion: AdRemovalCorpusFormat.schemaVersion,
            episodes: (0..<10).map { index in
                AdRemovalCorpusIndexEpisode(
                    episodeID: "episode-\(index)",
                    subscriptionID: "subscription-\(index % 5)",
                    audioFile: "../outside.mp3",
                    labelsFile: "labels/episode-\(index).json",
                    transcriptFile: "transcripts/episode-\(index).json",
                    resultFile: "results/episode-\(index).json"
                )
            }
        )
        let indexURL = directory.appendingPathComponent("corpus.json")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        try encoder.encode(index).write(to: indexURL)

        XCTAssertThrowsError(try AdRemovalGoldenCorpusLoader().load(indexURL: indexURL)) { error in
            guard let corpusError = error as? AdRemovalCorpusError else {
                return XCTFail("Unexpected loader error: \(error)")
            }
            XCTAssertEqual(corpusError, .unsafeRelativePath("../outside.mp3"))
        }
    }

    func testCommittedGoldenCorpusFixtureUsesVersionedRedactedFormat() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtureRoot = repositoryRoot.appendingPathComponent(
            "dev/fixtures/ad-removal-corpus-v1",
            isDirectory: true
        )
        let decoder = JSONDecoder()
        let index = try decoder.decode(
            AdRemovalCorpusIndex.self,
            from: Data(contentsOf: fixtureRoot.appendingPathComponent("corpus.example.json"))
        )
        let labels = try decoder.decode(
            AdRemovalCorpusLabelsFile.self,
            from: Data(contentsOf: fixtureRoot.appendingPathComponent("labels/synthetic-episode.json"))
        )
        let transcript = try decoder.decode(
            AdRemovalCorpusTranscriptFile.self,
            from: Data(contentsOf: fixtureRoot.appendingPathComponent("transcripts/synthetic-episode.json"))
        )
        let result = try decoder.decode(
            AdRemovalCorpusResultFile.self,
            from: Data(contentsOf: fixtureRoot.appendingPathComponent("results/synthetic-episode.json"))
        )

        XCTAssertEqual(index.schemaVersion, AdRemovalCorpusFormat.schemaVersion)
        XCTAssertEqual(index.episodes.count, 1)
        XCTAssertEqual(index.episodes.first?.episodeID, "synthetic-episode")
        XCTAssertEqual(labels.ranges.map(\.classification), [.content, .advertisement])
        XCTAssertEqual(transcript.segmentIDs, ["segment-content", "segment-ad"])
        XCTAssertEqual(result.ranges.count, 1)
        XCTAssertEqual(result.ranges.first?.sourceSegmentIDs, ["segment-ad"])
        XCTAssertTrue(result.ranges.first?.reversibleByUndo == true)
    }

    private func makeGoldenCorpusEpisodes() -> [AdRemovalCorpusEpisodeEvaluation] {
        (0..<10).map { index in
            AdRemovalCorpusEpisodeEvaluation(
                episodeID: "episode-\(index)",
                subscriptionID: "subscription-\(index % 5)",
                durationSeconds: 100,
                transcriptSegmentIDs: ["ad-\(index)", "content-\(index)"],
                labels: [
                    AdRemovalCorpusLabel(startTime: 0, endTime: 20, classification: .advertisement),
                    AdRemovalCorpusLabel(startTime: 20, endTime: 100, classification: .content)
                ],
                predictedSkipRanges: [
                    AdRemovalCorpusPrediction(
                        startTime: 0,
                        endTime: 19,
                        sourceSegmentIDs: ["ad-\(index)"],
                        reversibleByUndo: true
                    ),
                    AdRemovalCorpusPrediction(
                        startTime: 20,
                        endTime: 20.8,
                        sourceSegmentIDs: ["content-\(index)"],
                        reversibleByUndo: true
                    )
                ]
            )
        }
    }

    private func correction(id: String, text: String, createdAt: Int64) -> AdCorrection {
        AdCorrection(
            id: id,
            podcastID: 1,
            sourceEpisodeID: 2,
            transcriptWindow: text,
            classificationContext: "false positive",
            classifierVersion: "qwen-test",
            promptVersion: "prompt-1",
            createdAt: createdAt,
            active: true
        )
    }

    private struct ClassificationHarness {
        let database: PodsDatabase
        let store: AdRemovalJobStore
        let artifactStore: AdRemovalArtifactStore
        let episodeID: Int64
        let job: AdRemovalJob
    }

    private func makeClassifyingHarness() throws -> ClassificationHarness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdRemovalClassificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
        let episodeID = database.lastInsertRowID()
        let store = AdRemovalJobStore(database: database, now: { 1_000 })
        let queued = try store.enqueue(episodeID: episodeID)
        _ = try store.transition(jobID: queued.id, to: .downloading)
        _ = try store.transition(jobID: queued.id, to: .downloaded)
        _ = try store.transition(jobID: queued.id, to: .transcribing)
        let segments = (0..<4).map { index in
            AdTranscriptSegment(
                id: "segment-\(index)",
                index: index,
                language: "en-US",
                startTime: Double(index * 10),
                endTime: Double((index + 1) * 10),
                text: "Transcript \(index)"
            )
        }
        _ = try store.recordTranscript(
            jobID: queued.id,
            segments: segments,
            transcriberVersion: "speech-v1"
        )
        let job = try store.transition(jobID: queued.id, to: .classifying)
        return ClassificationHarness(
            database: database,
            store: store,
            artifactStore: try AdRemovalArtifactStore(rootURL: directory.appendingPathComponent("AdRemoval")),
            episodeID: episodeID,
            job: job
        )
    }
}
