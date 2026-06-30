import { afterEach, describe, expect, it } from "vitest";
import { createAudioEngine, hasNativeAudioBridge } from "./audioEngine";

describe("native audio bridge", () => {
  afterEach(() => {
    delete window.webkit;
    delete window.PodsAudioBridge;
  });

  it("posts playback commands and accepts native state events", async () => {
    const messages: unknown[] = [];
    window.webkit = {
      messageHandlers: {
        podsAudio: {
          postMessage(message) {
            messages.push(message);
          },
        },
      },
    };

    expect(hasNativeAudioBridge()).toBe(true);
    const audio = createAudioEngine();
    const seen: string[] = [];
    audio.addEventListener("timeupdate", () => seen.push(`time:${audio.currentTime}`));
    audio.addEventListener("ended", () => seen.push("ended"));

    audio.src = "https://h.example/one.mp3";
    audio.playbackRate = 2;
    await audio.play();
    audio.currentTime = 42;
    audio.pause();

    expect(messages).toEqual([
      expect.objectContaining({ command: "load", src: "https://h.example/one.mp3" }),
      expect.objectContaining({ command: "rate", rate: 2 }),
      expect.objectContaining({ command: "play" }),
      expect.objectContaining({ command: "seek", seconds: 42 }),
      expect.objectContaining({ command: "pause" }),
    ]);

    window.PodsAudioBridge?.emit({ type: "timeupdate", position: 12, duration: 180, paused: false });
    expect(audio.currentTime).toBe(12);
    expect(audio.duration).toBe(180);
    expect(audio.paused).toBe(false);
    window.PodsAudioBridge?.emit({ type: "ended" });

    expect(seen).toEqual(["time:12", "ended"]);
    expect(audio.paused).toBe(true);
  });
});
