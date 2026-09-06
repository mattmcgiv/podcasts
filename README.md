# Pods

A single-user podcast app for Chrome on iPhone. The browser stores the library and downloaded audio. The Mac runs the Rust backend.

**The native iOS app is deprecated.** Its source remains for history and data migration. New development targets the browser client.

The current architecture and operating instructions are in [Mac backend and offline browser](docs/mac-backend.md).

The Mac publishes only automatically processed episodes. There is no human review or correction workflow.
There is no `prepare-review` command.
Classification is binary: `ad` or `content`. Mixed or unclear audio is `content`.
Invalid or disagreeing block JSON still fails closed after repair.
Automatic processing retries at most four failed attempts. Then the job stage is `blocked`.
The episode remains unavailable.
`omlx_busy` does not consume an attempt. It retries in 30-60 seconds.
The command `python3 mac/backend/manage.py retry EPISODE_ID` requests a fresh automatic run.
It does not accept corrected labels.
Old `review.json` files, if present, are ignored. They need not be deleted.
If the operator opens an upgraded database, it converts legacy `review` rows below four attempts to `retry`.
It converts rows at or above four attempts to `blocked`. It converts over-limit `retry` rows to `blocked`.
The upgrade does not alter publications or listening state.
Source `CLASSIFIER_VERSION` is `pods-local-v4-whisper-large-v3-fp16-ad24-context12-blocks-repair-binary-aac128`.
Source `VERSION` is `pods-local-v22-whisper-large-v3-fp16-repair-open24-gap8-discourse-trim-shift8-full-chapters-binary-aac128`.

The v21 real fixture is the episode 20720 transcript.
It produces 977 segment labels.
Expected ad ranges are `(2,38),(252,282),(443,457),(589,603),(773,788),(934,976)`.
An independent rerun found zero mismatches.
It published automatically and produced nonempty show notes.
Runtime was 152.59 seconds.

The strengthened synthetic end-to-end fixture used 16.110 seconds of source audio.
Published duration was 11.150 seconds.
The cutter removed 4.960 seconds.
Labels were 2 ad and 3 content.
An independent rerun published automatically and produced nonempty notes.
Runtime was 11.25 seconds.

These fixtures pass the current acceptance contract.
They do not prove universal classifier accuracy.
Broader automatic monitoring remains appropriate.
There is no manual review or operator labeling.
VPS retirement remains deferred.

The sections after this notice describe the legacy native app, not the supported deployment.

No discovery feed. No recommendations. Your subscriptions, unplayed episodes first (oldest by default), with mark-played archive.

## What it does

- **Listen / Played / Shows / Settings** tabs, with horizontal swipe between primary tabs
- **Search in Shows** for Podcast Index directory results and your local episodes (search is not a separate tab)
- **Native feed refresh** on the iPhone (foreground catch-up plus opportunistic background refresh; manual refresh always works)
- **Playback** with scrubber, skip back/forward, speeds through 3×, autoplay next, and mini player
- **Ad removal** (optional): download audio, local speech transcription, DeepSeek V4 Pro classification of ad ranges, automatic skip during playback with undo
- **Generated show notes / chapters** from the episode transcript when ad-removal processing is ready
- **Play on Mac** via the optional **Pods Speaker** menu-bar app (LAN cast, not AirPlay; progress saves on the phone)
- **Library tools**: subscribe by search or RSS URL, OPML import/export, unsubscribe
- **Appearance**: system, light, or dark theme

People-following / guest appearances exist in the codebase but stay off by default (`FOLLOW_APPEARANCES_ENABLED` in `client/src/config.ts`).

## Layout

| Path | Role |
|------|------|
| `client/` | React UI (runtime deps: `react` + `react-dom` only) |
| `backend/` | Active library/API (`Backend::handle`). Implement backend changes here. |
| `ios/` | **Deprecated 1 October 2026.** Frozen iPhone shell and signing/install tooling. See `ios/DEPRECATED.md`. |
| `mac/` | Mac backend tooling (`mac/backend/`) plus optional **Pods Speaker** |
| `docs/` | Architecture and design notes (browser/Mac backend, ad removal) |
| `dev/` | Isolated Apple `container` workflow for frontend tooling |
| `shared/` | Small shared Swift helpers |

## Architecture

The active library/API is the Rust crate in `backend/` (`Backend::handle`).
New backend behavior belongs there, covered by `cargo test`.

