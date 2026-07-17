# On-device ad removal design

Status: accepted v1 design as of 2026-07-16; implementation has not started.

## Goal

When Pods discovers a new podcast episode, it downloads the audio to the iPhone,
transcribes it locally into timestamped English text segments, classifies likely
advertising locally, and stores a skip manifest on the original audio timeline.
When the manifest is ready, Pods automatically skips those ranges during iPhone
or Mac playback and prefers the exact downloaded audio over a publisher stream.

All transcription, classification, correction learning, and durable feature
state live on the iPhone. The Mac remains a normal audio playback endpoint.

## V1 non-goals

- Physically cutting, remuxing, or re-encoding episode audio.
- FFmpeg or another audio-editing runtime.
- Non-English transcription or classification.
- Speaker diarization or word-level transcript timing.
- A transcript reader or manual pre-playback review workflow.
- Silence detection, acoustic boundary refinement, or fixed skip padding.
- A second transcription or classification pipeline on the Mac.
- AirPlay, AirPlay Receiver, or another Mac audio-route takeover.
- Lock-screen, headset, car, or Mac Undo controls.
- A UI for manually marking the start and end of a missed ad.
- Automatic processing of the existing unplayed backlog.
- Discovery or recommendation features.

## Product contract

### Setup and enrollment

- Ad removal is globally disabled by default.
- Enabling it establishes an enrollment cutoff and starts a Wi-Fi-only classifier
  model download after showing its exact size and receiving explicit consent.
- Once enabled, every subscribed episode first discovered after the cutoff is
  enrolled automatically. V1 has no per-podcast processing toggles.
- Existing episodes are not enrolled automatically, but any episode may expose a
  manual **Prepare ad-free** action.
- V1 raises the Pods iPhone deployment target from iOS 17 to iOS 26. The initial
  device and acceptance baseline is an iPhone 16 (`iPhone17,3`) on iOS 26.5.2.
- Pods Speaker keeps its existing macOS 14 deployment target.

### Network policy

- Episode audio downloads automatically over Wi-Fi or cellular.
- The classifier model and all model updates are Wi-Fi-only.
- Audio downloads use a background `URLSession`, are resumable, and survive app
  suspension or system termination through normal background-session recovery.
- A missing classifier model does not prevent episode audio from downloading or
  unfiltered playback from starting.

### Playback readiness

Tapping Play always starts immediately. Source priority is:

1. Downloaded audio with a ready skip manifest.
2. Downloaded audio without skipping when preparation is incomplete or failed.
3. The publisher stream when no downloaded audio is available.

Preparation status never becomes a playback gate. Autoplay follows the same
source rules for the next episode.

### Retention and disabling

- Episode audio, transcript segments, classifier output, and skip manifest remain
  while an episode is unplayed.
- Marking an episode played deletes those episode-specific artifacts.
- Replaying that episode from Played uses the publisher stream unless the user
  manually prepares it again.
- Compact podcast-specific correction examples survive played-episode cleanup.
- Disabling ad removal stops new enrollment, processing, and automatic skipping,
  but retains the model and existing artifacts so re-enabling is reversible.
- Settings provides a separate destructive action to delete the model, prepared
  episode artifacts, and correction memory.
- Unsubscribing deletes that podcast's episode artifacts and correction memory.

## Processing architecture

The durable pipeline is:

```text
feed discovery
  -> audio download
  -> Apple SpeechAnalyzer transcription
  -> Qwen transcript classification
  -> deterministic skip-manifest construction
  -> ready for iPhone and Mac playback
```

### Durable job state

Each enrolled episode has one durable job with a processing stage and an optional
blocking reason. The core stages are:

```text
queued -> downloading -> downloaded -> transcribing -> classifying -> ready
```

Blocking reasons include `model_required`, `storage_limit`, `low_power`,
`thermal_pressure`, and `playback_active`. A failure records the failed stage,
attempt count, stable error code, human-readable error, and retry eligibility.

Every transition is committed to SQLite before the coordinator starts the next
stage. Stages are idempotent and validate their input artifact before reusing it,
so expiration, app termination, reboot, and retry cannot create a false `ready`
state.

