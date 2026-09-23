# Local inference on the Mac

Show notes, chapters, and Listen titles use local oMLX (`Qwen3.8-27B-4bit`, reasoning effort `low`). Ad classification uses TypeSafe Jev unless `mac.json` sets `"classifier": "omlx"`. Transcription is local Whisper and does not take the oMLX lock.

Pods shares the Mac GPU with other local clients. Native oMLX `max_concurrent_requests=1` is per model engine. It still queues extra work. It is not a Mac-wide exclusive lock.

This project adds one cooperative advisory lock. It is not a daemon. No extra background process starts. Kernel close of the lock file descriptor releases ownership.

## Why two controls exist

| Control | What it does |
| --- | --- |
| oMLX `max_concurrent_requests=1` | Per engine: at most one admitted prefill/decode. Extra requests wait (up to 32), then HTTP 503. Two models can still run at once. Leave this setting unchanged. |
| Cooperative `flock(2)` | Mac-wide mutex for complete inference work among cooperative callers (Pods, Pi wrapper, scripts). |

## Paths

The lock file contains no secrets. Existence of the file is not ownership. `flock(2)` is ownership.

```text
~/.omlx/locks/mac-inference.lock      # advisory lock (same BSD flock(2) as /usr/bin/lockf)
~/.omlx/locks/mac-inference.json      # inspection only: pid, owner, purpose, model, started_at
```

Never put keys, prompts, transcripts, URLs, or payloads in the JSON file.

## When Pods holds the lock

- **Show notes and Listen titles:** one acquire covers the complete oMLX response, then Pods releases.
- **oMLX classification** (`"classifier": "omlx"`): one permit covers every transcript window and the boundary pass. Pods does not release between windows. It releases before ffmpeg audio rendering. Jev classification does not acquire this lock.

Each chat acquire starts the managed oMLX server if loopback port 8000 is down, then loads `Qwen3.8-27B-4bit` if it is not already loaded. Drop unloads that model. If the server is idle with no models left, or Pods started it for this acquire, Drop also runs `omlx stop --timeout 60`. Whisper still only unloads Pods' model and leaves the server running. A disabled advisory lock is not enough authority to start, load, or stop shared state. Start and stop use the same managed CLI as autostart (`/Applications/oMLX.app/Contents/MacOS/omlx-cli` or `~/.omlx/bin/omlx`). Homebrew `omlx` on `PATH` does not win. Argv never includes the API key.

Chat POST requires that permit token. Nested acquire of the same path returns busy. That prevents deadlock and accidental bypass inside Pods.

After `flock` succeeds, Pods makes an authenticated read-only `GET /api/status`. If `active_requests` or `waiting_requests` is nonzero, Pods releases and reports `omlx_busy`. An uncooperative caller can still race after this check and POST to `127.0.0.1:8000` without the file lock.

If the lock is held or oMLX is occupied, Pods does not start `/v1/chat/completions`. It does not consume a classifier failure attempt. Job error is `omlx_busy`. `next_retry_at` is 30–60 seconds with bounded deterministic jitter from the episode id.

## Pi and scripts

Use the standard-library wrapper. It acquires the same lock, writes metadata, then runs the command. It releases when the wrapped process exits. It does not read credentials and does not call oMLX.

Put the command after `--` so flags stay with that command:

```sh
python3 mac/backend/omlx_inference_lock.py --owner pi --purpose chat --model Qwen3.8-27B-4bit -- pi
python3 mac/backend/omlx_inference_lock.py --owner script --purpose chat --model unspecified -- /usr/bin/python3 ./my_omlx_client.py
```

A shell-only wrapper is not enough. macOS has `/usr/bin/lockf`, not util-linux `flock`. `lockf` can run a command under `flock(2)`, but it cannot keep metadata and exact argv together without a parent process. The Python wrapper is stdlib-only (`fcntl.flock` is `flock(2)` on macOS).

## Inspect ownership without stealing the lock

Do not delete the lock file. Deleting it does not unlock a live holder.

```sh
python3 mac/backend/omlx_inference_lock.py --check
/usr/bin/lockf -k -s -t 0 ~/.omlx/locks/mac-inference.lock /usr/bin/true
# busy → exit 75 (EX_TEMPFAIL)
lsof ~/.omlx/locks/mac-inference.lock
cat ~/.omlx/locks/mac-inference.json
```

`--check` and `lockf -t 0 … /usr/bin/true` try a non-blocking lock and drop it at once. They do not keep ownership. `--check` does not write metadata.

## Crash and stale state

The kernel releases `flock` when the last holding fd closes. That includes normal Drop, errors, cancellation, panic/unwind, and process death (`kill -9`). Sleep/wake keeps a live holder.

Stale `mac-inference.json` can remain after a crash. The lock file is the source of truth. The next holder overwrites or removes the JSON. Never delete `mac-inference.lock` to unlock.

