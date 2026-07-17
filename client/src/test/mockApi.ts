import { vi } from "vitest";
import type { AdRemovalSettings, AdRemovalStatusItem, EpisodeItem } from "../types";

type RouteValue =
  | unknown
  | ((url: URL, init: RequestInit) => unknown | Promise<unknown>);

export interface MockRoutes {
  /** key: "GET /api/recent" (path only, query ignored for matching) */
  [key: string]: RouteValue;
}

export class HttpError {
  constructor(
    public status: number,
    public body: unknown = {},
  ) {}
}

/** Installs a fetch mock; returns a spy plus a per-route call log. */
export function installApi(routes: MockRoutes) {
  const calls: { key: string; url: URL; init: RequestInit }[] = [];
  const impl = async (input: RequestInfo | URL, init: RequestInit = {}) => {
    const url = new URL(String(input), "http://localhost");
    const method = (init.method ?? "GET").toUpperCase();
    const key = `${method} ${url.pathname}`;
    calls.push({ key, url, init });
    const handler = routes[key];
    if (handler === undefined) {
      throw new Error(`unmocked route: ${key}`);
    }
    const value = typeof handler === "function" ? await handler(url, init) : handler;
    if (value instanceof HttpError) {
      return new Response(JSON.stringify(value.body), {
        status: value.status,
        headers: { "content-type": "application/json" },
      });
    }
    if (value === null || value === undefined) {
      return new Response(null, { status: 204 });
    }
    if (typeof value === "string") {
      return new Response(value, { status: 200, headers: { "content-type": "text/plain" } });
    }
    if (value instanceof Blob) {
      return new Response(await value.arrayBuffer(), {
        status: 200,
        headers: { "content-type": value.type },
      });
    }
    return new Response(JSON.stringify(value), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  };
  const spy = vi.fn(impl);
  vi.stubGlobal("fetch", spy);
  return { spy, calls };
}

export function episode(overrides: Partial<EpisodeItem> = {}): EpisodeItem {
  return {
    id: 1,
    podcast_id: 10,
    podcast_title: "Test Show",
    podcast_image: "",
    title: "Test Episode",
    audio_url: "https://h.example/ep.mp3",
    duration_secs: 1800,
    published_at: 1_750_000_000,
    image_url: "",
    position_secs: 0,
    played_at: null,
    ad_removal_state: "unfiltered",
    ad_removal_action: "prepare",
    ad_removal_stage: null,
    ad_removal_blocking_reason: null,
    ad_removal_completed_windows: null,
    ad_removal_total_windows: null,
    ...overrides,
  };
}

export function adRemovalSettings(
  overrides: Partial<AdRemovalSettings> = {},
): AdRemovalSettings {
  return {
    enabled: false,
    enrollment_cutoff: null,
    cloud_classifier_configured: false,
    model_repository: "",
    model_revision: "",
    model_total_bytes: 3_060_000_000,
    model_downloaded_bytes: 0,
    model_download_state: "not_downloaded",
    episode_storage_bytes: 0,
    episode_storage_limit_bytes: 10_000_000_000,
    device_available_bytes: 20_000_000_000,
    minimum_free_bytes: 10_000_000_000,
    corrections: [],
    ...overrides,
  };
}

export function page<T>(items: T[], next_offset: number | null = null) {
  return { items, next_offset };
}

export function adRemovalStatusItem(
  overrides: Partial<AdRemovalStatusItem> = {},
): AdRemovalStatusItem {
  return {
    id: 1,
    ad_removal_state: "unfiltered",
    ad_removal_action: "prepare",
    ad_removal_stage: null,
    ad_removal_blocking_reason: null,
    ad_removal_completed_windows: null,
    ad_removal_total_windows: null,
    ...overrides,
  };
}

export function adRemovalStatuses(items: AdRemovalStatusItem[]) {
  return { items };
}
