import { describe, expect, it, vi } from "vitest";
import { Api, clearToken, getToken, setToken, UNAUTHORIZED_EVENT } from "./api";
import { episode, HttpError, installApi, page } from "./test/mockApi";

describe("token storage", () => {
  it("round-trips", () => {
    expect(getToken()).toBeNull();
    setToken("abc");
    expect(getToken()).toBe("abc");
    clearToken();
    expect(getToken()).toBeNull();
  });
});

describe("request wrapper", () => {
  it("sends the bearer token and parses json", async () => {
    setToken("sekrit");
    const { calls } = installApi({ "GET /api/recent": page([episode()]) });
    const res = await Api.recent();
    expect(res.items[0].title).toBe("Test Episode");
    const headers = new Headers(calls[0].init.headers);
    expect(headers.get("authorization")).toBe("Bearer sekrit");
  });

  it("clears the token and broadcasts on 401", async () => {
    setToken("stale");
    installApi({ "GET /api/recent": new HttpError(401) });
    const listener = vi.fn();
    window.addEventListener(UNAUTHORIZED_EVENT, listener);
    await expect(Api.recent()).rejects.toMatchObject({ status: 401 });
    expect(getToken()).toBeNull();
    expect(listener).toHaveBeenCalled();
    window.removeEventListener(UNAUTHORIZED_EVENT, listener);
  });

  it("surfaces server error messages", async () => {
    setToken("t");
    installApi({ "POST /api/shows": new HttpError(409, { error: "already subscribed" }) });
    await expect(Api.subscribe("https://x.example/f")).rejects.toThrow("already subscribed");
  });

  it("handles 204 and raw text responses", async () => {
    setToken("t");
    installApi({
      "POST /api/episodes/5/played": null,
      "GET /api/opml": "<opml/>",
    });
    await expect(Api.markPlayed(5)).resolves.toBeUndefined();
    await expect(Api.opmlExport()).resolves.toBe("<opml/>");
  });

  it("builds query strings for search and next", async () => {
    setToken("t");
    const { calls } = installApi({
      "GET /api/search": { directory_configured: false, podcasts: [], episodes: [] },
      "GET /api/next": null,
    });
    await Api.search("hello world");
    await Api.next(42, "show");
    expect(calls[0].url.searchParams.get("q")).toBe("hello world");
    expect(calls[1].url.searchParams.get("after")).toBe("42");
    expect(calls[1].url.searchParams.get("context")).toBe("show");
  });
});

describe("login", () => {
  it("stores the token on success", async () => {
    installApi({ "POST /api/login": null });
    await Api.login("good-token");
    expect(getToken()).toBe("good-token");
  });

  it("does not store the token on failure", async () => {
    installApi({ "POST /api/login": new HttpError(401) });
    await expect(Api.login("bad")).rejects.toThrow();
    expect(getToken()).toBeNull();
  });
});