The iPhone app diagram below is **archived**. That shell is deprecated as of
1 October 2026 and must not be extended. See `ios/DEPRECATED.md`.

```
iPhone (Pods.app) — deprecated 1 October 2026
├── WKWebView  →  bundled React client
└── Swift loopback shell  →  127.0.0.1:18180
    └── Rust backend via FFI (`backend/src/ffi.rs`)
```

The React client talks to a backend through `window.PODS_API_BASE`. Do not
add library/API behavior in `ios/Pods/`.

## Renaming the app

The display name lives in two places: `client/src/config.ts` (`APP_NAME`) and `client/public/manifest.webmanifest`. Change both.

## Development — read this first

All client toolchain work runs **inside an isolated VM** (Apple `container` CLI, macOS Containerization). The host never runs `npm`, `npx`, or `node`. See `AGENTS.md` for the rules and `dev/` for container setup.

```sh
dev/up.sh        # build image + start the long-lived dev container
dev/sh.sh        # shell into it
dev/check.sh     # frontend test + coverage gate (≥90% lines, statements, functions)
```

The Vite dev server publishes to http://127.0.0.1:5173. The user-facing
library/API backend is the Rust crate in `backend/`. The iPhone Swift shell
that can serve it on loopback is deprecated; do not extend it.

### Troubleshooting the container runtime

Homebrew's `container` bottle does not link `libexec`, so the apiserver can crash-loop with
"cannot find any plugins with type network". Fix (one-time, survives upgrades):

```sh
ln -sfn /opt/homebrew/opt/container/libexec/container-plugins /opt/homebrew/libexec/container-plugins
launchctl kickstart -k gui/$(id -u)/com.apple.container.apiserver
```

Headless starts should use `container system start --enable-kernel-install` (the default
prompts interactively). Kernel can be (re)installed with `container system kernel set --recommended`.

## Configuration

### Podcast Index (show search)

Podcast Index credentials live in the host-only file `~/.config/podcasts/credentials.env`. The Xcode build writes them into the signed app bundle as `PodcastIndexCredentials.plist`. No credential file is committed.

Required keys:

```sh
PODCASTINDEX_KEY=...
PODCASTINDEX_SECRET=...
```

Optional:

```sh
PODCASTINDEX_BASE_URL=https://api.podcastindex.org/api/1.0
```

Without keys, local episode search still works. Directory subscribe-by-search reports `directory_configured: false`. You can still paste an RSS URL in Settings.

## oMLX inference lock

Pods shares the Mac GPU with Pi and other local clients. Native oMLX `max_concurrent_requests=1` is per model engine. It still queues extra work. It is not a Mac-wide exclusive lock.

This project adds one cooperative advisory lock. It is not a daemon. No extra background process starts. Kernel close of the lock file descriptor releases ownership.

### Why two controls exist

| Control | What it does |
| --- | --- |
| oMLX `max_concurrent_requests=1` | Per engine: at most one admitted prefill/decode. Extra requests wait (up to 32), then HTTP 503. Two models can still run at once. Leave this setting unchanged. |
| Cooperative `flock(2)` | Mac-wide mutex for complete inference work among cooperative callers (Pods, Pi wrapper, scripts). |

### Paths

The lock file contains no secrets. Existence of the file is not ownership. `flock(2)` is ownership.

```text
~/.omlx/locks/mac-inference.lock      # advisory lock (same BSD flock(2) as /usr/bin/lockf)
~/.omlx/locks/mac-inference.json      # inspection only: pid, owner, purpose, model, started_at
```

Never put keys, prompts, transcripts, URLs, or payloads in the JSON file.

### When Pods holds the lock

- **Classification phase:** one permit covers every transcript window and the boundary pass. Pods does not release between windows. It releases before ffmpeg audio rendering.
- **Show notes:** a second acquire of the same lock. Pods holds it through the complete oMLX notes response/work, then releases.

Chat POST requires that permit token. Nested acquire of the same path returns busy. That prevents deadlock and accidental bypass inside Pods.

After `flock` succeeds, Pods makes an authenticated read-only `GET /api/status`. If `active_requests` or `waiting_requests` is nonzero, Pods releases and reports `omlx_busy`. An uncooperative caller can still race after this check and POST to `127.0.0.1:8000` without the file lock.

If the lock is held or oMLX is occupied, Pods does not start `/v1/chat/completions`. It does not consume a classifier failure attempt. Job error is `omlx_busy`. `next_retry_at` is 30–60 seconds with bounded deterministic jitter from the episode id.

