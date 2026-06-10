/** Fired after any mutation that changes episode/show lists (mark played,
 * subscribe, import…). List views listen and reload. */
export const EPISODES_CHANGED_EVENT = "pods-episodes-changed";

export function emitEpisodesChanged(): void {
  window.dispatchEvent(new Event(EPISODES_CHANGED_EVENT));
}

export function onEpisodesChanged(cb: () => void): () => void {
  window.addEventListener(EPISODES_CHANGED_EVENT, cb);
  return () => window.removeEventListener(EPISODES_CHANGED_EVENT, cb);
}
