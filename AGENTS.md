# Pods — project rules

## Security model (non-negotiable)

This project treats npm supply-chain compromise as the primary threat. The development boundary is a hardware-isolated VM via Apple's `container` CLI.

1. **NEVER run `npm`, `npx`, or `node` on the host.** All client toolchain execution goes through the dev container: `container exec pods-dev <cmd>` (helpers in `dev/`).
2. **NEVER mount `.git` or the repo root into the container.** Only `client/` is mounted. A guest-writable `.git` enables host code execution via hooks/`core.fsmonitor`/smudge filters.
3. Git runs on the host only. The guest holds no GitHub/SSH credentials.
4. `node_modules/` lives in a guest-only volume — untrusted packages never land on host disk.
5. npm runs with `ignore-scripts=true` and `save-exact=true` (enforced by `client/.npmrc`). Lockfiles are committed.
6. Podcast Index credentials stay in the host-only credential store: `~/.config/podcasts/credentials.env`. The Mac backend reads them. Never include credentials in the browser build.

## Dev workflow

- After every turn, commit that turn's work on `main` and push it to `origin/main`.
- After a turn that changes the Mac backend (`backend/` or the `mac/backend/` runtime the installed service runs), install that backend in the same turn. Do not wait to be asked. From the repo root run `python3 mac/backend/manage.py install`, then `launchctl kickstart -k gui/$(id -u)/dev.mcgiv.pods-backend`. Install builds the release binary, rebuilds the client in `pods-dev`, and atomically retargets `~/.local/share/pods/current`. The running service resolves `current` once at start, so the kickstart is what loads the new binary. If `pods-dev` is down, install a backend-only release instead: copy the live `current` tree into `releases/<YYYYMMDD-HHMMSS>`, replace `pods-backend` (and `runtime/manage.py` when it changed), retarget `current` the way `install()` does (write `current.next` as a symlink, then `Path.replace` it onto `current`), then kickstart. Do not `mv` or `ln` onto `current` while the shell is following that symlink. A client-only or docs-only turn does not reinstall the backend. Client production deploy stays the Cloudflare Pages steps below.
- `dev/up.sh` — build the image and start the long-lived `pods-dev` container (mounts, ports, resources).
- `dev/sh.sh [cmd...]` — exec into the container (interactive shell if no args).
- `dev/check.sh` — the merge gate: frontend Vitest coverage (≥90% lines, statements, and functions, enforced in `vite.config.ts`).
- Vite dev server: `:5173`.
- Client production deploy: **Deploy the client** in `docs/mac-backend.md`. Build in `pods-dev`, zip `client/dist/` at the zip root, then upload that zip with local Chrome through browser-harness in the Cloudflare Pages dashboard. Do not use Wrangler, `npx`, GitHub Actions, or `infra/deploy.sh`. Do not create a new Pages project or change DNS.

## Menu bar app

The Mac menu-bar app is Pods Pipeline Preview (`Pods Speaker`, `dev.mcgiv.pods.speaker`). `~/Applications/Pods Pipeline Preview.app` is a symlink to `/Applications/Pods Pipeline Preview.app`.

- The next build has to replace the app in `/Applications`. Copying a new bundle onto the `~/Applications` path would replace the link, and `mbm` would hide the icon again. MenuBarAgent does not attribute a status item whose real path is outside `/Applications`, and `mbm` hides every unattributed icon while it is running.
- After replacing the bundle, relaunch it from `/Applications`. Login agent `dev.mcgiv.pods-speaker` runs `open -W "/Applications/Pods Pipeline Preview.app"`.

## Default app/runtime

- The browser at `pods.mcgiv.dev` is the supported client. The first native iOS app was removed on 19 October 2026; its source is in git history.
- A native iPhone app lives in `ios/` (rebuilt from 13 November 2026). It is 100% native SwiftUI and AVFoundation: no `WKWebView`, no web content, no third-party packages, no on-device backend, no FFI. It speaks the same sync protocol as the browser (`GET /api/sync`, `POST /api/sync/actions`, ranged `GET /api/artifacts/<hash>` with per-chunk SHA-256 checks) and keeps the library, an outbox, and downloaded media in `Application Support/Pods`. Do not restore the old `ios/` tree, `backend/src/ffi.rs`, or the old refresh scripts. As of 13 November 2026 the new Swift sources had not yet been compiled or run on a device; treat them as unverified until a later note says otherwise.
- Behavior rules that the browser client follows (sync conflict handling, position mapping through the manifest timeline, download limits, no discovery) apply to the native app too. When one changes, change both clients. `ios/Pods/SyncLogic.swift` mirrors the browser's sync rules.
- Native sign-in is a pairing code, because a free Personal Team cannot use passkeys (no Associated Domains). `python3 mac/backend/manage.py pair` prints a single-use code valid for ten minutes (only its hash is stored, in `auth_pair_tokens`); `POST /api/auth/pair` exchanges it for the normal `pods_session` cookie. Anyone who can run commands as Matt on this Mac can mint a session this way; that is the same trust boundary as `manage.py enroll`. The app sends `Origin: https://pods.mcgiv.dev` itself.
- The app is signed with a free Personal Team (seven-day signatures). Only Xcode on this Mac signs and installs it: no third-party sideloading tools, no paid developer account. `ios/tools/pods-ios.py` does it (`install`, `refresh`, `status`, `schedule`); team ID and device ID live in `~/.config/podcasts/ios.env`, never in the repo. The refresh reuses compiled output, treats "installed" as success, and never launches the app. It still needs this Mac awake and the iPhone reachable at least once inside the last three days of each signature.
- Not in the native app yet: Mac speaker output, voice feedback, OPML import, video picture, notifications and pipeline views. Use the browser for those.
- The library/API backend is the Rust crate in `backend/` (`Backend::handle`), hosted on the Mac. The browser must work from downloaded data while the Mac is unavailable.
- The browser synchronizes over HTTPS through Tailscale while the Mac is awake and connected. Only processed episodes with finished show notes are published.
- For user-facing library/API behavior, implement backend changes in Rust (`backend/`) and cover them with `cargo test`.
- The iPhone client app (Swift), the in-app iPhone "backend" (loopback server + Rust FFI shell), and all iPhone signing/install tooling were removed on 19 October 2026 after the 1 October deprecation. The old tree lived in `ios/` (deleted) plus `backend/src/ffi.rs`, `backend/include/pods_backend.h`, and `backend/build-ios.sh` (all deleted). Historical records of that work remain in dated docs such as `ios/DEPRECATED.md` via git history.
- There is no active Hetzner remote dev host for this project.
- There is no Vultr VPS. Cloudflare Pages serves the client. The Mac host runs the backend.

## Product rules

- Personal mobile client for iPhone and iPad, including portrait, landscape, and split-screen widths.
- Primary browser: **Chrome on iPhone** — Matt uses it most of the time. Pods is for his personal use, so optimize for Chrome's features. (Note: Chrome on iOS still uses the WebKit engine, so web-platform capabilities match Safari; the differences are in browser UI/features, not the rendering/JS engine.)
- **No discovery/recommendation features — ever.** This is an anti-requirement from Matt.
- Recent (default view) = unplayed episodes, oldest first. Mark-played removes; Played view is the archive.
- Client runtime deps stay at exactly `react` + `react-dom`. Routing is the hand-rolled hash router in `client/src/router.ts`. Justify any proposed new dependency in terms of the supply-chain posture.
- App display name: `APP_NAME` in `client/src/config.ts` + `client/public/manifest.webmanifest`.
