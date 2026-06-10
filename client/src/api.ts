import type {
  EpisodeDetail,
  EpisodeItem,
  Page,
  PlayContext,
  SearchResults,
  Settings,
  Show,
  ShowDetailResponse,
} from "./types";

const TOKEN_KEY = "pods-token";

export function getToken(): string | null {
  return localStorage.getItem(TOKEN_KEY);
}

export function setToken(token: string): void {
  localStorage.setItem(TOKEN_KEY, token);
}

export function clearToken(): void {
  localStorage.removeItem(TOKEN_KEY);
}

export class ApiError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

export const UNAUTHORIZED_EVENT = "pods-unauthorized";

async function request<T>(path: string, init: RequestInit = {}, raw = false): Promise<T> {
  const headers = new Headers(init.headers);
  const token = getToken();
  if (token) headers.set("authorization", `Bearer ${token}`);
  if (init.body != null && !headers.has("content-type")) {
    headers.set("content-type", "application/json");
  }
  const res = await fetch(`/api${path}`, { ...init, headers });
  if (res.status === 401) {
    clearToken();
    window.dispatchEvent(new Event(UNAUTHORIZED_EVENT));
    throw new ApiError(401, "unauthorized");
  }
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

export const Api = {
  async login(token: string): Promise<void> {
    const res = await fetch("/api/login", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ token }),
    });
    if (!res.ok) throw new ApiError(res.status, "That token didn't work");
    setToken(token);
  },

  recent: (offset = 0) => request<Page<EpisodeItem>>(`/recent?offset=${offset}`),
  played: (offset = 0) => request<Page<EpisodeItem>>(`/played?offset=${offset}`),
  shows: () => request<Show[]>("/shows"),
  show: (id: number, offset = 0) =>
    request<ShowDetailResponse>(`/shows/${id}?offset=${offset}`),
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
  settings: () => request<Settings>("/settings"),
  saveSettings: (s: Settings) =>
    request<void>("/settings", { method: "PUT", body: JSON.stringify(s) }),
  search: (q: string) => request<SearchResults>(`/search?q=${encodeURIComponent(q)}`),
  next: (afterId: number, context: PlayContext) =>
    request<EpisodeItem | null>(`/next?after=${afterId}&context=${context}`),
  refresh: () => request<{ refreshed: number; errors: number }>("/refresh", { method: "POST" }),
  opmlExport: () => request<string>("/opml", {}, true),
  opmlImport: (xml: string) =>
    request<{ imported: number; skipped: number; failed: number }>("/opml", {
      method: "POST",
      headers: { "content-type": "text/xml" },
      body: xml,
    }),
};
