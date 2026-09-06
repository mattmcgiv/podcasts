import { readFileSync } from "node:fs";
import { beforeEach, afterEach, expect, it, vi } from "vitest";
import { localMedia } from "./offline/media";
vi.mock("./offline/media", () => ({ localMedia: vi.fn() }));
let listeners: Record<string, (event: never) => void>;
let cache: { addAll: ReturnType<typeof vi.fn>; match: ReturnType<typeof vi.fn>; put: ReturnType<typeof vi.fn>; keys: ReturnType<typeof vi.fn>; delete: ReturnType<typeof vi.fn> };
beforeEach(async () => {
  vi.resetModules(); listeners = {};
  cache = { addAll: vi.fn().mockResolvedValue(undefined), match: vi.fn().mockResolvedValue(undefined), put: vi.fn().mockResolvedValue(undefined), keys: vi.fn().mockResolvedValue([]), delete: vi.fn().mockResolvedValue(true) };
  vi.stubGlobal("addEventListener", vi.fn((name, callback) => { listeners[name] = callback; }));
  vi.stubGlobal("caches", { open: vi.fn().mockResolvedValue(cache), keys: vi.fn().mockResolvedValue(["pods-shell-old", "pods-artwork-v1"]), delete: vi.fn().mockResolvedValue(true) });
  vi.stubGlobal("clients", { claim: vi.fn().mockResolvedValue(undefined) });
  vi.stubGlobal("fetch", vi.fn().mockResolvedValue(new Response(JSON.stringify(["/index.html"]))));
  await import("./sw");
});
afterEach(() => vi.unstubAllGlobals());
async function fetchEvent(url: string, extras: { method?: string; destination?: string; mode?: string } = {}) {
  let response: Promise<Response> | undefined;
  listeners.fetch({ request: { url, method: "GET", destination: "", ...extras }, respondWith: (value: Promise<Response>) => { response = value; } } as never);
  return response;
}
function parsePagesHeaders(text: string) {
  const rules: { path: string; set: Record<string, string>; unset: string[] }[] = [];
  let rule: { path: string; set: Record<string, string>; unset: string[] } | undefined;
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    if (line.startsWith("/")) {
      rule = { path: line, set: {}, unset: [] };
      rules.push(rule);
      continue;
    }
    if (!rule) continue;
    if (line.startsWith("! ")) { rule.unset.push(line.slice(2).trim()); continue; }
    const sep = line.indexOf(":");
    if (sep === -1) continue;
    rule.set[line.slice(0, sep).trim().toLowerCase()] = line.slice(sep + 1).trim();
  }
  return rules;
}
function pagesHeadersFor(rules: ReturnType<typeof parsePagesHeaders>, pathname: string) {
  const headers = new Headers();
  const seen = new Set<string>();
  for (const rule of rules) {
    const pattern = "^" + rule.path.split("*").map(part => part.replace(/[.+?^${}()|[\]\\]/g, "\\$&")).join(".*") + "$";
    if (!new RegExp(pattern).test(pathname)) continue;
    for (const name of rule.unset) headers.delete(name);
    for (const [name, value] of Object.entries(rule.set)) {
      if (seen.has(name)) headers.append(name, value);
      else { headers.set(name, value); seen.add(name); }
    }
  }
  return headers;
}
function cspSources(header: string | null, directive: string) {
  if (!header) return [];
  const match = header.split(";").map(part => part.trim()).find(part => part === directive || part.startsWith(directive + " "));
  return match ? match.slice(directive.length).trim().split(/\s+/).filter(Boolean) : [];
}
it("installs a complete shell and removes only obsolete shell caches", async () => {
  let work: Promise<void> | undefined;
  listeners.install({ waitUntil: (promise: Promise<void>) => { work = promise; } } as never); await work;
  expect(cache.addAll).toHaveBeenCalledWith(["/index.html"]);
  listeners.activate({ waitUntil: (promise: Promise<void>) => { work = promise; } } as never); await work;
  expect(caches.delete).toHaveBeenCalledWith("pods-shell-old");
  expect(caches.delete).not.toHaveBeenCalledWith("pods-artwork-v1");
});
it("routes local media and navigations without caching API mutations", async () => {
  vi.mocked(localMedia).mockResolvedValue(new Response("audio"));
  expect(await (await fetchEvent(`${location.origin}/_media/test`))?.text()).toBe("audio");
  expect(await fetchEvent(`${location.origin}/api/sync`)).toBeUndefined();
  expect(await fetchEvent(`${location.origin}/write`, { method: "POST" })).toBeUndefined();
  cache.match.mockResolvedValue(new Response("shell"));
  expect(await (await fetchEvent(`${location.origin}/#/recent`, { mode: "navigate" }))?.text()).toBe("shell");
  expect(cache.match).toHaveBeenCalledWith("/index.html");
  cache.match.mockResolvedValue(undefined);
  expect(await fetchEvent(`${location.origin}/new.js`)).toBeInstanceOf(Response);
});
it("caches artwork with a bound and returns unavailable offline without a cached image", async () => {
  cache.match.mockResolvedValue(new Response("saved"));
  expect(await (await fetchEvent("https://publisher.example/image", { destination: "image" }))?.text()).toBe("saved");
  cache.match.mockResolvedValue(undefined);
  cache.keys.mockResolvedValue(Array.from({ length: 201 }, (_, i) => `image${i}`));
  await fetchEvent("https://publisher.example/image", { destination: "image" });
  expect(fetch).toHaveBeenCalledWith(expect.objectContaining({ url: "https://publisher.example/image" }));
  expect(cache.put).toHaveBeenCalled(); expect(cache.delete).toHaveBeenCalledWith("image0");
  vi.mocked(fetch).mockRejectedValue(new Error("offline"));
  expect((await fetchEvent("https://publisher.example/other", { destination: "image" }))?.status).toBe(503);
});
it("does not fetch original audio as a fallback", async () => {
  expect(await fetchEvent("https://publisher.example/episode.mp3", { destination: "audio" })).toBeUndefined();
});
it("lets the worker fetch publisher artwork without loosening the document connect-src", () => {
  const rules = parsePagesHeaders(readFileSync("public/_headers", "utf8"));
  const pageCsp = pagesHeadersFor(rules, "/").get("content-security-policy");
  expect(cspSources(pageCsp, "img-src")).toEqual(["'self'", "https:", "data:", "blob:"]);
  expect(cspSources(pageCsp, "connect-src")).toEqual(["'self'", "https://sync.pods.mcgiv.dev:8443"]);
  expect(pagesHeadersFor(rules, "/index.html").get("content-security-policy")).toBe(pageCsp);

  const workerRule = rules.find(rule => rule.path === "/sw.js");
  expect(workerRule?.unset.map(name => name.toLowerCase())).toContain("content-security-policy");
  const workerCsp = pagesHeadersFor(rules, "/sw.js").get("content-security-policy");
  expect(workerCsp).not.toContain("https://sync.pods.mcgiv.dev:8443");
  expect(cspSources(workerCsp, "connect-src")).toEqual(["'self'", "https:"]);
  expect(cspSources(workerCsp, "script-src")).toContain("'self'");
});
it("normalizes a redirected Pages shell for offline navigation", async () => {
  const redirected = new Response("cached shell", { headers: { "Content-Type": "text/html" } });
  Object.defineProperty(redirected, "redirected", { value: true });
  cache.match.mockResolvedValue(redirected);
  vi.mocked(fetch).mockRejectedValue(new Error("offline"));
  const response = await fetchEvent(`${location.origin}/`, { mode: "navigate" });
  expect(response?.redirected).toBe(false);
  expect(response?.status).toBe(200);
  expect(response?.headers.get("Content-Type")).toBe("text/html");
  expect(await response?.text()).toBe("cached shell");
});
