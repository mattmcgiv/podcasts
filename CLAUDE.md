# Pods — project rules

## Security model (non-negotiable)

This project treats npm/cargo supply-chain compromise as the primary threat. The development boundary is a hardware-isolated VM via Apple's `container` CLI.

1. **NEVER run `npm`, `npx`, `node`, `cargo`, or `rustc` on the host.** All toolchain execution goes through the dev container: `container exec pods-dev <cmd>` (helpers in `dev/`).
2. **NEVER mount `.git` or the repo root into the container.** Only `client/` and `server/` are mounted. A guest-writable `.git` enables host code execution via hooks/`core.fsmonitor`/smudge filters.
3. Git runs on the host only. The guest holds no GitHub/SSH credentials.
4. `node_modules/` and `target/` live in guest-only volumes — untrusted packages never land on host disk.
5. npm runs with `ignore-scripts=true` and `save-exact=true` (enforced by `client/.npmrc`). Lockfiles are committed.
6. The only secret allowed inside the guest is the Podcast Index API key (low-stakes, revocable). Host-only credential store: `~/.config/podcasts/credentials.env`.

## Dev workflow

- `dev/up.sh` — build the image and start the long-lived `pods-dev` container (mounts, ports, resources).
- `dev/sh.sh [cmd...]` — exec into the container (interactive shell if no args).
- `dev/check.sh` — the merge gate: frontend Vitest coverage (≥80% lines, enforced in `vite.config.ts`) + backend `cargo llvm-cov --fail-under-lines 80`.
- Vite dev server: `:5173` (proxies `/api` → `:8080` in-container). axum: `:8080`.

## Product rules

- Mobile-only (iPhone Safari). No tablet/desktop layouts.
- **No discovery/recommendation features — ever.** This is an anti-requirement from Matt.
- Recent (default view) = unplayed episodes, newest first. Mark-played removes; Played view is the archive.
- Client runtime deps stay at exactly `react` + `react-dom`. Routing is the hand-rolled hash router in `client/src/router.ts`. Justify any proposed new dependency in terms of the supply-chain posture.
- App display name: `APP_NAME` in `client/src/config.ts` + `client/public/manifest.webmanifest`.
