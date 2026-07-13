# Pods iOS

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

The script builds with Xcode automatic signing and installs over the existing app. It never uninstalls the app.

## Automated Refresh

Free Personal Team installs expire after 7 days. Install the launchd job to refresh every 5 days:

```sh
IOS_DEVICE_ID=<device-id> IOS_TEAM_ID=<team-id> ios/install-refresh-agent.sh
```

Logs:

```sh
tail -f ~/Library/Logs/Pods/ios-refresh.log
```

Failures show a macOS notification titled `Pods Refresh Failed`.

## Reinstall Acceptance Test

Before retiring the remote server:

1. Install once with a staged seed DB.
2. Open the app and verify subscriptions, recent/played state, settings, and a playback position.
3. Run `IOS_DEVICE_ID=<device-id> ios/refresh-device.sh` again.
4. Reopen the app and verify the same state is still present.
5. Force a failure with a bad device id and verify the script exits nonzero, logs the failure, and sends a macOS notification.

Do not uninstall the app during this test. Uninstalling removes the app container and deletes the live database.

## Backend Status

The iOS app runs a native Swift backend inside the app process. It opens the reinstall-safe SQLite database in Application Support, listens on `127.0.0.1:18180`, and serves the same no-auth `/api` contract used by the React client. The bundled web app points at that loopback backend through `window.PODS_API_BASE`.

The old Rust backend has been removed. Backend behavior for the app belongs in `ios/Pods/PodsBackend.swift` and adjacent Swift files.

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