### Scheduling

- iOS feed refresh discovers work using the existing hybrid foreground and
  best-effort background behavior; no completion deadline is promised.
- Automatic work may run on battery power.
- Low Power Mode and serious or critical thermal pressure pause transcription and
  classification at the next safe boundary.
- Any active iPhone or Mac episode playback pauses transcription and
  classification to protect playback quality and phone-to-Mac stream stability.
- Pods processes one episode at a time, oldest enrolled unplayed episode first,
  matching the product's oldest-first Recent order.
- Opening Pods or tapping **Prepare ad-free** provides a predictable opportunity
  to continue queued work, but iOS may still interrupt it.

### Failure and retry

- Each failing stage retries automatically up to three times with backoff.
- A stage that exhausts its retries becomes `failed`; playback remains available
  through the normal unfiltered source fallback.
- **Retry** resumes from the earliest valid durable artifact instead of deleting
  successful earlier stages.
- If an episode is marked played while queued or processing, Pods cancels the job
  and performs played-episode cleanup.

## Transcription

- V1 uses Apple `SpeechAnalyzer` with `SpeechTranscriber` on iOS 26.
- The OS-managed English speech model runs on-device; V1 does not ship a separate
  Whisper model.
- Only finalized results are stored. Volatile partial results are unnecessary.
- Each transcript row contains a stable segment identifier, English language
  identifier, start time, end time, and text.
- Segment timestamps use the exact downloaded audio as their canonical timeline.
- V1 does not store speaker labels or require word-level timing.
- WhisperKit or another transcriber is reconsidered only when observed failures
  show that transcription quality materially limits end-to-end ad accuracy.

## Classification

### Initial model

- The classifier uses Qwen3-1.7B through MLX Swift with the official 4-bit MLX
  conversion behind an `AdClassifier` interface. It replaced Qwen3.5-4B after
  that model exceeded the iPhone's per-process memory limit during inference.
- The initial configuration is text-only, vision disabled, non-thinking mode,
  and an 8,192-token maximum context.
- Classification windows contain at most eight transcript segments with two
  segments of overlap, and generation is capped at 384 output tokens to bound
  the phone's inference-time memory peak.
- The pinned `Qwen/Qwen3-1.7B-MLX-4bit` artifact is approximately 930 MB decimal
  including tokenizer and configuration files.
- Transcription assets and the classifier are not deliberately kept resident at
  the same time.
- A smaller model remains the fallback if Qwen3-1.7B fails memory, thermal,
  latency, reliability, or golden-corpus accuracy gates.

### Input and output contract

- The classifier receives bounded, overlapping windows of timestamped transcript
  segments rather than a complete long episode.
- Podcast-specific false-positive examples are included within a fixed token
  budget as strong negative evidence.
- The classifier returns structured segment labels, confidence, and a short
  reason. It never invents playback timestamps.
- The output schema, prompt revision, model revision, quantization, and sampling
  parameters are versioned with every classification run.
- Output that fails schema validation is rejected and retried; malformed output
  never produces a manifest.
- Thresholds are tuned for aggressive ad recall subject to the accepted content
  loss guardrail in the accuracy gate.

### Model delivery and updates

- The exact model repository revision and every downloaded file checksum are
  pinned before activation.
- A model update is manual, Wi-Fi-only, displays its size, and requires explicit
  confirmation.
- An update applies to future classifications. Ready episodes are not
  automatically reprocessed.
- Locally AI may be used as a manual feasibility aid but is not a Pods runtime
  dependency.

## Skip manifest and corrections

### Manifest construction

- The classifier labels transcript segment identifiers as `ad` or `content`.
- Pods deterministically merges consecutive ad-labeled segments.
- A range starts at the first merged segment's start and ends at the last merged
  segment's end.
- V1 adds no padding, silence detection, or acoustic boundary pass.
- Each range records its segment bounds, confidence, reason, classifier version,
  prompt version, creation time, and disabled state.

### Aggressive policy and Undo

