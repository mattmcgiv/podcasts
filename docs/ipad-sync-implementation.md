# iPhone and iPad implementation and rollout

Authorized September 19, 2026. The existing browser origin and IndexedDB remain intact; the native iOS app remains deprecated.

## Implemented

- Shared progress, including intentional rewinds; played state; subscriptions; speed, autoplay, theme, last-listened episode, and dismissed notifications. Download quotas and audio remain local to each device.
- Durable outbox with immutable sent IDs and acknowledgement-only removal. Independent field conflicts preserve edits and show local/shared values with writer names. Equal edits merge without creating false conflicts. Active playback retains its original progress revision even when a newer snapshot arrives.
- Position saves every five seconds, on pause/seek, and when leaving the page. Foreground, reconnect, manual, and bounded pre-play sync refresh shared state. Active playback never jumps to a remote position.
- Continue listening prioritizes the current episode's download. iPad portrait, landscape, and split-screen layouts; device labels; readable sync status; metadata backup export without audio or credentials.
- Caddy binds only to the connected Tailscale address, retaining the existing HTTPS hostname/certificate and passkey authentication. Rust stays on loopback. A Tailscale outage stops the external listener without changing DNS to a LAN/public address.
- Jev uses the complete transcript in one request when it fits, otherwise larger contiguous batches. Explicit per-segment questions retain timestamps and full coverage. Explicit context-limit errors split batches recursively; other failures retain ordinary retry behavior. Checkpoints and classifier cache identities include the new version.

