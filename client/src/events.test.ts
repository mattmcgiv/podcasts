import { describe, expect, it, vi } from "vitest";
import { emitEpisodesChanged, onEpisodesChanged } from "./events";

describe("emitEpisodesChanged", () => {
  it("coalesces multiple synchronous calls into one event", async () => {
    const handler = vi.fn();
    const off = onEpisodesChanged(handler);

    emitEpisodesChanged();
    emitEpisodesChanged();
    emitEpisodesChanged();
    expect(handler).not.toHaveBeenCalled();

    await Promise.resolve();
    expect(handler).toHaveBeenCalledTimes(1);

    off();
  });

  it("allows another emit after the microtask flushes", async () => {
    const handler = vi.fn();
    const off = onEpisodesChanged(handler);

    emitEpisodesChanged();
    await Promise.resolve();
    emitEpisodesChanged();
    await Promise.resolve();

    expect(handler).toHaveBeenCalledTimes(2);
    off();
  });
});
