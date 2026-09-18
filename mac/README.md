# Pods pipeline menu (Mac)

Menu-bar companion that shows local processing status.

This is **not** a desktop Pods client. It does not play audio. Mac playback is the Rust helper on `/api/speaker`. See [Play on Mac](../docs/mac-speaker.md).

## What it shows

The waveform extra lists processing, queued, and stuck jobs from `~/.local/share/pods/data/pods.sqlite`.

The **Pause** switch in the header stops local inference work: Whisper transcription, ad classification, and show-note generation. Downloads and sync keep running. A pause ends after four hours, or when the switch is turned off. The switch writes `~/.local/share/pods/pipeline-pause.json`, which the Rust backend reads.

## Setup

1. Open `mac/PodsSpeaker.xcodeproj` in Xcode.
2. Select your Team under Signing (Personal Team is fine).
3. Run **PodsSpeaker** (destination: My Mac).
4. Confirm a **waveform** icon appears in the menu bar.
