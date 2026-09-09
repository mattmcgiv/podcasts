# Mac backend and offline browser

## Supported architecture

The supported client is Chrome on iPhone at `https://pods.mcgiv.dev`. The native iOS app is deprecated.
The `ios/` source remains for history and migration. Native builds are not an acceptance gate for this architecture.

Cloudflare Pages serves the static client. The Mac supplies the library API while awake.
The phone and Mac must share a Wi-Fi network that permits communication between devices.
There is no public backend tunnel, VPN requirement, or cloud inference fallback.

| Component | Location | Responsibility |
| --- | --- | --- |
| React client | Cloudflare Pages | App shell and updates |
| IndexedDB and service worker | Phone browser | Library, pending edits, audio chunks, offline playback |
| Caddy | Mac Wi-Fi address, port 8443 | HTTPS and loopback proxy |
| Rust backend | Mac loopback, port 18180 | SQLite library, synchronization, processing queue |
| Whisper large-v3 FP16 | Mac, MLX | Local transcription with word timestamps |
| DeepSeek-V4-Flash-0731-2.4bit-mixed | Local oMLX endpoint | Ad classification and show notes |

The client never receives an episode before ad classification and audio rendering finish.
Playback uses an immutable AAC/M4A file with ads physically removed. There is no original-audio fallback or timer-based ad skipping.
The Mac retains the original audio and a mapping between original and processed timestamps.
Show notes use processed timestamps. A notes failure does not hide an otherwise complete episode.

Whisper large-v3 FP16 is the initial transcription default, not a proven winner on this library.
Real-episode accuracy comparisons remain necessary before any claim that it is the best local model.
The model revision is `49e6aa286ad60c14352c404340ded53710378a11` from `mlx-community/whisper-large-v3-mlx`.

## Current deployment

The installed Mac release is `20260905-123534`.
The running binary SHA-256 is `2c7d7906f90863d595ae73234e1e7bd474acb6bdf5b2fbed08be92a1e71682ae`.
That binary contains source v21, classifier version v3, and `omlx_busy`.
The launchd manager uses Homebrew Python 3.11.
The running backend executable resolves to this immutable release.

The pre-activation SQLite backup is `~/.local/share/pods/backups/20260905-123318/pods.sqlite`.
Its SHA-256 is `6138bbd3289f666531e352c6e1ab42e8c740e5a8f728d34bdffb7fcbc587ec27`.
Integrity is `ok`.

Activation preserved 32 subscribed podcasts and 19,764 episode-state rows.
Played count is 490.
Archived count is 19,273.
Positioned count is 203.
Position sum is 556038.024955.
Original publications 20718 and 20720 remain.

Migration removed all legacy `review` rows.
It converted 209 over-limit jobs to `blocked`.
It left zero over-limit retry or review rows.

Automatic processing continued after activation.
At the final snapshot, publications are 20715, 20716, 20718, and 20720.
Job stages are blocked 209, downloading 1, queued 3426, ready 4, and retry 4.
This state is live and can move.

The cooperative oMLX lock was busy for Pods classification and show notes.
It later became available.
The model is `DeepSeek-V4-Flash-0731-2.4bit-mixed`.
No paid provider configuration was introduced.

The public Cloudflare client contains `main-Cp0Opcme.js`, `main-CsV4hKcg.css`, and `store-z4IKHTCH.js`.
Public `sw.js` SHA-256 is `47ccb51e3916a024815cb4c9f13ec0c4a2ac20d04d21fddf3487a16dfc3c386b`.
That hash matches the local build.
Public main JS SHA-256 is `61c5b2650b2b49b638834d88aef814b2230e124472ad752eda77490823ef0e04`.
That hash matches the local build.

Public response headers contain one worker Content-Security-Policy.
Worker `connect-src` is `'self'` and `https:`. The page keeps a strict sync-only `connect-src`.
Page CSP and worker CSP remained correct.
Certificate and DNS remained healthy. They were not changed.

All 32 live subscribed feeds have clean titles and artwork URLs.
The catalog excludes the duplicate backlog. It does not delete rows or listening history.

Chrome mobile-width acceptance ran after waiting-worker activation.
It preserved 32 subscriptions.
Shows rendered 32 artwork images.
All loaded with nonzero dimensions and no failures.
Authenticated `/api/status` returned 200, revision 21, and the local model.
Offline emulation made the Mac API fail while `/_media/...` returned HTTP 206.

