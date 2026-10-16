# Download reliability review — 16 October 2026

The reported failure was a completed download making the preceding episode show “Not downloaded.” This review covers the supported browser client and Rust Mac API, including how updated code reaches an already-open browser. The physical iPhone's active build and IndexedDB were not directly observable; the findings below distinguish reproduced defects from server checks.

## Findings and changes

| Area | Finding | Resolution and regression evidence |
| --- | --- | --- |
| Cleanup | A sweep could select a played episode, then delete its bytes after a newer unplayed change and another download completed. | Recheck current state inside the same IndexedDB transaction as deletion. A deferred-sweep test completes the next episode before releasing the old cleanup and verifies both files remain playable. |
| Storage budget | The earlier transfer path had its own eviction decisions. Automatic selection counted oversized episodes toward its episode limit. | Transfer admission never evicts an unplayed file. Cleanup has one guarded path. One planner reserves all complete/partial files and fills available slots with later fitting episodes. |
| Automatic refill | Marking played or increasing limits did not immediately restart automatic downloads. An overlapping pass could miss newly published episodes. | Queue events trigger refill immediately. Replan after each transfer and replay requests that arrived during a running pass. Tests require refill without a focus event, a Sync tap, or the minute timer. |
| Multiple tabs | Per-module promises coordinated only one page. Other pages could race budget decisions or retain stale UI state. | Web Locks serialize transfers across the origin. BroadcastChannel refreshes lists and plans. Playback holds a shared artifact lock; another tab's cleanup skips that file until playback closes. |
| Updates | A waiting service worker could leave the old eviction code active behind an open tab. | Activate only after the new offline shell is fully installed. Refresh loads the new shell. IndexedDB version 3 preserves every store and record while preventing version-2 clients from writing. Migration tests retain audio and reject the legacy writer. |
| List/UI | Queued episodes looked like work the user needed to start manually. | The downloader and list use the same automatic plan. Queued entries say “Waiting to download”; manual controls remain for retries and entries outside the selected/budgeted queue. The real list/storage test verifies earlier rows stay enabled after later completions and synchronization. |
| Snapshot identity | The client checked the audio URL/hash but not the episode-to-manifest identity or duplicate IDs. | Reject duplicate IDs, mismatched manifest episode IDs, invalid chunk geometry, and invalid hashes before adopting the snapshot. Existing downloads remain readable after rejection. |

## Server review

Reviewed `browser.rs` publication selection, replacement snapshots, action targeting and authenticated artifact ranges; `local_worker.rs` immutable publication generation; `browser_schema.sql` publication/artifact ownership; and the client's checksum/range validation and service-worker playback.

The live database contained 351 publications at inspection, with no duplicate current artifact hashes, no manifest/episode ID mismatches, and no multiple-artifact histories for the reported episodes. On The Brink 26709, All-In 26715, Peter Schiff 26718 and Market Disruptors 26719 each matched their published byte count, whole-file SHA-256 and every chunk hash on disk. Downloads do not mutate played state or publications. No server implementation change was justified by this evidence.

The new Rust regression publishes two different files, downloads them in alternating order with chunk ranges and `If-Range`, checks every chunk and whole-file SHA-256, and compares both episodes and their field revisions after each download. A played action changes only its target episode. Existing authentication, resumption, corruption, hidden-page pause, storage, range playback and sync tests remain in the full suites.

## Validation and rollout

- Client: `dev/check.sh` — 534 tests passed, plus TypeScript and global/per-file coverage. One existing speaker polling test failed on an intermediate full run; it passed both the targeted rerun and final full runs.
- Server: `cargo test --manifest-path backend/Cargo.toml --features passkey` — 624 passed. The feature is required by the existing authentication integration tests.
- Browser: upgrade the preceding production shell in an isolated library with existing 60 MiB and 30 MiB downloads. Verify both remain complete after migration, an old version-2 open fails, and marking the first played automatically completes the third 30 MiB episode while preserving the second and its HTTP 206 audio bytes.
- Client production uses the existing Cloudflare Pages project and local Chrome upload. See `mac-backend.md` for final deployed asset and runtime evidence.

No user library data was cleared. The app still needs an available Mac/network and a foreground browser to transfer new audio, and respects the user's episode count and storage limit. A stale page must be refreshed to load the repaired code. Future rollback builds must retain IndexedDB version 3 or later; older version-2 bundles intentionally cannot write this database.

## Follow-up: automatic downloads still stopped at the defaults

The preceding fix retained a 2 GiB / 50 episode default, even after the requested behavior became automatic downloads of the unplayed library. A read-only live-library check found 61 unplayed publications totaling 6.053 GiB. With an empty cache, the old default planner selected 23 and excluded 38. That explains a reproducible class of idle queues and Download buttons; the phone's supplied diagnostics did not include its actual preferences, so they do not independently confirm its limit. They contained no afternoon transfer errors, while the Mac recorded a recent iPhone sync.

New installs and exact legacy default settings now enable **Download all unplayed episodes**. Browser quota admission still applies, downloaded unplayed files are retained, and played cleanup supplies space. Non-default limits and explicitly disabled automatic queues remain custom. Legacy storage did not record whether the exact 2 GiB / 50 values had been manually chosen; the migration treats that pair as the old default. Settings lets the user switch between all-unplayed and custom limits without clearing audio.

Two startup dependencies also blocked automatic work: the queue waited for a successful metadata sync, and startup awaited an app-shell update even when an installed worker was already usable. The queue now starts from cached manifests independently, then replans after sync; an existing worker remains usable while the update succeeds, fails or stalls. Local diagnostics record the running build and queue settings, saved count, reserved bytes and pending count. Device failures are shown above the list.

A real production browser with an existing cache initially loaded `main-jzDPqmxB.js` while the installed shell updated to `main-B5vCUQ_J.js`; a subsequent navigation loaded the new app. Navigations now try current HTML with a three-second bound and fall back to the fully installed offline shell on failure. Existing already-open JavaScript still needs a refresh; the deployment does not force a reload during playback. API behavior was checked against the [service worker lifecycle documentation](https://web.dev/articles/service-worker-lifecycle) and [registration options](https://developer.mozilla.org/en-US/docs/Web/API/ServiceWorkerContainer/register).

Validation: `dev/check.sh` passed 540 tests, TypeScript, and all 47 per-file coverage checks. New regressions cover a 61-episode library beyond 2 GiB, legacy-default migration, retained custom/disabled limits, actual browser quota, cached downloads during failed sync/shell updates, stalled startup dependencies, and navigation freshness/offline fallback. In a real browser, the preceding production build downloaded exactly 50 of 61 fixture episodes and displayed 11 Download buttons. Upgrading completed all 61 with exactly 61 total artifact requests, zero Download buttons, 61 enabled episode rows, and HTTP 206 bytes readable from both the first and last files. The server implementation was unchanged in this follow-up.
