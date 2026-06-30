import { afterEach, describe, expect, it } from "vitest";
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
  });

  it("uses the native API base when provided", async () => {
    window.PODS_API_BASE = "http://127.0.0.1:18180";
    const { calls } = installApi({ "GET /api/recent": page([]) });
    await Api.recent();
    expect(calls[0].url.origin).toBe("http://127.0.0.1:18180");
  });

  it("surfaces server error messages", async () => {
    installApi({ "POST /api/shows": new HttpError(409, { error: "already subscribed" }) });
    await expect(Api.subscribe("https://x.example/f")).rejects.toThrow("already subscribed");
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
});
