# Pods

A single-user, mobile-first podcast app. React/TypeScript/Vite client, Rust (axum + SQLite) server, shipped as one self-contained binary.

No discovery. No recommendations. Just your episodes, newest first.

## Layout

- `client/` — React app (runtime deps: react + react-dom, nothing else)
- `server/` — Rust API + feed engine; release builds embed the built client

## Renaming the app

The display name lives in two places: `client/src/config.ts` (`APP_NAME`) and `client/public/manifest.webmanifest`. Change both, done.

## Development — read this first

All toolchain execution happens **inside an isolated VM** (Apple `container` CLI, macOS 26 Containerization framework). The host never runs `npm` or `cargo` — see `CLAUDE.md` for the rules and `dev/` for the container setup.

```sh
dev/up.sh        # build image + start the long-lived dev container
dev/sh.sh        # shell into it
dev/check.sh     # full test + coverage gates (≥80% both stacks)
```

Dev servers (run inside the container) publish to the host:

- Client (Vite): http://127.0.0.1:5173
- Server (axum): http://127.0.0.1:8080

### Troubleshooting the container runtime

Homebrew's `container` bottle doesn't link `libexec`, so the apiserver crash-loops with
"cannot find any plugins with type network". Fix (one-time, survives upgrades):

```sh
ln -sfn /opt/homebrew/opt/container/libexec/container-plugins /opt/homebrew/libexec/container-plugins
launchctl kickstart -k gui/$(id -u)/com.apple.container.apiserver
```

Headless starts should use `container system start --enable-kernel-install` (the default
prompts interactively). Kernel can be (re)installed with `container system kernel set --recommended`.

## Configuration

Server env (see `server/.env.example`): `API_TOKEN` (login token), `PODCASTINDEX_KEY` / `PODCASTINDEX_SECRET` (directory search), `DATABASE_PATH`, `BIND_ADDR`.