### Pi and scripts

Use the standard-library wrapper. It acquires the same lock, writes metadata, then runs the command. It releases when the wrapped process exits. It does not read credentials and does not call oMLX.

Put the command after `--` so flags stay with that command:

```sh
python3 mac/backend/omlx_inference_lock.py --owner pi --purpose chat --model DeepSeek-V4-Flash-0731-2.4bit-mixed -- pi
python3 mac/backend/omlx_inference_lock.py --owner script --purpose chat --model unspecified -- /usr/bin/python3 ./my_omlx_client.py
```

A shell-only wrapper is not enough. macOS has `/usr/bin/lockf`, not util-linux `flock`. `lockf` can run a command under `flock(2)`, but it cannot keep metadata and exact argv together without a parent process. The Python wrapper is stdlib-only (`fcntl.flock` is `flock(2)` on macOS).

### Inspect ownership without stealing the lock

Do not delete the lock file. Deleting it does not unlock a live holder.

```sh
python3 mac/backend/omlx_inference_lock.py --check
/usr/bin/lockf -k -s -t 0 ~/.omlx/locks/mac-inference.lock /usr/bin/true
# busy → exit 75 (EX_TEMPFAIL)
lsof ~/.omlx/locks/mac-inference.lock
cat ~/.omlx/locks/mac-inference.json
```

`--check` and `lockf -t 0 … /usr/bin/true` try a non-blocking lock and drop it at once. They do not keep ownership. `--check` does not write metadata.

### Crash and stale state

The kernel releases `flock` when the last holding fd closes. That includes normal Drop, errors, cancellation, panic/unwind, and process death (`kill -9`). Sleep/wake keeps a live holder.

Stale `mac-inference.json` can remain after a crash. The lock file is the source of truth. The next holder overwrites or removes the JSON. Never delete `mac-inference.lock` to unlock.

### Cooperative bypass and a possible later proxy

Any process with the API key can POST to `127.0.0.1:8000` and skip this file lock. Native `max_concurrent_requests=1` still serializes admitted work on one model and can queue the bypass. A later loopback proxy that owns port 8000 can enforce this for every HTTP client. That needs an oMLX bind/restart. This change does not do that.

### Debug override and rollback

Locking is on by default and fail closed. If the lock or status check cannot prove it is safe to start inference, Pods does not POST.

```sh
PODS_OMLX_LOCK=0    # WARNING: disables only the cooperative lock. Unsafe for normal use.
```

Rollback: set `PODS_OMLX_LOCK=0`, stop using the wrapper, leave oMLX settings and the live service unchanged. Tests can set `PODS_OMLX_LOCK_DIR` to a temporary directory.

This code does not create a LaunchAgent, lock daemon, or other mysterious background process.

### Ad removal (optional)

Ad removal is off by default. In Settings:

1. Save a DeepSeek API key in Settings, then enable ad removal. Transcript text is sent to DeepSeek V4 Pro for classification and generated show notes; episode audio stays on the iPhone.
2. New subscribed episodes after the enrollment cutoff prepare in the background. Existing episodes can use **Prepare ad-free**.

Details, storage rules, and acceptance criteria: `docs/ad-removal-design.md` and `docs/ad-removal-v1-acceptance.md`.

## iOS app

**Deprecated as of 1 October 2026.** Do not review, extend, or append to
`ios/` or the iPhone FFI/build glue (`backend/src/ffi.rs`,
`backend/include/pods_backend.h`, `backend/build-ios.sh`). The code is
kept until removal. See `ios/DEPRECATED.md`.

The private iPhone target lives under `ios/`.

- Full Xcode is required; Command Line Tools are not enough.
- Free Personal Team installs expire after 7 days. The launchd agent checks on a timer, reinstalls before profile expiry, and retries when the phone is briefly unavailable.
- Reinstall-over-existing must preserve the live SQLite DB in Application Support. Uninstalling the app deletes that state.
- Generated web assets (`ios/Pods/Web/`) and seed DBs are ignored by Git. Stage UI with `ios/prepare-web-assets.sh`.

See `ios/README.md` for Xcode setup, seed DB staging, feed refresh behavior, refresh automation, and reinstall acceptance tests.

## Mac speaker (optional)

`mac/PodsSpeaker` plays episode audio on the Mac while you control playback from the iPhone. Phone and Mac must share the same Wi‑Fi. See `mac/README.md`.
