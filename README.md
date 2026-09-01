# Pods

A single-user, mobile-first podcast app for iPhone. The app bundles a React UI and runs a native Swift backend in-process on `127.0.0.1:18180`.

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
| `ios/` | Private iPhone target, Swift backend, local server, reinstall automation |
| `mac/` | Optional **Pods Speaker** menu-bar companion |
| `docs/` | Design notes (for example ad removal) |
| `dev/` | Isolated Apple `container` workflow for frontend tooling |
| `shared/` | Small shared Swift helpers |

## Architecture

```
iPhone (Pods.app)
├── WKWebView  →  bundled React client
└── Swift backend  →  loopback HTTP on 127.0.0.1:18180
    ├── SQLite library (Application Support)
    ├── RSS refresh + Podcast Index search
    ├── Audio / ad-removal pipeline
    └── Cast control channel → Mac Pods Speaker (optional)
```

The React client talks to the Swift backend through `window.PODS_API_BASE`. Backend behavior for the app lives in `ios/Pods/`, not in a remote server.

## Renaming the app

The display name lives in two places: `client/src/config.ts` (`APP_NAME`) and `client/public/manifest.webmanifest`. Change both.

## Development — read this first

All client toolchain work runs **inside an isolated VM** (Apple `container` CLI, macOS Containerization). The host never runs `npm`, `npx`, or `node`. See `AGENTS.md` for the rules and `dev/` for container setup.

```sh
dev/up.sh        # build image + start the long-lived dev container
dev/sh.sh        # shell into it
dev/check.sh     # frontend test + coverage gate (≥80% lines)
```

The Vite dev server publishes to http://127.0.0.1:5173. The user-facing backend is the Swift backend inside the iOS app.

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

### Ad removal (optional)

Ad removal is off by default. In Settings:

1. Save a DeepSeek API key in Settings, then enable ad removal. Transcript text is sent to DeepSeek V4 Pro for classification and generated show notes; episode audio stays on the iPhone.
2. New subscribed episodes after the enrollment cutoff prepare in the background. Existing episodes can use **Prepare ad-free**.

Details, storage rules, and acceptance criteria: `docs/ad-removal-design.md` and `docs/ad-removal-v1-acceptance.md`.

## iOS app

The private iPhone target lives under `ios/`.

- Full Xcode is required; Command Line Tools are not enough.
- Free Personal Team installs expire after 7 days. The launchd agent checks on a timer, reinstalls before profile expiry, and retries when the phone is briefly unavailable.
- Reinstall-over-existing must preserve the live SQLite DB in Application Support. Uninstalling the app deletes that state.
- Generated web assets (`ios/Pods/Web/`) and seed DBs are ignored by Git. Stage UI with `ios/prepare-web-assets.sh`.

See `ios/README.md` for Xcode setup, seed DB staging, feed refresh behavior, refresh automation, and reinstall acceptance tests.

## Mac speaker (optional)

`mac/PodsSpeaker` plays episode audio on the Mac while you control playback from the iPhone. Phone and Mac must share the same Wi‑Fi. See `mac/README.md`.