Downloaded playback had no loading indicator.
Playback advanced from 37:25 to 37:30.
Then the test paused playback and restored networking.
The playback test advanced episode 20715's local saved position to about 37:30.

Browser-harness hidden-tab HTMLAudio is an environment limitation.
All HTMLAudio controls stall when hidden.
AAC, WAV, and MP3 load when visible.
Pods playback works when visible.
No source change was made for that limitation.
`dev/check.sh` still passed 247 tests.

This evidence is Chrome mobile-width browser evidence.
It is not physical iPhone-device acceptance.

The earlier fallback publication of episode 20720 is historical live-install evidence.
It is not the v21 automatic fixture result.

The earlier v13 synthetic local test passed with DeepSeek-V4-Flash-0731-2.4bit-mixed.
The result was 1 passed. Runtime was 158.56 seconds. The run used no paid fallback.

The earlier v13 automatic real test for episode 20720 used a fresh disposable transcript and evidence set.
It completed all 41 coarse classification windows. It failed closed at the first opening-boundary disagreement.
The test published no automatic result. Runtime was 433.11 seconds.

The iOS native app is deprecated. The Vultr VPS was destroyed on 2026-09-07.

Classifier v21 fixtures pass the current automatic acceptance contract.
They do not prove universal classifier accuracy.
Broader automatic monitoring remains appropriate.

## Offline behavior

The default automatic download queue contains the oldest ten unplayed episodes, within a 2 GiB limit.
Manual downloads and pins use the same limit. Pins and the active playback file are protected from eviction.
Eviction removes played episodes first, then the most recent unplayed episodes.
Downloads pause while the app is hidden. Verified 1 MiB chunks remain available for the next attempt.
Only complete downloads can play. The service worker supports byte ranges. It does not load the whole episode into memory.

Playback positions, played state, subscriptions, and app settings enter a durable local queue before synchronization.
Retries reuse operation IDs. The backend rejects conflicting edits to the same field.
Settings offers **Keep phone** and **Use Mac** for conflicts. Backward seeks remain valid edits.
An expired login does not lock the cached library. A new login is necessary only for synchronization.

iOS can remove browser storage. A persistence request does not guarantee retention.
The phone is not a backup of the Mac library. Offline playback requires an earlier complete download.
The browser cannot obtain new episodes while the Mac is unavailable.

## Activate a client update

The service worker caches versioned app assets. It waits for old tabs to close before it activates.

1. Close every Pods tab and window.
2. Do not clear browser storage.
3. Open Pods again at `https://pods.mcgiv.dev`.
4. If the phone is on the Mac Wi-Fi, sign in.
5. Then synchronize.

Note: Browser storage holds the library and downloads. Site-data deletion removes that cache.

## Development and checks

Run all frontend tools inside the isolated container. Never run host `node`, `npm`, or `npx`.
The client runtime dependencies remain `react` and `react-dom` only.

```sh
dev/up.sh
dev/check.sh
cargo test --manifest-path backend/Cargo.toml --features passkey
python3 -m unittest discover -s mac/backend -p 'test_*.py'
```

The frontend build emits `sw.js` and `offline-assets.json`.
The service worker caches versioned app assets. See **Activate a client update**.
A local static server does not apply Cloudflare `_headers`.
A no-header local server test is not production-header acceptance.
API responses never enter the app cache. Credentials never enter the static bundle.

The explicit local-inference test uses synthetic audio and real model calls:

```sh
PODS_SMOKE_AUDIO=/absolute/path/to/synthetic.aiff \
PODS_PYTHON=/absolute/path/to/mac/backend/.venv/bin/python \
PODS_TRANSCRIBE_SCRIPT=/absolute/path/to/mac/backend/transcribe.py \
cargo test --manifest-path backend/Cargo.toml --features passkey \
  --test local_pipeline_smoke synthetic_audio_through_publication_and_notes -- --ignored --nocapture
```

The fixture must contain astronomy discussion and a short sponsor read, as documented in the test assertion.
The earlier v13 synthetic local test passed with DeepSeek-V4-Flash-0731-2.4bit-mixed.
The result was 1 passed. Runtime was 158.56 seconds. The run used no paid fallback.
Unit tests and synthetic audio checks do not prove universal classifier accuracy.
They are not physical iPhone-device acceptance.

## Library repair and processing status

The RSS parser reads channel metadata separately from episode metadata. It decodes CDATA and XML entities.
The first successful refresh after a parser upgrade ignores old HTTP validators. Missing metadata does not erase known artwork or descriptions.
The browser excludes untouched CDATA duplicates from its catalog and queue. The database retains these rows for recovery.
A duplicate with listening history, an explicit Listen entry, or a publication remains available for reconciliation.

