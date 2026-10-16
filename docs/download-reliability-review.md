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