WebKit can reject playback after awaiting network sync. On a `NotAllowedError`, the next Play tap calls the existing audio element synchronously. This avoids repeatedly consuming the new user gesture in another async sync. Physical iOS playback still needs verification. [WebKit user gesture requirements](https://webkit.org/blog/6784/new-video-policies-for-ios/).

## Jev comparison

Model: `jev-1.13.0`. Classifier identity: `pods-jev-v2-segment-questions-bytes48k-128k-context12-threshold50`.

TypeSafe documents 64k total context and 32k state plus the longest question. The implementation uses conservative serialized-byte budgets, not an exact tokenizer, with explicit oversize-error fallback. A whole 69-minute request was rejected by the API. The 10.7-minute episode fit in one request. [Official model limits](https://docs.typesafe.ai/models.md).

| Episode | Duration | Requests, old → new | Measured seconds, old → new | Input tokens, old → new |
| --- | --- | --- | --- | --- |
| Jocko Underground (24979) | 10.7 min | 7 → 1 | 2.758 → 0.792 | 46,578 → 36,650 |
| Modern Wisdom / Stan Tatkin (24355) | 69 min | 42 → 7 | 19.982 → 5.614 | 314,709 → 253,741 |
| Deep Questions / Cal Newport (20687) | 80 min | 55 → 9 | 24.735 → 7.154 | 417,790 → 338,230 |

Across these episodes: 104 → 17 requests, 47.475 → 13.560 seconds, and 19.3% fewer input tokens. Reviewed transcript spans contain 425.16 seconds of editorial material and 688.98 seconds of ads. Editorial material incorrectly classified as ads fell from 127.22 seconds to zero; missed ads fell from 37.14 seconds to 1.46 seconds. These are manually reviewed transcript spans, not an audio audit or a general accuracy estimate. Mixed/uncertain boundaries were excluded. An earlier indexed-question candidate performed poorly and was discarded.

Raw evaluation reports and reviewed spans are outside Git in `~/.local/share/pods/jev-evaluation-20260919/`; final report suffix is `-release.json`, aggregates are `summary.json`. `pods-evaluate-jev` supports `legacy`, `adaptive`, and `whole` without modifying live episode caches. Show notes remain on local oMLX. Existing publications are preserved.

## Verification and rollout

- Frontend: 330 tests pass; statement coverage 90.75%, function coverage 91.64%, line coverage 94.66%. Tests cover lost acknowledgements, in-flight edits, immutable retries, missing acknowledgements, conflicts, rewind revisions, migration, and direct-gesture playback retry.
- Rust: full suite with `--features passkey -- --test-threads=1`: 390 passed, 7 ignored. Subsequent Jev timing-accounting change passes 10 focused Jev tests. Serial execution avoids pre-existing process-global oMLX test interference.
- Python: 44 tests pass, including Tailscale failure handling and listener/DNS behavior. Manager-specific suite: 32 passed after the standalone CLI environment fix.
- Browser fixture: checked portrait 834×1112, landscape 1194×834, and split width 375×812. This verifies layout; fixture audio was synthetic and does not prove real-device playback.
- Online SQLite backup, prior release path, private manager config, Caddyfile, and prior tailnet policy are in `~/.local/share/pods/backups/ipad-sync-20260919/`. SQLite backup integrity was verified.
- Backend activated on the Mac; release `20260919-074614`. HTTPS `/api/auth/status` returned 200, unauthenticated `/api/sync` returned 401, `/api/internal/status` returned 404, and an unrelated Origin returned 403. Listener checks confirmed Tailscale-only 8443 and loopback-only 18180.
- Client published through Chrome to the existing production Pages project. The public index, service worker, JavaScript and CSS matched the tested build byte for byte. Closing and reopening the browser tab activated the new client without clearing site data; its prior 10 downloaded episodes were visible before synchronization. Authenticated live-browser synchronization subsequently succeeded with zero pending changes. Normal server reconciliation then refreshed its library and local download queue.
- Physical iPhone/iPad handoff and cellular access remain unverified. After client publication, sync the existing iPhone browser first, then the iPad. Test pause/resume in both directions, deliberate rewind, simultaneous offline edits/conflict resolution, and downloaded playback with Tailscale off. Do not clear site data.

## Machine setup

Official standalone Tailscale 1.102.4 is installed. Saved tailnet grants permit only the phone and tablet to the Mac's TCP 8443. Policy tests deny their access to ports 22 and 18180. Mac accepts no tailnet DNS override and uses no exit node.

Mullvad was disconnected with user approval; the user will reconnect it when needed. For airline Wi-Fi, disconnect both VPNs before portal sign-in, then enable Tailscale only when needed. Tailscale VPN On Demand can exclude airline SSIDs with **Except On**. This Pods hostname is not a `*.ts.net` on-demand trigger. Offline downloads and queued edits work while VPNs are off. [Tailscale iOS VPN On Demand](https://tailscale.com/kb/1291/ios-vpn-on-demand).

After the user approved Finder authentication, ProtonVPN.app is absent from Applications and no ProtonVPN process or VPN network configuration remains. macOS still reports the WireGuard extension as activated/enabled; removal of that residual registration is not yet verified. System Settings did not apply the attempted disable action. Proton Mail, Proton Drive, and the Mail uninstaller are present in Applications; an accidental Finder move of those three apps was immediately reversed. Their data was not deleted.

## Recovery

The prior working release is `20260918-183621`. Restore the `current` symlink and restart the LaunchAgent for binary rollback, together with the prior transport config/DNS policy if reverting from Tailscale. Shared-state schema changes are additive. Do not replace the live SQLite database with the pre-rollout backup merely to roll back code: doing so would discard subsequent user edits. Keep browser storage and outboxes intact.

The worktree baseline `30e317f` is a private checkpoint of pre-existing dirty edits. Task changes are the diff after that baseline; preserve unrelated main-checkout work during integration.

Prepared Pages upload: `/tmp/pods-ipad-sync-pages.zip`. SHA-256: `f54e0315a348fbdbca1ba5aea54297d1a4586f0668d260fc960fa3e71bb53be7`. Published successfully; temporary upload zip removed after verification.

Public service-worker SHA-256: `e1a8257362d81f3b1a97aa5ee0ac75ff95495479bddfbf38a345fcf5ecde907f`. Main JS: `125221d94c7d3fc99e82a9cfa32e1689007ec87d9004c1a37ab9e8864544a5d2`.

Post-publication check found Caddy absent even though a fresh Tailscale status probe reported Running/Online. A graceful LaunchAgent restart restored HTTPS, followed by successful authenticated Chrome synchronization. Repeated HTTPS checks remained successful afterward; the original stopped-listener cause is not established. Physical handoff/cellular verification is still pending user testing.

ProtonVPN-only cache, group container, app container, and transparent-proxy container were moved to `~/.Trash/ProtonVPN leftovers 20260919/` for recoverability. Mail and Drive paths were preserved. The residual macOS WireGuard extension registration remains unresolved.

## September 19 sync outage fix

The stopped HTTPS listener was traced to leaked SQLite connections in `omlx_has_pending_inference`. The live manager held file descriptors through 255, mostly repeated database/WAL handles. The exhausted process could no longer launch the Tailscale CLI; its failed probe stopped Caddy. Python's SQLite transaction context does not close a connection. The probe now uses `contextlib.closing` on both success and query failure.

Regression test failed on the old code in all three cases (pending, idle, SQL error), then passed. The deployed-source Python suite passed 45 tests; the isolated upstream fix passed 44 tests. A 1,000-poll stress check with garbage collection disabled and a 64-file-descriptor limit retained exactly four open handles throughout.

Deployed release: `20260919-141810`. HTTPS resumed, and the running manager retained zero database handles between polls. The server subsequently accepted an iPad progress update and its played-state change. No listening-state rows were manually changed. iPhone display verification remains with the user.
