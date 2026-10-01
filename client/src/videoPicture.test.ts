import { afterEach, describe, expect, it, vi } from "vitest";
import { BLACK_FRAME_WAIT_MS, recoverBlackVideo } from "./videoPicture";

function videoElement(): HTMLVideoElement {
  const video = document.createElement("video");
  document.body.appendChild(video);
  Object.defineProperty(video, "paused", { configurable: true, value: false });
  Object.defineProperty(video, "ended", { configurable: true, value: false });
  vi.spyOn(video, "getBoundingClientRect").mockReturnValue({
    width: 320,
    height: 180,
    top: 0,
    left: 0,
    bottom: 180,
    right: 320,
    x: 0,
    y: 0,
    toJSON: () => ({}),
  });
  return video;
}

describe("recoverBlackVideo", () => {
  afterEach(() => {
    document.body.replaceChildren();
    vi.useRealTimers();
  });

  it("leaves the width alone when a frame is presented", () => {
    vi.useFakeTimers();
    const video = videoElement();
    let present: (() => void) | undefined;
    video.requestVideoFrameCallback = (callback) => {
      present = () => callback(0, {} as VideoFrameCallbackMetadata);
      return 7;
    };
    video.cancelVideoFrameCallback = () => {};
    recoverBlackVideo(video);
    present?.();
    vi.advanceTimersByTime(BLACK_FRAME_WAIT_MS);
    expect(video.style.width).toBe("");
  });

  it("shrinks the width by one pixel when no frame arrives, then restores it", () => {
    vi.useFakeTimers();
    const video = videoElement();
    video.style.width = "100%";
    video.requestVideoFrameCallback = () => 1;
    video.cancelVideoFrameCallback = () => {};
    recoverBlackVideo(video);
    vi.advanceTimersByTime(BLACK_FRAME_WAIT_MS);
    expect(video.style.width).toBe("319px");
    vi.runAllTimers();
    expect(video.style.width).toBe("100%");
  });

  it("does not nudge a paused, ended, or zero-width video", () => {
    vi.useFakeTimers();
    const paused = videoElement();
    Object.defineProperty(paused, "paused", { configurable: true, value: true });
    recoverBlackVideo(paused);
    const ended = videoElement();
    Object.defineProperty(ended, "ended", { configurable: true, value: true });
    recoverBlackVideo(ended);
    const narrow = videoElement();
    vi.spyOn(narrow, "getBoundingClientRect").mockReturnValue({
      width: 0, height: 0, top: 0, left: 0, bottom: 0, right: 0, x: 0, y: 0, toJSON: () => ({}),
    });
    recoverBlackVideo(narrow);
    vi.advanceTimersByTime(BLACK_FRAME_WAIT_MS);
    expect(paused.style.width).toBe("");
    expect(ended.style.width).toBe("");
    expect(narrow.style.width).toBe("");
  });

  it("nudges when the frame callback is missing", () => {
    vi.useFakeTimers();
    const video = videoElement();
    delete (video as { requestVideoFrameCallback?: unknown }).requestVideoFrameCallback;
    recoverBlackVideo(video);
    vi.advanceTimersByTime(BLACK_FRAME_WAIT_MS);
    expect(video.style.width).toBe("319px");
  });

  it("cancels the wait and the frame callback", () => {
    vi.useFakeTimers();
    const video = videoElement();
    const cancel = vi.fn();
    video.requestVideoFrameCallback = () => 4;
    video.cancelVideoFrameCallback = cancel;
    const stop = recoverBlackVideo(video);
    stop();
    vi.advanceTimersByTime(BLACK_FRAME_WAIT_MS);
    expect(cancel).toHaveBeenCalledWith(4);
    expect(video.style.width).toBe("");
  });

  it("does not restore a newer reveal", () => {
    vi.useFakeTimers();
    const video = videoElement();
    video.requestVideoFrameCallback = () => 1;
    recoverBlackVideo(video);
    vi.advanceTimersByTime(BLACK_FRAME_WAIT_MS);
    expect(video.style.width).toBe("319px");
    recoverBlackVideo(video);
    vi.runAllTimers();
    expect(video.style.width).toBe("319px");
  });
});
