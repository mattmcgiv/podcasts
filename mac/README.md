# Pods pipeline menu (Mac)

Menu-bar companion that shows local processing status.

This is **not** a desktop Pods client. It does not play audio. Mac playback is the Rust helper on `/api/speaker`. See [Play on Mac](../docs/mac-speaker.md).

## What it shows

The waveform extra lists processing, queued, and stuck jobs from `~/.local/share/pods/data/pods.sqlite`.

## Setup

1. Open `mac/PodsSpeaker.xcodeproj` in Xcode.
2. Select your Team under Signing (Personal Team is fine).
3. Run **PodsSpeaker** (destination: My Mac).
4. Confirm a **waveform** icon appears in the menu bar.