Shows reports total episodes, unplayed episodes, and completed episodes separately. Listen reports pending jobs, retry failures, and blocked automatic failures from the last sync.
Only processed episodes appear in Listen. An empty Listen screen does not mean that subscriptions were deleted.
Audio downloads permit 15 redirects. Failed automatic jobs use exponential retry delays, from five minutes to six hours.
Automatic processing retries at most four failed attempts. Then the job stage is `blocked` and the episode remains unavailable.
`omlx_busy` does not consume an attempt. It retries in 30-60 seconds.
`memory_busy` does not consume an attempt. It retries in 60-120 seconds.
The memory gate defers Whisper below 8 GiB available (resume at 10 GiB) and oMLX work below 24 GiB (resume at 32 GiB).
Kernel pressure `warn` or `critical` defers both bands and stops an in-flight Whisper process group.
Notification Center posts `Transcription` or `Classification` paused or resumed copy on each transition.
Merge `memory_gate` and the four byte keys into the existing `mac.json`. Do not replace that file.
A plist-only `PODS_MEMORY_GATE` does not survive `manage.py agent`.
New jobs precede ordinary retries. An explicit `retry` command still takes precedence.

The public refresh client keeps the 120-second caller signal.
Snapshot status reads persisted history directly. It does not send a nested unauthenticated HTTP request.
It does not keep a stale live `is_refreshing` flag.

The `jobs` command reads the eligible pending view. Retry rejects nonexistent or ineligible jobs.
The command `python3 mac/backend/manage.py retry EPISODE_ID` requests a fresh automatic run.
It does not accept corrected labels.

The source classifier is pipeline v23.
It uses a bounded repair of at most two model calls per window. The second call uses 24 context segments.
Labels are binary: `ad` or `content`. Mixed or unclear audio is `content`, so the episode still publishes.
The repair keeps strict block validation. Invalid or disagreeing JSON fails closed after two attempts.
A last-attempt ad/content overlap publishes the disputed IDs as content.
Content-bound versions include repair and retry semantics, not only the initial prompt.

Source `CLASSIFIER_VERSION` is `pods-local-v5-whisper-large-v3-fp16-ad24-context12-blocks-repair-conflict-content-aac128`.
Source `VERSION` is `pods-local-v23-whisper-large-v3-fp16-repair-open24-gap8-discourse-trim-shift8-full-chapters-binary-aac128`.

The v21 real fixture is the episode 20720 transcript.
It produces 977 segment labels.
Expected ad ranges are `(2,38),(252,282),(443,457),(589,603),(773,788),(934,976)`.
An independent rerun found zero mismatches.
It published automatically and produced nonempty show notes.
Runtime was 152.59 seconds.

The v21 strengthened synthetic end-to-end fixture used 16.110 seconds of source audio.
Published duration was 11.150 seconds.
The cutter removed 4.960 seconds.
Labels were 2 ad and 3 content.
An independent rerun published automatically and produced nonempty notes.
Runtime was 11.25 seconds.

These fixtures pass the current acceptance contract.
They do not prove universal classifier accuracy.
Broader automatic monitoring remains appropriate.
There is no manual review or operator labeling.

The model identifies complete ad blocks: setup, dialogue, slogans, and disclaimers.
The backend requires complete, non-conflicting coverage.
The backend attaches exact source excerpts to the resulting labels.
Uncertain labels prevent publication. The job fails closed.
An independent small-window pass inspects each ad boundary.
A disagreement prevents publication. The job fails closed.

Agreement does not prove accuracy.
The real-podcast acceptance test compares every segment against gold ad ranges.
The earlier v13 automatic real test for episode 20720 completed all 41 coarse windows.
It failed closed at the first opening-boundary disagreement.
The test published no automatic result.

The cutter removes gaps inside consecutive ad segments.
An editorial segment always ends an ad block.

Additional opt-in tests cover live feeds, real tracking redirects, and the known pre-roll from episode 20720.
These tests require their named environment variables. They do not run in the normal regression suite.
The disposable browser fixture accepts a database only inside the system temporary directory. It binds to loopback and has no processing worker.
Its disabled authentication does not affect the production service.

## Private Mac configuration

The state directory is `~/.local/share/pods`. Immutable releases reside in `releases/`, with `current` pointing to the selected release.
The database resides in `data/pods.sqlite`. Audio and checkpoints reside in `data/AdRemovalData/`.

