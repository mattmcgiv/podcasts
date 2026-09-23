import { beforeEach, afterEach, expect, it, vi } from "vitest";
import { bootstrapOffline } from "./bootstrap";
import * as client from "./client";
import * as downloads from "./downloads";
vi.mock("./client", () => ({ backendBase: () => "https://sync.pods.mcgiv.dev:8443", offlineEnabled: vi.fn(), synchronize: vi.fn() }));
vi.mock("./downloads", () => ({ prefetch: vi.fn(), sweepStaleDownloads: vi.fn() }));
vi.mock("../voice", () => ({ flushVoiceDrafts: vi.fn().mockResolvedValue(undefined) }));
beforeEach(() => {
  vi.useFakeTimers(); vi.mocked(client.offlineEnabled).mockReturnValue(true);
  vi.mocked(client.synchronize).mockResolvedValue(); vi.mocked(downloads.prefetch).mockResolvedValue();
  vi.mocked(downloads.sweepStaleDownloads).mockResolvedValue();
});
afterEach(() => { vi.useRealTimers(); vi.restoreAllMocks(); });
it("registers a module worker and synchronizes on reconnect/foreground", async () => {
  const register = vi.fn().mockResolvedValue({});
  Object.defineProperty(navigator, "serviceWorker", { configurable: true, value: { register, ready: Promise.resolve({}) } });
  const persist = vi.fn().mockResolvedValue(true);
  Object.defineProperty(navigator, "storage", { configurable: true, value: { persist } });
  await bootstrapOffline();
  expect(register).toHaveBeenCalledWith("/sw.js", { type: "module" });
  await vi.waitFor(() => expect(downloads.prefetch).toHaveBeenCalled());
  Object.defineProperty(document, "visibilityState", { configurable: true, value: "hidden" });
  const count = vi.mocked(client.synchronize).mock.calls.length;
  document.dispatchEvent(new Event("visibilitychange")); expect(client.synchronize).toHaveBeenCalledTimes(count);
  expect(downloads.sweepStaleDownloads).toHaveBeenCalled();
  Object.defineProperty(document, "visibilityState", { configurable: true, value: "visible" });
  window.dispatchEvent(new Event("online")); window.dispatchEvent(new Event("pods-authenticated"));
  window.dispatchEvent(new Event("pageshow")); window.dispatchEvent(new Event("focus"));
  await vi.advanceTimersByTimeAsync(60000);
  expect(client.synchronize).toHaveBeenCalledTimes(count + 5);
});
it("skips deprecated native mode and fails clearly without service worker support", async () => {
  vi.mocked(client.offlineEnabled).mockReturnValue(false); await bootstrapOffline();
  vi.mocked(client.offlineEnabled).mockReturnValue(true);
  Object.defineProperty(navigator, "serviceWorker", { configurable: true, value: undefined });
  await expect(bootstrapOffline()).rejects.toThrow("cannot store");
});

it("retries on a failed sync instead of waiting for the minute interval", async () => {
  const register = vi.fn().mockResolvedValue({});
  Object.defineProperty(navigator, "serviceWorker", { configurable: true, value: { register, ready: Promise.resolve({}) } });
  const persist = vi.fn().mockResolvedValue(true);
  Object.defineProperty(navigator, "storage", { configurable: true, value: { persist } });
  await bootstrapOffline();
  const initial = vi.mocked(client.synchronize).mock.calls.length;
  vi.mocked(client.synchronize).mockRejectedValue(new Error("Mac unavailable"));
  window.dispatchEvent(new Event("online"));
  const afterFail = vi.mocked(client.synchronize).mock.calls.length;
  expect(afterFail).toBeGreaterThan(initial);
  await vi.advanceTimersByTimeAsync(5000);
  expect(vi.mocked(client.synchronize).mock.calls.length).toBeGreaterThan(afterFail);
});

it("backs off while the Mac stays down instead of retrying every five seconds", async () => {
  const register = vi.fn().mockResolvedValue({});
  Object.defineProperty(navigator, "serviceWorker", { configurable: true, value: { register, ready: Promise.resolve({}) } });
  Object.defineProperty(navigator, "storage", { configurable: true, value: { persist: vi.fn().mockResolvedValue(true) } });
  await bootstrapOffline();
  vi.mocked(client.synchronize).mockRejectedValue(new Error("Mac unavailable"));
  window.dispatchEvent(new Event("online"));
  await vi.advanceTimersByTimeAsync(5000);
  const afterFirstRetry = vi.mocked(client.synchronize).mock.calls.length;
  await vi.advanceTimersByTimeAsync(5000);
  expect(vi.mocked(client.synchronize).mock.calls.length).toBe(afterFirstRetry);
  await vi.advanceTimersByTimeAsync(10000);
  expect(vi.mocked(client.synchronize).mock.calls.length).toBeGreaterThan(afterFirstRetry);
});