- V1 prioritizes ad-seconds removed over minimizing every false positive.
- Entering an enabled ad range causes an automatic seek to its end.
- The iPhone player shows one pending **Skipped _duration_ - Undo** action; a
  later automatic skip replaces the pending action.
- Undo seeks to the range start and disables that range for the current episode.
- Undo stores the corrected transcript window and classification context as a
  false-positive example for that podcast.
- The next classification for that podcast incorporates relevant corrections as
  strong but soft negative evidence. A correction is not a permanent exclusion
  rule and does not fine-tune the model.
- Corrections never cross podcast boundaries.
- Settings shows a per-podcast correction count and **Reset learned
  corrections**. V1 has no item-by-item correction editor; raw records remain
  inspectable through diagnostics.
- V1 does not provide positive feedback for a missed ad. That interaction is
  deferred until real use proves it is necessary.

## Playback timeline and source selection

- Original-audio time is canonical everywhere: transcript, manifest, progress,
  duration, scrubber, Now Playing, iPhone player, and Mac player.
- Pods does not synthesize an ad-free duration or remap progress to a shortened
  timeline.
- Playback progress advances to the end of a skipped range when the automatic
  seek succeeds.
- Starting or manually seeking into an enabled range triggers the same automatic
  skip. Undo is the explicit way to inspect and disable that range.
- Local and Mac playback share one pure skip policy and one iPhone-owned manifest
  lookup path.

## Mac playback parity

### Hard constraints

- Ad skipping must work for both iPhone-local and Mac output.
- The Mac must play the exact audio bytes downloaded and transcribed by the
  iPhone. A later publisher request may contain a different dynamically inserted
  ad timeline.
- Pods Speaker remains a normal macOS `AVPlayer` application. V1 must not use
  AirPlay, AirPlay Receiver, or any mechanism that takes over normal Mac use.
- The Mac does not run transcription, classification, correction learning, or a
  second skip engine.

### Live audio transport

- The iPhone exposes an authenticated, byte-range-capable LAN endpoint for the
  active downloaded episode.
- Pods Speaker gives that URL to its normal `AVPlayer` and retains no persistent
  Mac copy of the audio.
- The endpoint supports the HTTP methods and range semantics required by
  `AVPlayer`, rejects unauthenticated or non-paired access, and exposes only the
  specifically authorized episode.
- Pairing credentials and stream tokens are never written to logs.
- The existing cast audio keep-alive remains active while Mac output is selected,
  so screen lock is a supported operating state.

### Phone-driven skipping

- Pods Speaker reports original-audio position approximately four times per
  second while playing.
- The iPhone applies the same skip policy used for local playback and sends the
  existing absolute-seek command when a range is entered.
- The iPhone owns the in-app skipped-content notification and Undo, even when the
  Mac is producing sound.
- Mac media keys and Control Center retain their existing normal play/pause
  behavior; they do not gain Undo.

### Failure and reconnection

- If the control channel or live audio stream becomes unavailable, Pods Speaker
  pauses and reports that the iPhone is unavailable.
- It never falls back to publisher CDN audio for a prepared episode.
- The last confirmed original-audio position and prior play intent are retained.
- On reconnection, the Mac restores that position. It resumes automatically only
  if it was playing when the connection failed; a previously paused episode
  remains paused.

## Storage and cleanup

- Episode-specific ad-removal artifacts have a 10 GB aggregate cap, excluding the
  classifier model.
- Pods requires at least 10 GB of device free space before starting a new episode
  download or materializing another large stage output.
- When either limit blocks work, the job waits with `storage_limit`; Pods does not
  silently evict an unplayed prepared episode.
- Played and unsubscribed cleanup is transactional at the metadata level and
  retryable at the file level.
- Model and episode audio files are excluded from device backups because they are
  reproducible downloads. SQLite state and compact correction memory remain in
  the normal app container.

## V1 user interface

- Settings contains the global enable/setup control, model download progress and
  revision, storage use, destructive feature-data cleanup, and per-podcast
  correction counts/reset actions.
- Episode surfaces use compact states: **Preparing**, **Ad-free**,
  **Unfiltered**, and **Failed**.