Create `~/.config/podcasts/mac.json` with mode `0600`:

```json
{
  "desec_token": "REPLACE_LOCALLY",
  "acme_email": "YOUR_EMAIL",
  "whisper_model": "/Users/matthewmcgivney/models/whisper-large-v3-mlx"
}
```

Optional: set `"omlx_autostart": true` on that same object if the Mac manager should request `omlx start --no-wait` when loopback port 8000 is down. The request waits 60 seconds of continuous downtime, requires pending classification or show-notes work, and then waits 15 minutes before another request. It does not restart a live server. Restart the agent after that change. Rollback: set `"omlx_autostart": false` or remove the key, then restart the agent.

Never put real tokens in Git, chat, the client, or shell arguments.
The service reads the oMLX key from `~/.pi/agent/models.json`. It does not invoke Pi.
An optional `omlx_key` in the private configuration overrides that source.
The model endpoint must use loopback. The default is `http://127.0.0.1:8000/v1/chat/completions`.

Podcast Index credentials remain in `~/.config/podcasts/credentials.env`.
The service reads only `PODCASTINDEX_KEY` and `PODCASTINDEX_SECRET` from that file. It does not execute the file.

## DNS, HTTPS, and static hosting

The parent domain can remain in Route53. Only `sync.pods.mcgiv.dev` needs delegation to deSEC.
The service publishes the current private Wi-Fi IPv4 address and explicitly clears IPv6.
It never publishes the public address of the API caller.
The [deSEC update API](https://desec.readthedocs.io/en/latest/dyndns/update-api.html) uses a 60-second record TTL.

1. Create the `sync.pods.mcgiv.dev` zone in the selected deSEC account.
2. Delegate that zone in Route53 to the nameservers supplied by deSEC.
3. Store a zone-scoped deSEC token in the private Mac configuration.
4. Verify the public NS delegation before certificate issuance.
5. Run `python3 mac/backend/manage.py certificate`.

Certbot uses DNS-01 validation. No inbound public port is necessary for certificate issuance.
The certificate hook waits for both deSEC nameservers and two public resolvers before validation.
If the TXT proof does not propagate, the hook stops after 15 minutes.
DNS API requests use IPv4 with a 30-second request limit. Authentication remains outside process arguments and logs.
Caddy binds only to the private Wi-Fi address and proxies to loopback.
The service checks certificate renewal every 12 hours and restarts Caddy after renewal.

Some networks block private-address DNS answers or communication between clients.
Local-network browser permission, DNS availability, and network isolation can prevent synchronization.
The app remains usable with its existing downloads in those cases.

1. Create a direct-upload project in the selected Cloudflare Pages account.
2. Build the client inside the dev container.
3. Upload only `client/dist/` through the Cloudflare dashboard.
4. Add `pods.mcgiv.dev` as a custom domain in Pages.
5. Preserve the existing Route53 records for rollback.
6. At cutover, replace only the `pods.mcgiv.dev` A/AAAA records with the supplied Pages CNAME.

Cloudflare supports an [externally managed subdomain](https://developers.cloudflare.com/pages/configuration/custom-domains/) through a CNAME.
The DNS change alone is insufficient. The Pages project must also have the custom domain association.
The upload contains no database, audio, transcript, model, or credentials.

Public `/sw.js` has its own Content-Security-Policy. Worker `connect-src` is `'self'` and `https:`.
The HTML page keeps `connect-src 'self' https://sync.pods.mcgiv.dev:8443`.
A local static server does not apply these headers.

This removes the need for a paid VPS and inference API in the target deployment.
Domain registration, the existing parent DNS service, electricity, and internet access are separate costs.
Free service limits are external constraints, not a guarantee of zero costs forever.

## Install and supervise the backend

Before installation, verify the local model checkpoint and Python lockfile.
The checkpoint directory must contain `config.json`, model weights, and `.pods-revision` with the exact revision above.

```sh
uv sync --project mac/backend --frozen
python3 mac/backend/manage.py install
python3 mac/backend/manage.py agent
```

The installer builds Rust and the frontend, copies an immutable release, and installs its locked Python environment.
The agent command prints the exact `launchctl bootstrap` command. It does not start the service automatically.
The service restarts failed child processes. It stops their processing descendants on shutdown.
Feed refresh runs at startup, after a missed interval during sleep, and every 30 minutes while awake.
One worker runs transcription, classification, and rendering. Completed work survives restarts through content-bound checkpoints.

The processing cap defaults to 100 GiB, with at least 10 GiB of free disk space required.
The worker stops new downloads at the cap. It does not automatically erase original audio or the library.
The environment variable `PODS_STORAGE_LIMIT_BYTES` changes the processing cap for a direct backend launch.

Note: The installed release is `20260905-123534`.

## Backup and migration

CAUTION: Do not uninstall the deprecated iOS app. Uninstalling the native app can erase its remaining local data.
The Vultr VPS was destroyed on 2026-09-07. Cloudflare Pages serves the client. The Mac host runs the backend.

Use SQLite backup, not a standalone copy of a live database file.
The backup command includes committed WAL data and runs an integrity check.

```sh
python3 mac/backend/manage.py backup /absolute/source/pods.sqlite /absolute/new/backup.sqlite
python3 mac/backend/manage.py inventory /absolute/new/backup.sqlite
python3 mac/backend/manage.py import /absolute/new/backup.sqlite
```

Import refuses to overwrite an existing destination database.
The initial VPS copy is a historical migration baseline. The live library is the Mac database.
Keep backup hashes, table counts, and audio hashes outside Git.
Existing passkey credentials remain in the database.

For an additional passkey, run `python3 mac/backend/manage.py enroll` locally.
The command prints a single-use enrollment URL that expires after 15 minutes.
It does not reset existing credentials or sessions. Do not share that URL in chat or logs.

## Automatic processing

Note: Installed `jobs`, `retry`, and the current classifier are in release `20260905-123534`.

There is no human review or correction workflow. There is no `prepare-review` command.

The command `python3 mac/backend/manage.py jobs` lists eligible pending work.
The command reads the `browser_pending_jobs` view. It does not list excluded duplicates as the live queue.

Invalid or disagreeing block JSON fails closed after repair. Mixed or unclear audio is `content`. A last-attempt ad/content overlap publishes the disputed IDs as content. The worker still publishes the episode.
Automatic processing retries at most four failed attempts. Then the job stage is `blocked`.
A blocked episode remains unavailable. It does not wait for operator labels.

`omlx_busy` does not consume an attempt. It retries in 30-60 seconds.
`memory_busy` does not consume an attempt. It retries in 60-120 seconds.

The command `python3 mac/backend/manage.py retry EPISODE_ID` requests a fresh automatic run.
It does not accept corrected labels.
Retry rejects a nonexistent job or an ineligible job.

Old `review.json` files, if present, are ignored. They need not be deleted.

If the operator opens an upgraded database, it converts legacy `review` rows.
Rows below four attempts become `retry`. Rows at or above four attempts become `blocked`.
Over-limit `retry` rows become `blocked`. The upgrade does not alter publications or listening state.

A window uses 24 core segments and 12 context segments. Bounded repair allows at most two model calls.
Every label requires an exact transcript quote. The output schema constrains IDs and labels before validation.
Transcript text is data, never instructions. Show notes use the same model and source-constrained chapter IDs.

## VPS retirement

The Mac release `20260905-123534` is installed and active.
The public Cloudflare client serves `main-Cp0Opcme.js`, `main-CsV4hKcg.css`, and `store-z4IKHTCH.js`.
Public service-worker and main JS hashes match the local build.
Page CSP and worker CSP remained correct.
Certificate and DNS remained healthy. They were not changed.

Chrome mobile-width browser acceptance passed after waiting-worker activation.
It preserved 32 subscriptions.
Shows rendered 32 artwork images with nonzero dimensions and no failures.
Authenticated `/api/status` returned 200, revision 21, and the local model.
Offline emulation made the Mac API fail while `/_media/...` returned HTTP 206.
Downloaded playback had no loading indicator and advanced 37:25 to 37:30.

The test then paused playback and restored networking.
Episode 20715's local saved position advanced to about 37:30.
This is Chrome mobile-width browser evidence. It is not physical iPhone-device acceptance.
Browser-harness hidden-tab HTMLAudio is an environment limitation.
No source change was made. `dev/check.sh` still passed 247 tests.

Classifier v21 fixtures pass the current automatic acceptance contract.
They do not prove universal classifier accuracy.
Broader automatic monitoring remains appropriate.
There is no manual review or operator labeling.

The native iOS app remains deprecated.
The Vultr VPS, firewall, and SSH key were destroyed on 2026-09-07.
The account had no snapshots, backups, reserved IPs, object storage, or other paid Vultr resources.
`https://pods.mcgiv.dev` stayed on Cloudflare Pages. Route53 records were not deleted.
