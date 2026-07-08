# Pods Speaker (Mac)

Menu-bar companion that plays podcast audio on your Mac while you control it from the Pods iPhone app.

This is **not** a desktop Pods client (no browse/search). It is only a speaker + remote-control receiver.

## Why not AirPlay?

AirPlay makes the Mac a system audio receiver and often takes over focus. Pods Speaker plays the episode’s public media URL with a normal macOS `AVPlayer`, so the Mac stays fully usable.

## How it works

1. **Bonjour** (zero-config local discovery): the Mac advertises `_pods-speaker._tcp` on your Wi‑Fi.
2. The iPhone finds that service and opens a small **control channel** (JSON over TCP).
3. The Mac streams the same `audio_url` the phone would play (publisher CDN).
4. Playback position streams back to the phone every second and is saved in the phone’s SQLite DB.

Phone and Mac must be on the **same Wi‑Fi** (or equivalent LAN). No cloud relay.

## Setup

1. Open `mac/PodsSpeaker.xcodeproj` in Xcode.
2. Select your Team under Signing (Personal Team is fine).
3. Run **PodsSpeaker** (destination: My Mac).
4. Confirm a **hifi speaker** icon appears in the menu bar.
5. On the iPhone, open Pods → play an episode → **Play on Mac**.
6. Allow Local Network access on the phone if prompted.
7. On first connect, the Mac may ask **Allow Pods on iPhone?** — choose Allow.

## Pairing

After you Allow once, a pairing token is stored on both devices. Unknown devices on the Wi‑Fi cannot control the speaker without a new Allow prompt.

To reset pairing on the Mac:

```sh
defaults delete dev.mcgiv.pods.speaker pods.speaker.allowedTokens
```

(If the app is sandboxed under a different container path, clear tokens from the app’s UserDefaults or delete & reinstall.)

## Controls while casting

| Where | What |
|-------|------|
| iPhone player | Play, pause, seek, speed, autoplay next |
| Mac media keys / Control Center | Play / pause |
| Menu bar window | Status, play/pause, disconnect, quit |

Progress always lives on the **phone**. Quitting the Mac app mid-episode should lose at most a few seconds of position.

## Troubleshooting

- **Mac not listed on phone:** same Wi‑Fi? Pods Speaker running? Local Network allowed for Pods?
- **No sound:** Mac volume / output device; try pause/play from the phone.
- **Pairing denied:** open the menu bar window and connect again; click Allow on the alert.
