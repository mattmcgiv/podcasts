import { afterEach, describe, expect, it, vi } from "vitest";
import { postPodsLifecycleEvent } from "./podsLifecycle";

type LifecycleTestWindow = Window & {
  __PODS_UI_READY?: boolean;
};

const lifecycleWindow = window as LifecycleTestWindow;

afterEach(() => {
  delete window.webkit;
  delete lifecycleWindow.__PODS_UI_READY;
});

describe("postPodsLifecycleEvent", () => {
  it("marks the UI ready before notifying the native container", () => {
    const readinessAtPost: Array<boolean | undefined> = [];
    const postMessage = vi.fn(() => {
      readinessAtPost.push(lifecycleWindow.__PODS_UI_READY);
    });
    Object.defineProperty(window, "webkit", {
      configurable: true,
      value: { messageHandlers: { podsLifecycle: { postMessage } } },
    });

    postPodsLifecycleEvent("ui-ready");

    expect(lifecycleWindow.__PODS_UI_READY).toBe(true);
    expect(readinessAtPost).toEqual([true]);
    expect(postMessage).toHaveBeenCalledWith({ event: "ui-ready" });
  });

  it("marks the UI failed before notifying the native container", () => {
    lifecycleWindow.__PODS_UI_READY = true;
    const readinessAtPost: Array<boolean | undefined> = [];
    const postMessage = vi.fn(() => {
      readinessAtPost.push(lifecycleWindow.__PODS_UI_READY);
    });
    Object.defineProperty(window, "webkit", {
      configurable: true,
      value: { messageHandlers: { podsLifecycle: { postMessage } } },
    });

    postPodsLifecycleEvent("ui-failed");

    expect(lifecycleWindow.__PODS_UI_READY).toBe(false);
    expect(readinessAtPost).toEqual([false]);
    expect(postMessage).toHaveBeenCalledWith({ event: "ui-failed" });
  });
});
