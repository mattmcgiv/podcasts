# Pods iOS

> **DEPRECATED as of 1 October 2026.** Do not review, extend, or append to
> this directory. The iPhone client, in-app backend shell, and
> signing/install tooling are frozen until removal. See
> [`DEPRECATED.md`](./DEPRECATED.md).

This directory contains the private iPhone app target and the refresh automation for a free Xcode Personal Team install.

## Play on Mac (Pods Speaker)

Optional menu-bar companion so episode audio plays on your MacBook while you fully use the computer (not AirPlay). Progress still saves on the phone.

See [`mac/README.md`](../mac/README.md) for setup. Summary: run `mac/PodsSpeaker.xcodeproj`, then in the iPhone player choose **Play on → Mac**.

## Xcode Setup

The Mac must have full Xcode, not only Command Line Tools.

1. Install Xcode from the App Store or Apple Developer downloads.
2. Select it:

   ```sh
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   ```

3. Open Xcode once, sign in with the Apple Account used for the Personal Team, and install required iOS platform components.
4. Connect the iPhone over USB once, trust the Mac, enable Developer Mode if prompted, and enable wireless/network installs in Xcode's Devices window.
5. Verify:

   ```sh
   ios/check-xcode.sh
   xcrun devicectl list devices
   ```

## Build Inputs

Generated app inputs are intentionally ignored by Git:

- `ios/Pods/Web/` - staged React build output.
- `ios/Pods/SeedData/pods-seed.sqlite` - optional first-run seed database.
- `ios/build/` - Xcode derived data and logs.

Stage the web UI with:

```sh
ios/prepare-web-assets.sh
```

That script uses the existing Apple `container` workflow and runs `npm` only inside `pods-dev`.

Stage a copied production database with:

```sh
ios/stage-seed-db.sh /path/to/pods.sqlite
```

The app copies `pods-seed.sqlite` into Application Support only if no live `pods.sqlite` exists. Reinstalling over the same bundle id must not overwrite the live database.

Podcast Index show search credentials live outside the repo at `~/.config/podcasts/credentials.env`:

```sh
PODCASTINDEX_KEY=...
PODCASTINDEX_SECRET=...
```

The Xcode build phase writes those values into the built app bundle as `PodcastIndexCredentials.plist`. If the file or either key is missing, `/api/search` still returns local episode matches but reports `directory_configured: false`.

## Manual Install

Set the iPhone device id from `xcrun devicectl list devices`, then run:

```sh
IOS_DEVICE_ID=<device-id> ios/refresh-device.sh
```

Optional:

```sh
IOS_TEAM_ID=<team-id> IOS_DEVICE_ID=<device-id> ios/refresh-device.sh
IOS_DEVICE_ID=<devicectl-id> IOS_XCODE_DESTINATION='platform=iOS,id=<xcode-device-id>' ios/refresh-device.sh
```

The script first verifies that CoreDevice reports the iPhone connected, then builds with Xcode automatic signing and installs over the existing app. It never uninstalls the app and will not create new signing material when the phone is already unreachable.

## Automated Refresh

Free Personal Team installs expire after 7 days. Install the launchd job to renew the actual provisioning profile before that deadline:

```sh
IOS_DEVICE_ID=<device-id> IOS_TEAM_ID=<team-id> ios/install-refresh-agent.sh
```

The agent runs at login and checks every 15 minutes. It performs a routine reinstall after 48 hours, but the embedded provisioning profile's verified expiration is the authoritative deadline. With 72 hours remaining, the agent archives only the matching expiring Pods profile from Xcode's active cache so automatic signing must request a fresh profile. A build is rejected before installation unless its profile belongs to `dev.mcgiv.pods` and has sufficient remaining lifetime.

Once a refresh is due, the agent actively opens a CoreDevice tunnel before invoking Xcode; an unavailable or briefly disconnected phone is retried at the next check. The installer must launch the newly installed app, observe a fresh UI-ready marker twice, and confirm that exact process remains alive before updating:

```text
~/Library/Application Support/PodsRefresh/last-success-epoch
~/Library/Application Support/PodsRefresh/profile-state
```

The profile state records the UUID, creation time, expiration time, and verified install time. Expiring profiles are retained recoverably under `~/Library/Application Support/PodsRefresh/profile-backups/`.

The Mac must be awake with the user logged in, and the iPhone must be reachable over USB or the same local network. A Personal Team app cannot be re-signed over the internet while the phone is away; the retry loop installs it automatically after the phone becomes reachable again.

Each verified install also upserts two iCloud Reminders, at 48 hours and 12 hours before the real profile expiration. If renewal is blocked, macOS notifications escalate once per profile and severity instead of repeating every 15 minutes.

For a bounded soak test, `ios/install-refresh-agent.sh` accepts `IOS_REFRESH_CHECK_INTERVAL_SECONDS` and `IOS_REFRESH_SUCCESS_INTERVAL_SECONDS`. Restore the defaults (`900` and `172800`) after testing.

Logs:

```sh
tail -f ~/Library/Logs/Pods/ios-refresh.log
tail -f ios/build/launchd.err.log
launchctl print gui/$(id -u)/dev.mcgiv.pods.refresh
```

Build or install failures show one deduplicated macOS notification titled `Pods Refresh Failed`. Expected unavailable-phone retries stay silent until the verified profile enters its warning window.

## Reinstall Acceptance Test

Before retiring the remote server:

1. Install once with a staged seed DB.
2. Open the app and verify subscriptions, recent/played state, settings, and a playback position.
3. Run `IOS_DEVICE_ID=<device-id> ios/refresh-device.sh` again.
4. Reopen the app and verify the same state is still present.
5. Force a failure with a bad device id and verify the script exits nonzero, logs the failure, and sends a macOS notification.

Do not uninstall the app during this test. Uninstalling removes the app container and deletes the live database.

## Backend Status

**Archived.** This directory is not the active backend. The Swift
`PodsBackend` implementation has been replaced; do not look for
`ios/Pods/PodsBackend.swift` and do not append library/API behavior here.

The still-present iPhone app hosts a loopback HTTP server
(`PodsLocalServer`) that calls the Rust crate in [`backend/`](../backend/)
through `RustBackend` and `backend/src/ffi.rs`. Implement backend changes in
`backend/` (`Backend::handle`) and cover them with `cargo test`.

See [`DEPRECATED.md`](./DEPRECATED.md).

## Feed refresh

The iPhone app owns automatic feed refresh natively; the React WebView does not run a refresh timer.

- On foreground activation, Pods refreshes only when the last successful complete pass is at least 12 hours old.
- It also submits an iOS `BGAppRefreshTask` for that cadence. iOS runs background tasks opportunistically, so foreground activation remains the reliable catch-up path.
- A failed automatic pass waits at least two hours before trying again. Manual **Refresh all feeds** always bypasses the window.
- RSS requests retain `ETag` and `Last-Modified` values. A `304 Not Modified` response is counted as a healthy feed check without reparsing or rewriting episodes.
- The backend persists the last attempt, success time, source, counts, and an audit row for every completed pass. Settings shows the most recent result, and the device log includes `Pods feed refresh source=... refreshed=... errors=...`.

## iOS Tests

Run the ported iOS backend contract tests with:

```sh
xcodebuild test -project ios/Pods.xcodeproj -scheme Pods -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -derivedDataPath ios/build/DerivedData CODE_SIGNING_ALLOWED=NO
```

The XCTest target covers no-auth startup, subscribe/backfill, Recent/Played state, episode position, settings, next episode, local search, OPML import/export, refresh, unsubscribe, and loopback HTTP serving.
