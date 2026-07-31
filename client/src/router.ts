import { useSyncExternalStore } from "react";
import { FOLLOW_APPEARANCES_ENABLED } from "./config";

export type Tab = "recent" | "played" | "shows" | "settings" | "follows";

export interface Route {
  tab: Tab;
  showId?: number;
}

export function parseHash(hash: string): Route {
  const parts = hash.replace(/^#\/?/, "").split("/").filter(Boolean);
  switch (parts[0]) {
    case "played":
      return { tab: "played" };
    case "search":
      return { tab: "shows" };
    case "settings":
      return { tab: "settings" };
    case "follows":
      return FOLLOW_APPEARANCES_ENABLED ? { tab: "follows" } : { tab: "recent" };
    case "shows": {
      const id = Number(parts[1]);
      return Number.isInteger(id) && id > 0 ? { tab: "shows", showId: id } : { tab: "shows" };
    }
    default:
      return { tab: "recent" };
  }
}

export function navigate(to: string): void {
  window.location.hash = to;
}

function subscribe(cb: () => void): () => void {
  window.addEventListener("hashchange", cb);
  return () => window.removeEventListener("hashchange", cb);
}

export function useRoute(): Route {
  const hash = useSyncExternalStore(subscribe, () => window.location.hash);
  return parseHash(hash);
}
