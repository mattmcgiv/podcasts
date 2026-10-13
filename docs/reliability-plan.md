# Pods reliability and error reporting plan

Reduce failures and make every accepted request traceable through completion or an actionable failure. Implement the work below in order, in small independently useful changes. Planning baseline: 13 October 2026, commit `6b56ef5`. The implementation is tracked below; runtime and deployment evidence is recorded separately from test results.

## Evidence and scope

The two missing Max Jolliffe videos exposed different defects: a render produced truncated audio, and a metadata lookup exhausted retries and deleted its queued submission. The render fix is committed in `6b56ef5`. At this review, episode 26687 was `ready` with a browser publication; episode 26738 was `transcribing` without one. Five other pending jobs were blocked: two DNS errors, two generic YouTube download errors, and one HTTP 403. These are current backlog counts, not a measured failure rate.

Verified gaps in current code:

- `backend/src/local_worker.rs::drain_youtube_listen` discards the error and removes a submission after four failures. Article intake follows a similar queue pattern. Both store queues as JSON in settings and rewrite the list; concurrent additions need a regression test for lost updates.
- `backend/src/browser_schema.sql` records current job state and a bounded set of notifications, but a submission cannot have an episode-linked notification before its episode exists. Current job rows lack stage start and heartbeat timestamps.
- The menu bar reads `browser_pending_jobs` directly and independently interprets stage/error strings in `mac/PodsSpeaker/PipelineMenu.swift`. The browser receives counts and selected notifications from `backend/src/browser.rs`. These do not provide the same complete view.
- `client/src/offline/Controls.tsx` suppresses local refresh failures and can leave the user looking at an indefinite loading state. Sync, download, and action messages also compete for one status slot.

Scope includes submission, download, processing, publication, browser sync, offline download, and playback. Keep Rust as the backend, SQLite as local persistence, the existing Mac service, and the React client. Preserve downloaded media, local changes, and the npm container boundary. No deprecated iOS work, new cloud monitoring service, or framework rewrite.

## 1 Preserve submissions and explain failures

Create durable intake rows with a stable submission ID, canonical source identity, timestamps, optional episode ID, state, attempts, next retry, error code, and safe diagnostic detail. Migrate existing queued links without dropping them. Accept a request only after its row commits; respond with its ID and say “Queued for processing.” Duplicate submissions and retries after an ambiguous HTTP response must return the existing work rather than create duplicate episodes.

Replace whole-list queue rewrites with transactional row claims and transitions. Do external work outside database transactions. Keep exhausted submissions as needs-attention records until explicitly dismissed or retried. Capture subprocess exit status and bounded, redacted stderr, including metadata lookup and media download failures. Persist failure and its notice together. Database write failures must themselves be surfaced.

Acceptance: failed metadata lookup remains visible before an episode exists; concurrent submissions survive; restart resumes pending work; retrying an accepted request creates one episode. Tests inject lookup failure, write failure, duplicate request, and concurrent enqueue/claim.

## 2 Share one status and recovery model

Expose a Rust status projection used by both the menu bar and browser. Represent queued, working, waiting, retry scheduled, needs attention, published, and cancelled explicitly. Include current stage, last progress time, attempt count, next retry, safe explanation, and supported action. Preserve Processing, Queue, and Stuck in the menu, with pauses in Queue. Distinguish a fresh local observation from the browser's last synchronized snapshot.

Show a persistent activity list for accepted submissions and affected episodes. Each failure answers: what failed, whether work is retained, what happens next, and what the user can do. Supply Retry and diagnostic-copy actions where supported. A dismissed notice must not cancel work or hide an unresolved failure from the full list. Retain Troubleshoot (AI) as an optional action. Avoid repeated notices for the same unresolved incident.

Make sync, download, playback, storage, and backend-connection failures independently visible. Replace swallowed refresh errors with recoverable UI states. Keep offline playback usable and label stale status with its timestamp.

Acceptance: injected intake, processing, sync, and local-storage failures have consistent messages and recovery behavior; success clears current failure state while retaining bounded history. Verify menu behavior and browser behavior, including offline/reconnect and iPhone-width rendering.

## 3 Recover temporary failures without wasting work

Classify errors at their source: transient network/service failures, explicit pause/resource waits, permanent source failures, and processing defects. Give transient errors bounded exponential backoff with jitter and a longer retry window; do not consume failure attempts while intentionally paused. Make next retry visible. Refresh expired source metadata where appropriate before retrying a 403; do not blindly treat every 403 as temporary or permanent.

Record stage start, heartbeat/progress, and worker ownership. Add stage-specific subprocess deadlines and cancellation that reaps children. Recover interrupted claims on service startup. Detect stalled work using progress and ownership, accounting for long videos and intentional waits; avoid a universal timeout that kills healthy transcription.

Resume from validated downloaded media, transcripts, and completed stages. Preserve useful artifacts after failures. Write new artifacts to temporary paths, validate them, then atomically publish them. Reconcile publication records and files after interruption. Keep the audio/video duration regression test and extend coverage only for demonstrated failure boundaries.

Acceptance: temporary DNS failure recovers without intervention; permanent failure stays actionable; killing a worker resumes safely without duplicate publication; failed show notes do not force a fresh download/transcription; a repeated deterministic render failure stops with useful evidence.