- Failed and older episodes expose **Retry** or **Prepare ad-free** as applicable.
- The player contains the single pending Undo action after an automatic skip.
- V1 sends no system notification for preparation completion or failure.
- V1 has no transcript viewer, classifier review queue, detailed job dashboard,
  or per-podcast enable toggle.

## Persistence model

Exact migration SQL is an implementation detail, but the durable model requires:

- `ad_removal_jobs`: episode, stage, blocking reason, attempts, versions, byte
  counts, timestamps, last error, and artifact metadata.
- `ad_transcript_segments`: episode, stable segment index, language, original
  start/end time, and finalized text.
- `ad_skip_ranges`: episode, segment bounds, original start/end time, confidence,
  reason, detector versions, and disabled state.
- `ad_corrections`: podcast-scoped negative-example snapshot, context, source
  versions, creation time, and active state. It must survive source episode
  cleanup.
- Model state in the existing settings system: enabled cutoff, active model
  revision, checksums, download state, and aggregate storage accounting.

Large audio and model files live under a dedicated Application Support subtree.
SQLite stores validated relative paths and checksums, never unaudited absolute
paths supplied over the network.

## On-device diagnostics

Copious diagnostics are a v1 requirement because model, background, media, and
LAN failures need to be reproduced and iterated on quickly.

### Logging foundation

- Replace the current expired `PodsTemporaryDebugLog` behavior for this feature
  with a permanent, bounded `AdRemovalDiagnostics` subsystem.
- Emit structured events to both `OSLog` and rotating JSON Lines files in the app
  container.
- Default retention is five 10 MB files (50 MB total) plus the ten most recent
  per-job diagnostic snapshots. Retention is deterministic and test-covered.
- Every event includes timestamp, event name, severity, app/build version,
  pipeline job ID, episode ID when available, podcast ID when available, stage,
  attempt, and a cross-device playback session ID when applicable.
- Diagnostics remain enabled by default for v1, survive over-install/re-signing,
  and can be cleared explicitly from Settings.

### Required iPhone events

Log at least:

- Feature enable/disable, cutoff, model consent, download progress, revision,
  checksum validation, activation, and deletion.
- Job enqueue, every state transition and blocking reason, scheduler submission,
  background launch, expiration, cancellation, retry, and recovery.
- Episode request URL host with sensitive query data removed, response status,
  expected/received bytes, resume information, content type, duration, checksum,
  and final file path relative to the feature root.
- Speech asset readiness, analyzer start/finish, audio duration, wall time,
  segment count, rejected/empty ranges, cancellation, and error domain/code.
- Classifier model load/unload, window and segment IDs, input/output token counts,
  correction examples selected, latency, structured-output validation, label
  counts, confidence distribution, retry, and error domain/code.
- Manifest creation, merged segment IDs, range boundaries, disabled ranges,
  version metadata, and acceptance/rejection reason.
- Playback source selection, output device, original position, range entry, seek
  request, seek completion/latency, stale-event rejection, Undo, correction
  creation, and progress persistence.
- LAN listener lifecycle, pairing decision without credentials, authorized file
  identity, HTTP method, byte range, response status/bytes, stream stalls,
  disconnects, reconnects, and preserved play intent.
- Storage accounting, quota/free-space blocks, cleanup start/result, orphan
  detection, and cleanup retry.
- Low Power Mode and thermal-state transitions that pause or resume work.

### Accuracy snapshots and export

- For the ten most recent jobs, retain a local diagnostic snapshot containing
  transcript segments, the exact versioned classifier prompt/input, selected
  correction examples, raw classifier output, schema-validation result, final
  labels, and skip manifest. Do not duplicate the audio file in the snapshot.
- Snapshot text stays on-device unless the user explicitly exports diagnostics.
- Settings provides **Export ad-removal diagnostics**, producing one archive with
  iPhone structured logs, recent snapshots, schema/app/model versions, and a
  concise state summary.
- Pods Speaker writes corresponding rotating structured logs on the Mac using the
  same playback session ID, making phone and Mac events joinable by time/session.
- The development workflow includes a helper that collects the exported iPhone
  archive and current Mac log without requiring secrets in chat.

