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
    audio.setMetadata?.({
      title: "Episode",
      artist: "Show",
      artwork: "http://127.0.0.1:18180/api/artwork/episodes/1",
      duration: 180,
    });
    audio.playbackRate = 2;
    await audio.play();
    audio.currentTime = 42;
    audio.pause();

    expect(messages).toEqual([
      expect.objectContaining({ command: "load", src: "https://h.example/one.mp3" }),
      expect.objectContaining({
        command: "metadata",
        title: "Episode",
        artist: "Show",
        artwork: "http://127.0.0.1:18180/api/artwork/episodes/1",
        duration: 180,
      }),
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

  it("does not reuse the previous source position when loading a new source", () => {
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

    const audio = createAudioEngine();
    audio.src = "https://h.example/one.mp3";
    window.PodsAudioBridge?.emit({ type: "timeupdate", position: 4200, duration: 4800 });
    audio.src = "https://h.example/two.mp3";

    expect(messages).toContainEqual(
      expect.objectContaining({
        command: "load",
        src: "https://h.example/two.mp3",
        position: 0,
      }),
    );

    audio.loadSource?.("https://h.example/three.mp3", 30);
    expect(messages).toContainEqual(
      expect.objectContaining({
        command: "load",
        src: "https://h.example/three.mp3",
        position: 30,
      }),
    );
  });
});