## 4 Measure and fix the recurring causes

Store a bounded local event history keyed by submission, episode, stage, and attempt. Record transition, duration, error code, retry outcome, and service/tool versions. Exclude credentials, full signed URLs, content payloads, and raw unrestricted logs. Offer one diagnostic export covering backend health, queue age, relevant events, versions, and browser sync/download state.

Track terminal failures per accepted submission, first-attempt success, eventual publication, stage latency, oldest eligible queued item, stalled jobs, retry recovery, and sync/download failures. Separate expected waits and cancellations from failures. Rank recurring causes by affected submissions and user impact; use that list to drive small fixes to intake, rendering, sync, downloads, and playback.

Start collecting immediately with step 1; review the first seven days after instrumentation. Success means zero silently lost accepted submissions, every unresolved failure has a visible reason and action, and measured failure rates and manual recoveries fall from the baseline. Set numeric reliability targets after a denominator exists. The observation period does not block shipping fixes.

## Delivery and verification

Ship each step incrementally. Use focused Rust tests and `cargo test --features passkey` for backend changes; run relevant Swift tests for menu changes and `dev/check.sh` inside the established container workflow for client changes. Exercise failure injection in isolated fixtures, never by corrupting the live library. Reuse existing libraries and check official documentation against installed versions before changing APIs or command flags.

Install and restart changed Mac backends in the same implementation turn; replace menu builds in `/Applications`; deploy client changes through the documented Cloudflare Pages upload. Verify the running version and actual acceptance/status/retry/publication flow separately from test results. Check browser sync and downloaded playback without clearing site data. Commit and push each implementation increment. No additional approval committee, soak-time gate, or broad rewrite is required.

Technical references: [SQLite transaction semantics](https://www.sqlite.org/lang_transaction.html) inform atomic state changes; [official yt-dlp options](https://github.com/yt-dlp/yt-dlp#usage-and-options) inform subprocess diagnostics, retries, and timeouts. Verify the installed yt-dlp version before adopting flags.

## Implementation details

Durable intake is in `backend/src/reliability.rs`. Existing settings queues migrate transactionally into `browser_intake`. Exhausted requests remain available for retry. Episode work uses the existing content-bound checkpoints, with heartbeat and progress timestamps, stage events, bounded diagnostics, and longer retries for network failures. Disk-space waits do not consume failure attempts. Forbidden podcast enclosures can be refreshed from the source feed before retrying.

The same status projection serves the menu at `GET /api/internal/pipeline` and authenticated browsers at `GET /api/pipeline`, and is included in offline sync snapshots. Retry uses the corresponding `/retry` endpoint and a stable item ID. Internal routes accept loopback connections only and reject browser origins. The menu includes Retry, Copy details, and Show all unresolved issues. Browser Settings includes Processing activity and Export diagnostics; Listen links to unresolved activity even after legacy notifications are cleared. Status timestamps identify cached observations.

`backend/src/child_process.rs` bounds captured output, deadlines, and process-group cleanup for YouTube and render tools. Transcription and synthesis retain their resource preemption and have four-hour ceilings. Startup reconciliation detects missing or truncated published media, preserves notes, and queues rebuilding; reused artifacts are verified by hash. No user library reset is required.

Diagnostics export includes bounded stage events, durations, retry recoveries, failure causes, submission counts, build/pipeline/tool versions, last sync, pending-change count, and download progress. Browser event details and outbox content are omitted. Failure rates require observations after rollout; this implementation does not establish a measured reduction or schedule recurring reviews.

## Rollout verification on 13 October 2026

Implementation commit: `df3659e` on `origin/main`. The Mac backend was installed as release `20261013-100541` and restarted; the diagnostic endpoint reports that build revision, and the installed binary matches the release build. The signed menu bundle was replaced in `/Applications`, relaunched there, and its binary matches the release build. Its home-directory symlink remains intact.

Cloudflare Pages production reported Success through the logged-in Chrome dashboard. The public `pods.mcgiv.dev` HTML references `assets/main-DBZFxe-3.js`, matching the built client. Page and worker CSP checks passed. No project or DNS settings changed.

Validation passed: 621 Rust tests, 505 client tests with all 47 checked files meeting the coverage floor, and 17 Swift menu tests. The Rust suite includes retained lookup failures, duplicate and concurrent intake, atomic migration/write failure, interrupted claims, missing-media reconciliation, shared status, and internal-route restrictions. Browser checks used an isolated incognito fixture at 390px width: failure notice navigation, persistent activity/retry controls, offline error retention, diagnostics export, and service-worker media ranges. A muted synthetic two-second download played to completion with the Mac connection unavailable. The user's browser library and downloads were not cleared.

Live retries were accepted for the five previously blocked download jobs. Processing had resumed with worker events and no worker-level error at verification; publication of all five remains pending. Both Max Jolliffe episodes were already ready with finished publications. Physical iPhone playback and authenticated browser sync were not tested in this rollout. The isolated preview lacked local-network permission, so its browser checks cover offline behavior rather than a successful live sync. Native menu UI inspection timed out; the signed build, tests, running app path, and shared live API were verified. The yt-dlp version probe returned unavailable within its short diagnostic deadline; the ffmpeg version was recorded.
