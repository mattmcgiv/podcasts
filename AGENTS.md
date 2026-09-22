# Pods — project rules

## Security model (non-negotiable)

This project treats npm supply-chain compromise as the primary threat. The development boundary is a hardware-isolated VM via Apple's `container` CLI.

1. **NEVER run `npm`, `npx`, or `node` on the host.** All client toolchain execution goes through the dev container: `container exec pods-dev <cmd>` (helpers in `dev/`).
2. **NEVER mount `.git` or the repo root into the container.** Only `client/` is mounted. A guest-writable `.git` enables host code execution via hooks/`core.fsmonitor`/smudge filters.
3. Git runs on the host only. The guest holds no GitHub/SSH credentials.
4. `node_modules/` lives in a guest-only volume — untrusted packages never land on host disk.
5. npm runs with `ignore-scripts=true` and `save-exact=true` (enforced by `client/.npmrc`). Lockfiles are committed.
6. Podcast Index credentials stay in the host-only credential store: `~/.config/podcasts/credentials.env`. The Mac backend reads them. Never include credentials in the browser build. The deprecated iPhone Xcode build still injects them into the signed app bundle at build time.

## Dev workflow

- After every turn, commit that turn's work on `main` and push it to `origin/main`.
- After a turn that changes the Mac backend (`backend/` or the `mac/backend/` runtime the installed service runs), install that backend in the same turn. Do not wait to be asked. From the repo root run `python3 mac/backend/manage.py install`, then `launchctl kickstart -k gui/$(id -u)/dev.mcgiv.pods-backend`. Install builds the release binary, rebuilds the client in `pods-dev`, and atomically retargets `~/.local/share/pods/current`. The running service resolves `current` once at start, so the kickstart is what loads the new binary. If `pods-dev` is down, install a backend-only release instead: copy the live `current` tree into `releases/<YYYYMMDD-HHMMSS>`, replace `pods-backend` (and `runtime/manage.py` when it changed), retarget `current` the way `install()` does (write `current.next` as a symlink, then `Path.replace` it onto `current`), then kickstart. Do not `mv` or `ln` onto `current` while the shell is following that symlink. A client-only or docs-only turn does not reinstall the backend. Client production deploy stays the Cloudflare Pages steps below.
- `dev/up.sh` — build the image and start the long-lived `pods-dev` container (mounts, ports, resources).
- `dev/sh.sh [cmd...]` — exec into the container (interactive shell if no args).
- `dev/check.sh` — the merge gate: frontend Vitest coverage (≥90% lines, statements, and functions, enforced in `vite.config.ts`).
- Vite dev server: `:5173`.
- Client production deploy: **Deploy the client** in `docs/mac-backend.md`. Build in `pods-dev`, zip `client/dist/` at the zip root, then upload that zip with local Chrome through browser-harness in the Cloudflare Pages dashboard. Do not use Wrangler, `npx`, GitHub Actions, or `infra/deploy.sh`. Do not create a new Pages project or change DNS.

## Default app/runtime

- The browser at `pods.mcgiv.dev` is the supported client. The native iOS app is deprecated; retain its source and data for migration only.
- The library/API backend is the Rust crate in `backend/` (`Backend::handle`), hosted on the Mac. The browser must work from downloaded data while the Mac is unavailable.
- The browser synchronizes over HTTPS through Tailscale while the Mac is awake and connected. Only processed episodes with finished show notes are published.
- For user-facing library/API behavior, implement backend changes in Rust (`backend/`) and cover them with `cargo test`.
- The iPhone client app (Swift), the in-app iPhone "backend" (loopback server + Rust FFI shell), and all iPhone signing/install tooling are **deprecated as of 1 October 2026**. Do not review, extend, or append to `ios/`, `backend/src/ffi.rs`, `backend/include/pods_backend.h`, or `backend/build-ios.sh`. See `ios/DEPRECATED.md`. The code is kept until removal.
- The still-present iPhone shell serves the Rust backend on `127.0.0.1:18180` via `ios/Pods/PodsLocalServer.swift` calling `RustBackend`.
- The bundled React app can point at that loopback backend through `window.PODS_API_BASE` in `ios/Pods/PodsWebView.swift`.
- There is no active Hetzner remote dev host for this project.
- There is no Vultr VPS. Cloudflare Pages serves the client. The Mac host runs the backend.

## Product rules

- Personal mobile client for iPhone and iPad, including portrait, landscape, and split-screen widths.
- Primary browser: **Chrome on iPhone** — Matt uses it most of the time. Pods is for his personal use, so optimize for Chrome's features. (Note: Chrome on iOS still uses the WebKit engine, so web-platform capabilities match Safari; the differences are in browser UI/features, not the rendering/JS engine.)
- **No discovery/recommendation features — ever.** This is an anti-requirement from Matt.
- Recent (default view) = unplayed episodes, oldest first. Mark-played removes; Played view is the archive.
- Client runtime deps stay at exactly `react` + `react-dom`. Routing is the hand-rolled hash router in `client/src/router.ts`. Justify any proposed new dependency in terms of the supply-chain posture.
- App display name: `APP_NAME` in `client/src/config.ts` + `client/public/manifest.webmanifest`.