### Redaction and safety

- Never log Podcast Index credentials, pairing tokens, stream bearer tokens,
  model-download credentials, cookies, or complete signed URL query strings.
- Redaction occurs before data reaches either `OSLog` or the rotating file.
- Redaction, rotation, concurrent writes, snapshot retention, and export manifest
  contents require unit tests.

## Accuracy and release gates

### Evaluation corpus

- Build a local golden corpus from ten real episodes across at least five current
  subscriptions.
- Include host-read ads and dynamically inserted ads, with manually verified
  original-audio ad ranges.
- Keep the audio, labels, transcripts, and results local and out of Git.
- Use a committed metadata/fixture format with synthetic or redacted small test
  fixtures where automated tests need repository data.

### Accuracy gate

On the labeled corpus, the selected pipeline must:

- Skip at least 95% of labeled ad seconds.
- Incorrectly skip no more than 1% of labeled content seconds.
- Produce only ranges traceable to stored transcript segment IDs.
- Make every automatic false skip reversible through Undo.

### Device and playback gate

- Complete one representative episode end-to-end on the iPhone 16 without crash,
  corrupt durable state, or unrecoverable interruption.
- Verify local playback source selection, skips, seeks, progress, Undo,
  corrections, autoplay, played cleanup, Low Power pause, and thermal pause.
- Complete a two-hour Mac playback session with the iPhone on battery, Pods
  backgrounded, and the screen locked.
- During that Mac session, verify range serving, phone-driven skip latency, Undo,
  manual seek, pause/resume, speed, Wi-Fi interruption, disconnect, reconnect,
  position recovery, and prior play-intent restoration.
- Confirm Pods Speaker uses normal `AVPlayer` playback and never activates
  AirPlay or takes over normal Mac use.
- Confirm unfiltered immediate playback remains available at every incomplete or
  failed preparation state.

## Implementation sequence

Every code change follows Red/Green/Refactor. Production behavior is introduced
only after a failing focused test demonstrates the missing behavior.

1. **Diagnostics foundation**: structured event model, rotation, redaction,
   snapshots, export seams, and correlated Mac/iPhone session IDs.
2. **Persistence and coordinator**: SQLite migration, job state machine, blocking
   reasons, idempotent transitions, retry, and cleanup policies.
3. **Audio download and storage**: background session, cellular policy, resume,
   checksum, quotas, free-space guard, played/unsubscribe cleanup.
4. **Transcription**: injectable transcriber seam, fake-driven coordinator tests,
   `SpeechAnalyzer` adapter, cancellation/restart, and physical-device spike.
5. **Classification**: versioned classifier contract, structured-output parser,
   correction injection, MLX/Qwen adapter, malformed-output recovery, and golden
   corpus harness.
6. **Manifest and corrections**: deterministic segment merging, aggressive
   threshold, skip lookup, Undo, podcast-scoped soft feedback, and reset.
7. **iPhone playback and UI**: source priority, local file loading, skip engine,
   original timeline, compact states, immediate fallback, and cleanup behavior.
8. **Mac live streaming**: authenticated range server, protocol versioning,
   normal Mac `AVPlayer` source, four-Hz state, phone-driven seeks, failure, and
   reconnect/play-intent recovery.
9. **Background orchestration and setup**: global enable cutoff, Wi-Fi model
   delivery, iOS processing tasks, policy pauses, manual Prepare/Retry, and model
   cleanup/update flow.
10. **Acceptance and hardening**: golden-corpus thresholds, two-hour locked-phone
    Mac test, interruption matrix, diagnostic export review, full iOS/macOS test
    suites, and `dev/check.sh`.

## Deferred until evidence justifies them

- Acoustic boundary refinement or word-level timing.
- WhisperKit or another transcription runtime.
- A broad classifier model bakeoff.
- Per-podcast enrollment toggles.
- Item-by-item correction management.
- Positive feedback for missed ads.
- Lock-screen or remote-control Undo.
- Mac-side caching or Mac-side ML processing.
- An adjusted ad-free playback clock.
- System notifications or a detailed processing dashboard.
