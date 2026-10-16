import { act, renderHook, waitFor } from "@testing-library/react";
import { expect, it, vi } from "vitest";
import { useList } from "./hooks";
import { emitEpisodesChanged } from "./events";
import type { Page } from "./types";

it("does not lose a download-complete refresh while an older list read is in flight", async () => {
  type Item = { id: number; downloaded: boolean };
  let finish: (page: Page<Item>) => void = () => {};
  const fetcher = vi.fn().mockImplementationOnce(() => new Promise<Page<Item>>(resolve => { finish = resolve; }))
    .mockResolvedValue({ items: [{ id: 1, downloaded: true }], next_offset: null });
  const { result } = renderHook(() => useList<Item>(fetcher));
  await act(async () => { emitEpisodesChanged(); });
  await act(async () => { finish({ items: [{ id: 1, downloaded: false }], next_offset: null }); });
  await waitFor(() => expect(result.current.items).toEqual([{ id: 1, downloaded: true }]));
  expect(fetcher).toHaveBeenCalledTimes(2);
});
