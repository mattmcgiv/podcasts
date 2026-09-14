# Play on Mac

The phone browser controls playback. The Mac Rust backend plays processed episode audio through authenticated `/api/speaker` routes.

The menu-bar app is a pipeline monitor. It lists local processing jobs. It does not play audio.

## Architecture

Cloudflare Pages serves the client. The Mac backend already listens on the same HTTPS URL that offline sync uses. Same Wi-Fi is reachability. Passkey session, origin, and CORS remain authorization.

The backend exposes authenticated `/api/speaker/*` routes. Load identifies a published episode by episode ID and artifact hash. The Mac never accepts a caller URL, blob URL, or filesystem path from the browser.

A small AVFoundation helper is compiled into the Rust binary at build time. The helper plays a local published file. It does not open a window or take focus. Other platforms report that the Mac speaker is not available.

One controller is active at a time. Every load and command carries a session id and a generation. A stale or replayed load is rejected. The helper tags acknowledgments with command ids so a later load does not inherit an earlier duration.

## Phone UI

Open the player. Use **Play on** to choose iPhone or Mac.

If Mac is unreachable, tap **Retry Mac** after you join the Mac Wi-Fi. The app also retries when the phone comes online or the tab becomes visible. It does not poll every second while idle.

Progress still saves on the phone through the existing sync queue.

## Handoff and disconnect

A switch to Mac pauses phone audio first. Then the Mac loads the current episode, position, rate, and play state. If Mac is already selected and connected, a second tap does nothing.

A switch to iPhone waits for the Mac to confirm stop and keeps the last actual Mac position. Then local audio resumes from that position. If the Mac does not confirm stop, the phone stays paused on the current episode and shows an error. The Mac may still be playing. Tap Play on the phone if you want phone audio anyway. The phone does not start local audio by itself after an unconfirmed stop.

Ordinary Play after you lose the Mac controller does not reconnect. Tap Mac again to take control.

## Background

If Chrome on the phone is in the background, the Mac keeps playing. Position updates pause until the phone is visible again. Close the player or switch to iPhone to stop Mac audio.

## Checks

```sh
cargo test --manifest-path backend/Cargo.toml --features passkey
# Frontend: copy this worktree client into the guest, then npm ci --ignore-scripts, npm run check, npm run build
python3 -m unittest discover -s mac/backend -p 'test_*.py'
```