## Cooperative bypass

Any process with the API key can POST to `127.0.0.1:8000` and skip this file lock. Native `max_concurrent_requests=1` still serializes admitted work on one model and can queue the bypass.

## Debug override

Locking is on by default and fail closed. If the lock or status check cannot prove it is safe to start inference, Pods does not POST.

```sh
PODS_OMLX_LOCK=0    # WARNING: disables only the cooperative lock. Unsafe for normal use.
```

Rollback: set `PODS_OMLX_LOCK=0`, stop using the wrapper, leave oMLX settings and the live service unchanged. Tests can set `PODS_OMLX_LOCK_DIR` to a temporary directory.

This code does not create a LaunchAgent, lock daemon, or other background process for the lock itself.

## oMLX autostart

The worker starts oMLX itself when show notes (or oMLX classification) need a server and port 8000 is down. The Mac manager can also request the existing oMLX menu-bar app to start that server, as a backup, when the port is down.

Manager autostart is off by default. Merge `"omlx_autostart": true` into `~/.config/podcasts/mac.json` and restart the agent. Do not put the flag only on the launchd plist. `python3 mac/backend/manage.py agent` rewrites the plist and drops extra env keys.

A TCP check of `127.0.0.1:8000` is the liveness probe. Occupied oMLX, a held cooperative lock, and HTTP 503 are live. Those cases do not trigger a start. `open -a oMLX` is not enough when the app is already up with the server stopped. The manager calls the menu-bar CLI (`/Applications/oMLX.app/Contents/MacOS/omlx-cli` or `~/.omlx/bin/omlx`) with `start --no-wait`. Homebrew `omlx` on `PATH` does not win. It does not call `omlx serve` or `omlx restart`. A fast non-zero CLI exit is a failed start. The first stderr line is logged. Stdout is discarded. Stderr is not a pipe. A CLI that is still running after a short poll is left running.

Start runs only when eligible pending work is in `classifying`, `ad_boundaries`, or `show_notes`, or the job error is `omlx_busy`. Queued, downloading, and transcribing jobs do not start oMLX. Played, archived, unsubscribed, and blocked jobs do not start it.

The manager waits 60 seconds of continuous downtime, then 15 minutes between start requests. The CLI spawn is asynchronous so DNS and Caddy keep their 5-second loop. If the menu-bar CLI is missing, the manager logs once and looks again later. Notification Center posts `oMLX start requested` or `oMLX start failed`. Logs and argv never include the API key.

Rollback: set `"omlx_autostart": false` or remove the key, then restart the agent.

## Memory-aware inference deferral

The Mac backend stays up for HTTPS, sync, and speaker when unified memory is tight. It defers only Whisper transcription and oMLX classification or show notes.

Default bands, absolute bytes:

| Work | Defer | Resume |
| --- | --- | --- |
| Transcription | below 8 GiB available, or memory pressure `warn`/`critical` | 10 GiB and pressure `normal` |
| Classification and show notes | below 24 GiB available, or memory pressure `warn`/`critical` | 32 GiB and pressure `normal` |

Job error is `memory_busy`. It does not consume a failure attempt. Retry is 60–120 seconds. Downloads, ffmpeg, RSS, and HTTP stay ungated.

If kernel pressure hits `warn` or `critical` while Whisper is already running, the backend stops that process group. Completed 180 s chunk files remain. Classification that already holds the oMLX lock is not cancelled.

`GET /api/status` includes a `memory` object with both gates. macOS Notification Center posts one `{work} paused due to {cause}` banner when a kind becomes deferred, and one `{work} resumed due to available memory` banner when it returns to open. The same pause or resume does not repeat while that kind stays in that state, including after a backend restart. Causes are low memory, warning-level memory pressure, critical memory pressure, and a memory sample failure. Live banners require `PODS_MEMORY_GATE_NOTIFY=1` from `python3 mac/backend/manage.py`; do not put that key only on the launchd plist.

Merge these keys into the existing `~/.config/podcasts/mac.json` (mode 0600). Keep the other keys in that file. Do not replace the file with a memory-only object.

```json
"memory_gate": true,
"memory_whisper_defer_below_bytes": 8589934592,
"memory_whisper_resume_above_bytes": 10737418240,
"memory_omlx_defer_below_bytes": 25769803776,
"memory_omlx_resume_above_bytes": 34359738368
```

Rollback: set `"memory_gate": false` on that same object, then restart the agent. Do not put `PODS_MEMORY_GATE` only on the launchd plist. `python3 mac/backend/manage.py agent` rewrites the plist and drops extra env keys.

If oMLX loads weights on the first POST instead of at process start, raise `memory_omlx_defer_below_bytes` to 96 GiB (`103079215104`).
