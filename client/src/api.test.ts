import { afterEach, describe, expect, it, vi } from "vitest";
import { Api } from "./api";
import { episode, HttpError, installApi, page } from "./test/mockApi";

afterEach(() => {
  delete window.PODS_API_BASE;
});

describe("request wrapper", () => {
  it("parses json without sending bearer auth", async () => {
    const { calls } = installApi({ "GET /api/recent": page([episode()]) });
    const res = await Api.recent();
    expect(res.items[0].title).toBe("Test Episode");
    const headers = new Headers(calls[0].init.headers);
    expect(headers.has("authorization")).toBe(false);
    expect(calls[0].init.credentials).toBe("include");
  });

  it("uses the native API base when provided", async () => {
    window.PODS_API_BASE = "http://127.0.0.1:18180";
    const { calls } = installApi({ "GET /api/recent": page([]) });
    await Api.recent();
    expect(calls[0].url.origin).toBe("http://127.0.0.1:18180");
  });

  it("surfaces server error messages", async () => {
    const warning = vi.spyOn(console, "warn").mockImplementation(() => {});
    installApi({ "POST /api/shows": new HttpError(409, { error: "already subscribed" }) });
    await expect(Api.subscribe("https://x.example/f")).rejects.toThrow("already subscribed");
    expect(warning).toHaveBeenCalledWith(
      "api_http_failed method=POST target=/api/shows status=409 message=already subscribed",
    );
    warning.mockRestore();
  });

  it("logs transport failures with method and target", async () => {
    const warning = vi.spyOn(console, "warn").mockImplementation(() => {});
    vi.spyOn(globalThis, "fetch").mockRejectedValueOnce(new TypeError("Load failed"));

    await expect(Api.recent()).rejects.toThrow("Load failed");
    expect(warning).toHaveBeenCalledWith(
      "api_fetch_failed method=GET target=/api/recent?offset=0 error=TypeError: Load failed",
    );
    warning.mockRestore();
  });

  it("handles 204 and raw text responses", async () => {
    installApi({
      "POST /api/episodes/5/played": null,
      "GET /api/opml": "<opml/>",
    });
    await expect(Api.markPlayed(5)).resolves.toBeUndefined();
    await expect(Api.opmlExport()).resolves.toBe("<opml/>");
  });

  it("builds query strings for search, show search, and next", async () => {
    const { calls } = installApi({
      "GET /api/search": { directory_configured: false, podcasts: [], episodes: [] },
      "GET /api/shows/5/search": page([episode({ title: "Specific Episode" })]),
      "GET /api/next": null,
    });
    await Api.search("hello world");
    await Api.showSearch(5, "specific");
    await Api.next(42, "show");
    expect(calls[0].url.searchParams.get("q")).toBe("hello world");
    expect(calls[1].key).toBe("GET /api/shows/5/search");
    expect(calls[1].url.searchParams.get("q")).toBe("specific");
    expect(calls[2].url.searchParams.get("after")).toBe("42");
    expect(calls[2].url.searchParams.get("context")).toBe("show");
  });

  it("posts and reviews person follows", async () => {
    const { calls } = installApi({
      "POST /api/follows": { id: 1, name: "Balaji Srinivasan", aliases: [], last_checked_at: null, pending_count: 0, accepted_count: 0 },
      "POST /api/follows/1": { id: 1, name: "Balaji Srinivasan", aliases: [], last_checked_at: 9, pending_count: 0, accepted_count: 0 },
      "POST /api/follow-candidates/5/accept": null,
      "POST /api/follow-candidates/5/reject": null,
    });
    await Api.addFollow("Balaji Srinivasan", ["Balaji S Srinivasan"]);
    await Api.refreshFollow(1);
    await Api.acceptFollowCandidate(5);
    await Api.rejectFollowCandidate(5);
    expect(JSON.parse(String(calls[0].init.body))).toEqual({ name: "Balaji Srinivasan", aliases: ["Balaji S Srinivasan"] });
    expect(calls[1].key).toBe("POST /api/follows/1");
    expect(calls[2].key).toBe("POST /api/follow-candidates/5/accept");
    expect(calls[3].key).toBe("POST /api/follow-candidates/5/reject");
  });

  it("disables ad removal", async () => {
    const { calls } = installApi({
      "POST /api/ad-removal/disable": { enabled: false },
    });
    await Api.disableAdRemoval();
    expect(calls[0].key).toBe("POST /api/ad-removal/disable");
  });

  it("downloads ad-removal diagnostics as a blob", async () => {
    installApi({
      "GET /api/ad-removal/diagnostics/export": new Blob(["zip"], { type: "application/zip" }),
    });
    const blob = await Api.exportAdRemovalDiagnostics();
    expect(blob.size).toBe(3);
  });

  it("logs blob transport failures with method and target", async () => {
    const warning = vi.spyOn(console, "warn").mockImplementation(() => {});
    vi.spyOn(globalThis, "fetch").mockRejectedValueOnce(new TypeError("Load failed"));

    await expect(Api.exportAdRemovalDiagnostics()).rejects.toThrow("Load failed");
    expect(warning).toHaveBeenCalledWith(
      "api_fetch_failed method=GET target=/api/ad-removal/diagnostics/export error=TypeError: Load failed",
    );
    warning.mockRestore();
  });

  it("surfaces blob server error messages", async () => {
    const warning = vi.spyOn(console, "warn").mockImplementation(() => {});
    installApi({
      "GET /api/ad-removal/diagnostics/export": new HttpError(500, { error: "zip failed" }),
    });
    await expect(Api.exportAdRemovalDiagnostics()).rejects.toThrow("zip failed");
    expect(warning).toHaveBeenCalledWith(
      "api_http_failed method=GET target=/api/ad-removal/diagnostics/export status=500 message=zip failed",
    );
    warning.mockRestore();
  });

  it("falls back to status text when a blob error body is not json", async () => {
    const warning = vi.spyOn(console, "warn").mockImplementation(() => {});
    vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(
      new Response("nope", { status: 502, statusText: "Bad Gateway" }),
    );
    await expect(Api.exportAdRemovalDiagnostics()).rejects.toThrow("Bad Gateway");
    expect(warning).toHaveBeenCalledWith(
      "api_http_failed method=GET target=/api/ad-removal/diagnostics/export status=502 message=Bad Gateway",
    );
    warning.mockRestore();
  });

  it("previews a feed and adds one episode to Listen", async () => {
    const { calls } = installApi({
      "POST /api/feeds/preview": {
        feed_url: "https://one.example/rss",
        title: "Guest Interviews",
        image_url: "",
        episodes: [{ guid: "g2", title: "Beta Guest", published_at: 1, duration_secs: null, image_url: "" }],
      },
      "POST /api/listen-episodes": episode({ title: "Beta Guest" }),
    });
    await Api.previewFeed("https://one.example/rss");
    await Api.addListenEpisode("https://one.example/rss", "g2");
    expect(JSON.parse(String(calls[0].init.body))).toEqual({ feed_url: "https://one.example/rss" });
    expect(JSON.parse(String(calls[1].init.body))).toEqual({ feed_url: "https://one.example/rss", guid: "g2" });
  });
});
