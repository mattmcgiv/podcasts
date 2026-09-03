# Pods — project rules

## Security model (non-negotiable)

This project treats npm supply-chain compromise as the primary threat. The development boundary is a hardware-isolated VM via Apple's `container` CLI.

1. **NEVER run `npm`, `npx`, or `node` on the host.** All client toolchain execution goes through the dev container: `container exec pods-dev <cmd>` (helpers in `dev/`).
2. **NEVER mount `.git` or the repo root into the container.** Only `client/` is mounted. A guest-writable `.git` enables host code execution via hooks/`core.fsmonitor`/smudge filters.
3. Git runs on the host only. The guest holds no GitHub/SSH credentials.
4. `node_modules/` lives in a guest-only volume — untrusted packages never land on host disk.
5. npm runs with `ignore-scripts=true` and `save-exact=true` (enforced by `client/.npmrc`). Lockfiles are committed.
6. Podcast Index credentials stay in the host-only credential store: `~/.config/podcasts/credentials.env`. Xcode injects them into the signed iOS app bundle at build time.

## Dev workflow

- `dev/up.sh` — build the image and start the long-lived `pods-dev` container (mounts, ports, resources).
- `dev/sh.sh [cmd...]` — exec into the container (interactive shell if no args).
- `dev/check.sh` — the merge gate: frontend Vitest coverage (≥90% lines, statements, and functions, enforced in `vite.config.ts`).
- Vite dev server: `:5173`.

## Default app/runtime

- The iPhone app is the default app now.
- The active iPhone runtime uses the native Swift backend in `ios/Pods/PodsBackend.swift`, served by `ios/Pods/PodsLocalServer.swift` on `127.0.0.1:18180`.
- The bundled React app points at that backend through `window.PODS_API_BASE` in `ios/Pods/PodsWebView.swift`.
- For user-facing app behavior, implement backend changes in Swift.
- There is no active Hetzner remote dev host for this project.

## Product rules

- Mobile-only (iPhone). No tablet/desktop layouts.
- Primary browser: **Chrome on iPhone** — Matt uses it most of the time. Pods is for his personal use, so optimize for Chrome's features. (Note: Chrome on iOS still uses the WebKit engine, so web-platform capabilities match Safari; the differences are in browser UI/features, not the rendering/JS engine.)
- **No discovery/recommendation features — ever.** This is an anti-requirement from Matt.
- Recent (default view) = unplayed episodes, oldest first. Mark-played removes; Played view is the archive.
- Client runtime deps stay at exactly `react` + `react-dom`. Routing is the hand-rolled hash router in `client/src/router.ts`. Justify any proposed new dependency in terms of the supply-chain posture.
- App display name: `APP_NAME` in `client/src/config.ts` + `client/public/manifest.webmanifest`.
