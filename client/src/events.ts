/** Fired after any mutation that changes episode/show lists (mark played,
 * subscribe, import…). List views listen and reload. */
export const EPISODES_CHANGED_EVENT = "pods-episodes-changed";

/** Coalesce rapid dual emits (e.g. auto-refresh + Settings on the same POST). */
let emitScheduled = false;

/**
 * Coalesce same-tick emits. Listeners are invoked on the next microtask,
 * not synchronously — callers must not assume post-emit state is updated
 * in the same turn.
 */
export function emitEpisodesChanged(): void {
  if (emitScheduled) return;
  emitScheduled = true;
  const schedule =
    typeof queueMicrotask === "function"
      ? queueMicrotask
      : (fn: () => void) => {
          void Promise.resolve().then(fn);
        };
  schedule(() => {
    emitScheduled = false;
    window.dispatchEvent(new Event(EPISODES_CHANGED_EVENT));
  });
}

export function onEpisodesChanged(cb: () => void): () => void {
  window.addEventListener(EPISODES_CHANGED_EVENT, cb);
  return () => window.removeEventListener(EPISODES_CHANGED_EVENT, cb);
}

/**
 * Test-only: clear coalesce flag between cases. No-op in production builds.
 * After reset, the next emit still dispatches via microtask — await Promise.resolve().
 */
export function resetEmitScheduledForTests(): void {
  if (import.meta.env.PROD) return;
  emitScheduled = false;
}
