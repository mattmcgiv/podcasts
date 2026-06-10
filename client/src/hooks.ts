import { useCallback, useEffect, useRef, useState } from "react";
import { onEpisodesChanged } from "./events";
import type { Page } from "./types";

interface ListState<T> {
  /** null until the first load resolves */
  items: T[] | null;
  error: string | null;
  loading: boolean;
  hasMore: boolean;
  loadMore: () => void;
  reload: () => void;
  removeById: (id: number) => void;
}

/** Offset-paginated list with reload-on-mutation. */
export function useList<T extends { id: number }>(
  fetcher: (offset: number) => Promise<Page<T>>,
): ListState<T> {
  const [items, setItems] = useState<T[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const nextOffset = useRef<number | null>(0);
  const busy = useRef(false);

  const load = useCallback(
    async (reset: boolean) => {
      if (busy.current) return;
      const offset = reset ? 0 : nextOffset.current;
      if (offset == null) return;
      busy.current = true;
      setLoading(true);
      setError(null);
      try {
        const page = await fetcher(offset);
        nextOffset.current = page.next_offset;
        setItems((prev) => (reset || prev == null ? page.items : [...prev, ...page.items]));
      } catch (e) {
        setError(e instanceof Error ? e.message : String(e));
      } finally {
        busy.current = false;
        setLoading(false);
      }
    },
    [fetcher],
  );

  useEffect(() => {
    void load(true);
    return onEpisodesChanged(() => void load(true));
  }, [load]);

  return {
    items,
    error,
    loading,
    hasMore: nextOffset.current != null,
    loadMore: () => void load(false),
    reload: () => void load(true),
    removeById: (id) => setItems((prev) => prev?.filter((i) => i.id !== id) ?? prev),
  };
}
