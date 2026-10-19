import { describe, expect, it, vi } from "vitest";
import { createAudioEngine, createVideoEngine } from "./audioEngine";
import { BrowserSpeakerEngine } from "./speakerEngine";

describe("audio engines", () => {
  it("creates a browser speaker engine by default", () => {
    const audio = createAudioEngine();
    expect(audio instanceof BrowserSpeakerEngine).toBe(true);
  });

  it("mirrors every media property and listener onto the backing video element", async () => {
    const video = {
      src: "", currentTime: 0, duration: 90, playbackRate: 1, paused: true, preload: "none",
      play: vi.fn().mockResolvedValue(undefined), pause: vi.fn(), load: vi.fn(),
      removeAttribute: vi.fn(), addEventListener: vi.fn(), removeEventListener: vi.fn(),
      dispatchEvent: vi.fn().mockReturnValue(true),
    };
    const engine = createVideoEngine(video as unknown as HTMLVideoElement);
    engine.src = "https://h.example/vid.mp4"; expect(video.src).toBe("https://h.example/vid.mp4");
    expect(engine.src).toBe("https://h.example/vid.mp4");
    engine.currentTime = 12; expect(video.currentTime).toBe(12); expect(engine.currentTime).toBe(12);
    expect(engine.duration).toBe(90);
    engine.playbackRate = 2; expect(video.playbackRate).toBe(2); expect(engine.playbackRate).toBe(2);
    expect(engine.paused).toBe(true);
    engine.preload = "auto"; expect(video.preload).toBe("auto"); expect(engine.preload).toBe("auto");
    await engine.play(); expect(video.play).toHaveBeenCalled();
    engine.pause(); expect(video.pause).toHaveBeenCalled();
    engine.load(); expect(video.load).toHaveBeenCalled();
    engine.removeAttribute("src"); expect(video.removeAttribute).toHaveBeenCalledWith("src");
    const listener = () => {};
    engine.addEventListener("timeupdate", listener); expect(video.addEventListener).toHaveBeenCalledWith("timeupdate", listener, undefined);
    engine.removeEventListener("timeupdate", listener); expect(video.removeEventListener).toHaveBeenCalledWith("timeupdate", listener, undefined);
    const event = new Event("ended"); expect(engine.dispatchEvent(event)).toBe(true);
    expect(video.dispatchEvent).toHaveBeenCalledWith(event);
  });
});