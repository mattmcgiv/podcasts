# Pods

A single-user, mobile-first podcast app. The iPhone app bundles the React UI and runs a native Swift backend in-process on `127.0.0.1:18180`.

No discovery. No recommendations. Just your episodes, newest first.

## Layout

- `client/` — React app (runtime deps: react + react-dom, nothing else)
- `ios/` — private iPhone target, Swift backend, local server, reinstall automation
- `mac/` — optional **Pods Speaker** menu-bar app (play phone-controlled audio on the Mac without AirPlay)

## Renaming the app

The display name lives in two places: `client/src/config.ts` (`APP_NAME`) and `client/public/manifest.webmanifest`. Change both, done.

## Development — read this first

All client toolchain execution happens **inside an isolated VM** (Apple `container` CLI, macOS 26 Containerization framework). The host never runs `npm`, `npx`, or `node` — see `AGENTS.md` for the rules and `dev/` for the container setup.

```sh
dev/up.sh        # build image + start the long-lived dev container
dev/sh.sh        # shell into it
dev/check.sh     # frontend test + coverage gate (≥80% lines)
```

The Vite dev server publishes to http://127.0.0.1:5173. The user-facing backend is the Swift backend inside the iOS app.

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

Podcast Index show search reads credentials from the host-only file `~/.config/podcasts/credentials.env` during the Xcode build. The build writes those values into the signed app bundle as `PodcastIndexCredentials.plist`; no credential file is committed to the repo.

Required keys:

```sh
PODCASTINDEX_KEY=...
PODCASTINDEX_SECRET=...
```

Optional:

```sh
PODCASTINDEX_BASE_URL=https://api.podcastindex.org/api/1.0
```

## iOS app

The private iPhone target lives under `ios/`.

- Full Xcode is required; Command Line Tools are not enough.
- Free Personal Team installs expire after 7 days. The launchd agent checks every 15 minutes, reinstalls after 48 hours since the last success, and retries when the phone is temporarily unavailable.
- Reinstall-over-existing must preserve the live SQLite DB in Application Support; uninstalling the app deletes that state.
- Generated web assets and seed DBs are ignored by Git.

See `ios/README.md` for setup, seed DB staging, refresh automation, and reinstall acceptance tests.
