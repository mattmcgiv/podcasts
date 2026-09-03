import { afterEach, describe, expect, it } from "vitest";
import { createAudioEngine, hasNativeAudioBridge, type AudioEngine, type CastInfo } from "./audioEngine";

function nativeCast(audio: AudioEngine): CastInfo {
  return (audio as AudioEngine & { cast: CastInfo }).cast;
}

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
    audio.setPlaybackRate?.(2.5, "speed-123");
    await audio.play();
    audio.currentTime = 42;
    audio.pause();

    expect(messages).toContainEqual(
      expect.objectContaining({ command: "load", src: "https://h.example/one.mp3" }),
    );
    expect(messages).toContainEqual(
      expect.objectContaining({
        command: "metadata",
        title: "Episode",
        artist: "Show",
        artwork: "http://127.0.0.1:18180/api/artwork/episodes/1",
        duration: 180,
      }),
    );
    expect(messages).toContainEqual(expect.objectContaining({ command: "rate", rate: 2 }));
    expect(messages).toContainEqual({ id: expect.any(Number), command: "rate", rate: 2.5, correlationId: "speed-123" });
    expect(messages).toContainEqual(expect.objectContaining({ command: "play" }));
    expect(messages).toContainEqual(expect.objectContaining({ command: "seek", seconds: 42 }));
    expect(messages).toContainEqual(expect.objectContaining({ command: "pause" }));

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

  it("does not dispatch events tagged for a previously loaded episode after loadSource switches", () => {
    window.webkit = {
      messageHandlers: {
        podsAudio: {
          postMessage() {},
        },
      },
    };

    const audio = createAudioEngine();
    const seen: string[] = [];
    audio.addEventListener("timeupdate", () => seen.push(`time:${audio.currentTime}`));
    audio.addEventListener("ended", () => seen.push("ended"));
    audio.addEventListener("play", () => seen.push("play"));

    audio.loadSource?.("https://h.example/one.mp3", 0, 1);
    audio.loadSource?.("https://h.example/two.mp3", 0, 2);

    // Stale transport / completion for episode 1 must not mutate or fire after switch to 2.
    window.PodsAudioBridge?.emit({ type: "timeupdate", position: 99, duration: 180, episodeId: 1 });
    window.PodsAudioBridge?.emit({ type: "ended", episodeId: 1 });
    window.PodsAudioBridge?.emit({ type: "play", paused: false, episodeId: 1 });
    expect(seen).toEqual([]);
    expect(audio.currentTime).toBe(0);
    expect(audio.paused).toBe(true);

    // Matching identity still applies.
    window.PodsAudioBridge?.emit({ type: "timeupdate", position: 3, duration: 200, episodeId: 2 });
    expect(seen).toEqual(["time:3"]);
    expect(audio.currentTime).toBe(3);
    expect(audio.duration).toBe(200);

    // Untagged browser-style events remain accepted.
    window.PodsAudioBridge?.emit({ type: "ended" });
    expect(seen).toEqual(["time:3", "ended"]);
    expect(audio.paused).toBe(true);
  });

  it("ignores non-positive duration events so early native zeros do not stick", () => {
    window.webkit = {
      messageHandlers: {
        podsAudio: {
          postMessage() {},
        },
      },
    };

    const audio = createAudioEngine();
    audio.loadSource?.("https://h.example/one.mp3", 0);
    expect(Number.isNaN(audio.duration)).toBe(true);

    window.PodsAudioBridge?.emit({ type: "loadedmetadata", duration: 0 });
    expect(Number.isNaN(audio.duration)).toBe(true);

    window.PodsAudioBridge?.emit({ type: "timeupdate", position: 5, duration: 1800 });
    expect(audio.duration).toBe(1800);
    expect(audio.currentTime).toBe(5);

    // A later zero must not wipe a known duration.
    window.PodsAudioBridge?.emit({ type: "timeupdate", position: 6, duration: 0 });
    expect(audio.duration).toBe(1800);
    expect(audio.currentTime).toBe(6);
  });

  it("posts cast connect/disconnect and surfaces cast status events", () => {
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
    const statuses: unknown[] = [];
    audio.addEventListener("cast", ((e: Event) => {
      statuses.push((e as CustomEvent).detail);
    }) as EventListener);

    audio.castConnect?.();
    audio.castDisconnect?.();

    expect(messages).toContainEqual(expect.objectContaining({ command: "castStatus" }));
    expect(messages).toContainEqual(expect.objectContaining({ command: "castConnect" }));
    expect(messages).toContainEqual(expect.objectContaining({ command: "castDisconnect" }));

    window.PodsAudioBridge?.emit({
      type: "cast",
      available: true,
      connected: true,
      name: "Pods Speaker (MacBook)",
      output: "mac",
    });
    expect(statuses).toContainEqual(
      expect.objectContaining({
        available: true,
        connected: true,
        name: "Pods Speaker (MacBook)",
        output: "mac",
      }),
    );
  });

  it("reloads, stops, undoes ad skips, and applies native rate and skip events", async () => {
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
    const skips: unknown[] = [];
    const undone: string[] = [];
    audio.addEventListener("adSkip", ((e: Event) => skips.push((e as CustomEvent).detail)) as EventListener);
    audio.addEventListener("adSkipUndone", () => undone.push("undone"));
    audio.addEventListener("state", () => undone.push("state"));

    audio.load();
    expect(messages.some((m) => (m as { command: string }).command === "load")).toBe(false);

    audio.src = "https://h.example/one.mp3";
    expect(audio.src).toBe("https://h.example/one.mp3");
    audio.load();
    expect(messages).toContainEqual(
      expect.objectContaining({ command: "load", src: "https://h.example/one.mp3" }),
    );

    audio.currentTime = Number.NaN;
    expect(audio.currentTime).toBe(0);
    audio.playbackRate = 0;
    expect(audio.playbackRate).toBe(1);
    audio.setPlaybackRate?.(Number.NaN, "bad-rate");
    expect(audio.playbackRate).toBe(1);

    audio.requestCastStatus?.();
    audio.undoAdSkip?.();
    expect(messages).toContainEqual(expect.objectContaining({ command: "castStatus" }));
    expect(messages).toContainEqual(expect.objectContaining({ command: "undoAdSkip" }));
    expect(nativeCast(audio)).toEqual({ available: false, connected: false, output: "local" });

    window.PodsAudioBridge?.emit({ type: "timeupdate", playbackRate: 1.5, position: 8 });
    expect(audio.playbackRate).toBe(1.5);
    window.PodsAudioBridge?.emit({ type: "adSkip", rangeStart: 1, rangeEnd: 12, skippedDuration: 11 });
    expect(skips).toEqual([]);
    window.PodsAudioBridge?.emit({
      type: "adSkip",
      rangeId: "ad-1",
      rangeStart: 1,
      rangeEnd: 12,
      skippedDuration: 11,
    });
    expect(skips).toEqual([
      { rangeId: "ad-1", rangeStart: 1, rangeEnd: 12, skippedDuration: 11 },
    ]);
    window.PodsAudioBridge?.emit({ type: "adSkipUndone" });
    expect(undone).toEqual(["undone"]);
    window.PodsAudioBridge?.emit({ type: "state", paused: true });
    expect(undone).toEqual(["undone"]);

    const otherId = (messages[0] as { id: number }).id + 99;
    window.PodsAudioBridge?.emit({ id: otherId, type: "timeupdate", position: 99 });
    expect(audio.currentTime).toBe(8);

    audio.removeAttribute("preload");
    expect(audio.src).toBe("https://h.example/one.mp3");
    audio.removeAttribute("src");
    expect(audio.src).toBe("");
    expect(audio.paused).toBe(true);
    expect(Number.isNaN(audio.duration)).toBe(true);
    expect(messages).toContainEqual(expect.objectContaining({ command: "stop" }));
  });

  it("uses a nested cast payload when native sends one", () => {
    window.webkit = {
      messageHandlers: {
        podsAudio: {
          postMessage() {},
        },
      },
    };
    const audio = createAudioEngine();
    window.PodsAudioBridge?.emit({
      type: "cast",
      cast: { available: true, connected: false, name: "Kitchen", output: "mac", error: "busy" },
    });
    expect(nativeCast(audio)).toEqual({
      available: true,
      connected: false,
      name: "Kitchen",
      error: "busy",
      output: "mac",
    });
  });
});
