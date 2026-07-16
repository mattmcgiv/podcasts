# Ad-removal v1 acceptance record

Date: 2026-07-16  
Branch: `feat/ad-removal`  
Accepted design: `docs/ad-removal-design.md` at `45b911e`

## Automated gates completed

- Client merge gate:
  `./dev/check.sh`
  - 84 tests passed.
  - 89.63% line coverage; the configured minimum is 80%.
- Complete iOS simulator suite:
  `xcodebuild -skipPackagePluginValidation -project ios/Pods.xcodeproj -scheme Pods -destination 'platform=iOS Simulator,id=02C63C27-27D5-40C9-AC3A-F73FE8EE413D' test`
  - 108 tests passed with no failures or skips on iOS 26.5.
- Pods Speaker macOS suite:
  `xcodebuild -project mac/PodsSpeaker.xcodeproj -scheme PodsSpeaker -destination 'platform=macOS' test`
  - 3 tests passed, covering protocol v2, progress cadence, legacy-message
    rejection, and position recovery.
- Physical-device architecture build for the paired iPhone 16:
  `xcodebuild -skipPackagePluginValidation -project ios/Pods.xcodeproj -scheme Pods -destination 'platform=iOS,id=F51CC28B-1C20-5F95-9E16-5A9238979720' CODE_SIGNING_ALLOWED=NO build`
  - The arm64 iPhoneOS build completed successfully.
- Golden-corpus helper contract:
  `sh dev/tests/evaluate-ad-removal-corpus.test.sh`
  - Usage/error behavior passed, and the helper compiled successfully against
    the standalone Swift evaluator.
- Diagnostics collection helper:
  `sh dev/tests/collect-ad-removal-diagnostics.test.sh`
  - The synthetic iPhone archive and Mac rotating log were collected without
    reading credentials or tokens.

## External acceptance checks still required

These checks cannot be completed in this local-only task without installing the
app, downloading user-approved assets, using private podcast data, or occupying
the physical devices for the prescribed session.

1. **Signed install and real-device pipeline.** A signed build currently stops
   with `Signing for "Pods" requires a development team.` The project needs a
   development team configured, followed by explicit authorization to install
   or launch the build on the iPhone. This task explicitly prohibited deploys.
2. **Model asset.** The pinned Qwen model is 3,061,129,077 bytes. It must be
   explicitly authorized in Settings and downloaded over Wi-Fi. The app verifies
   every pinned file's size and SHA-256 before activation; this task did not
   bypass consent or fetch the asset automatically.
3. **Real golden corpus.** Ten real episodes across at least five current
   subscriptions, including host-read and dynamically inserted ads, must be
   labeled locally. Audio, transcript text, labels, and results remain out of
   Git. Populate the committed v1 format documented in
   `dev/fixtures/ad-removal-corpus-v1/README.md`, then run:

   ```sh
   ./dev/evaluate-ad-removal-corpus.sh /absolute/path/to/corpus.json
   ```

   Exit `0` is required: at least 95% of labeled ad seconds skipped, at most 1%
   of labeled content seconds skipped, all ranges traceable to stored transcript
   segment IDs, and all false skips reversible by Undo.
4. **Representative iPhone episode.** On the signed iPhone 16 build with the
   model ready, verify download, SpeechAnalyzer transcription, MLX
   classification, local-source selection, skip seeks, original-timeline
   progress, Undo/correction memory, autoplay, played cleanup, Low Power pause,
   thermal pause, interruption/restart recovery, and immediate unfiltered
   fallback while preparation is incomplete.
5. **Two-hour locked-phone Mac session.** With the iPhone on battery, Pods
   backgrounded, and its screen locked, verify authenticated range serving,
   phone-driven skip latency, Undo, manual seek, pause/resume, speed, Wi-Fi
   interruption, disconnect/reconnect, position recovery, and restoration of
   prior play intent. Confirm Pods Speaker remains a normal `AVPlayer` client
   and does not activate AirPlay or take over the Mac.
6. **Diagnostic review.** After the two physical-device checks, export
   ad-removal diagnostics in Settings and combine them with the current Mac log:

   ```sh
   ./dev/collect-ad-removal-diagnostics.sh /path/to/pods-ad-removal-diagnostics.zip
   ```

   Review the joined playback session IDs, bounded log rotation, redaction,
   range/seek latency, reconnect events, and the ten retained accuracy snapshots.
