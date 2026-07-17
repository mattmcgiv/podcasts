import type {
  AdRemovalSettings,
  AdRemovalStatusesPayload,
  EpisodeDetail,
  EpisodeItem,
  Page,
  PlayContext,
  RefreshStatus,
  SearchResults,
  Settings,
  Show,
  ShowDetailResponse,
} from "./types";

declare global {
  interface Window {
    PODS_API_BASE?: string;
  }
}

export class ApiError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

async function request<T>(path: string, init: RequestInit = {}, raw = false): Promise<T> {
  const headers = new Headers(init.headers);
  if (init.body != null && !headers.has("content-type")) {
    headers.set("content-type", "application/json");
  }
  const res = await fetch(`${window.PODS_API_BASE ?? ""}/api${path}`, { ...init, headers });
  if (!res.ok) {
    let message = res.statusText || `HTTP ${res.status}`;
    try {
      const body = (await res.json()) as { error?: string };
      if (body.error) message = body.error;
    } catch {
      // non-JSON error body; keep the status text
    }
    throw new ApiError(res.status, message);
  }
  if (res.status === 204) return undefined as T;
  return (raw ? res.text() : res.json()) as Promise<T>;
}

async function requestBlob(path: string, init: RequestInit = {}): Promise<Blob> {
  const res = await fetch(`${window.PODS_API_BASE ?? ""}/api${path}`, init);
  if (!res.ok) {
    let message = res.statusText || `HTTP ${res.status}`;
    try {
      const body = (await res.json()) as { error?: string };
      if (body.error) message = body.error;
    } catch {
      // non-JSON error body; keep the status text
    }
    throw new ApiError(res.status, message);
  }
  return res.blob();
}

export const Api = {
  recent: (offset = 0) => request<Page<EpisodeItem>>(`/recent?offset=${offset}`),
  played: (offset = 0) => request<Page<EpisodeItem>>(`/played?offset=${offset}`),
  shows: () => request<Show[]>("/shows"),
  show: (id: number, offset = 0) =>
    request<ShowDetailResponse>(`/shows/${id}?offset=${offset}`),
  showSearch: (id: number, q: string) =>
    request<Page<EpisodeItem>>(`/shows/${id}/search?q=${encodeURIComponent(q)}`),
  subscribe: (feedUrl: string) =>
    request<Show>("/shows", { method: "POST", body: JSON.stringify({ feed_url: feedUrl }) }),
  unsubscribe: (id: number) => request<void>(`/shows/${id}`, { method: "DELETE" }),
  episode: (id: number) => request<EpisodeDetail>(`/episodes/${id}`),
  markPlayed: (id: number) => request<void>(`/episodes/${id}/played`, { method: "POST" }),
  unmarkPlayed: (id: number) => request<void>(`/episodes/${id}/played`, { method: "DELETE" }),
  setPosition: (id: number, seconds: number) =>
    request<void>(`/episodes/${id}/position`, {
      method: "PUT",
      body: JSON.stringify({ seconds }),
    }),
  prepareAdRemoval: (id: number) =>
    request<{ stage: string }>(`/episodes/${id}/ad-removal/prepare`, { method: "POST" }),
  retryAdRemoval: (id: number) =>
    request<{ stage: string }>(`/episodes/${id}/ad-removal/retry`, { method: "POST" }),
  adRemovalStatuses: (episodeIds: number[]) =>
    request<AdRemovalStatusesPayload>(
      `/ad-removal/statuses?episode_ids=${episodeIds.join(",")}`,
    ),
  adRemovalSettings: () => request<AdRemovalSettings>("/ad-removal/settings"),
  enableAdRemoval: (confirmedBytes: number) =>
    request<AdRemovalSettings>("/ad-removal/enable", {
      method: "POST",
      body: JSON.stringify({ confirmed_bytes: confirmedBytes }),
    }),
  disableAdRemoval: () =>
    request<AdRemovalSettings>("/ad-removal/disable", { method: "POST" }),
  resetAdRemovalCorrections: (podcastId: number) =>
    request<AdRemovalSettings>(`/ad-removal/corrections/${podcastId}/reset`, { method: "POST" }),
  exportAdRemovalDiagnostics: () => requestBlob("/ad-removal/diagnostics/export"),
  clearAdRemovalDiagnostics: () =>
    request<void>("/ad-removal/diagnostics/clear", { method: "POST" }),
  cleanupAdRemovalData: () =>
    request<AdRemovalSettings>("/ad-removal/cleanup", {
      method: "POST",
      body: JSON.stringify({ confirm: "DELETE_AD_REMOVAL_DATA" }),
    }),
  settings: () => request<Settings>("/settings"),
  saveSettings: (s: Settings) =>
    request<void>("/settings", { method: "PUT", body: JSON.stringify(s) }),
  search: (q: string) => request<SearchResults>(`/search?q=${encodeURIComponent(q)}`),
  next: (afterId: number, context: PlayContext) =>
    request<EpisodeItem | null>(`/next?after=${afterId}&context=${context}`),
  /** @param init.signal optional AbortSignal to cancel a hung refresh */
  refresh: (init: { signal?: AbortSignal } = {}) =>
    request<{ refreshed: number; errors: number }>("/refresh", {
      method: "POST",
      signal: init.signal,
    }),
  refreshStatus: () => request<RefreshStatus>("/refresh-status"),
  opmlExport: () => request<string>("/opml", {}, true),
  opmlImport: (xml: string) =>
    request<{ imported: number; skipped: number; failed: number }>("/opml", {
      method: "POST",
      headers: { "content-type": "text/xml" },
      body: xml,
    }),
};
