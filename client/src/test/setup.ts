import "@testing-library/jest-dom/vitest";
import { afterEach, beforeEach, vi } from "vitest";
import { cleanup } from "@testing-library/react";
import { FakeAudio } from "./fakeAudio";

beforeEach(() => {
  localStorage.clear();
  window.location.hash = "";
  FakeAudio.reset();
  vi.stubGlobal("Audio", FakeAudio);
  // Every test must declare its network expectations explicitly.
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL) => {
      throw new Error(`unmocked fetch: ${String(input)}`);
    }),
  );
});

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
  vi.useRealTimers();
});
