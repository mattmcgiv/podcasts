/// <reference lib="webworker" />
import { localMedia } from "./offline/media";
const worker = globalThis as unknown as ServiceWorkerGlobalScope;
const SHELL = "pods-shell-" + __PODS_BUILD_ID__;
const ARTWORK = "pods-artwork-v1";
declare const __PODS_BUILD_ID__: string;

worker.addEventListener("install", event => {
  event.waitUntil((async () => {
    const paths: string[] = await fetch("/offline-assets.json", { cache: "no-store" }).then(r => r.json());
    const cache = await caches.open(SHELL);
    await cache.addAll(paths);
    // Activate on the next app launch, without replacing code beneath active playback.
  })());
});
worker.addEventListener("activate", event => {
  event.waitUntil((async () => {
    for (const key of await caches.keys()) if (key.startsWith("pods-shell-") && key !== SHELL) await caches.delete(key);
    await worker.clients.claim();
  })());
});
worker.addEventListener("fetch", event => {
  const url = new URL(event.request.url);
  if (url.origin === worker.location.origin && url.pathname.startsWith("/_media/")) {
    event.respondWith(localMedia(event.request)); return;
  }
  if (event.request.method !== "GET" || url.pathname.startsWith("/api/")) return;
  if (event.request.destination === "image") {
    event.respondWith((async () => {
      const cache = await caches.open(ARTWORK);
      const saved = await cache.match(event.request);
      if (saved) return saved;
      try {
        // Cross-origin artwork fetch() uses this worker's connect-src, not document img-src.
        const response = await fetch(event.request);
        if (response.ok || response.type === "opaque") {
          await cache.put(event.request, response.clone());
          const keys = await cache.keys();
          if (keys.length > 200) await cache.delete(keys[0]);
        }
        return response;
      } catch { return new Response(null, { status: 503 }); }
    })());
    return;
  }
  if (url.origin === worker.location.origin) event.respondWith((async () => {
    const cache = await caches.open(SHELL);
    const saved = await cache.match(event.request.mode === "navigate" ? "/index.html" : event.request);
    // Pages redirects /index.html to /. Navigation requests reject a cached
    // redirected response, even though its final status is 200.
    if (saved?.redirected && event.request.mode === "navigate") {
      return new Response(saved.body, { status: saved.status, statusText: saved.statusText, headers: saved.headers });
    }
    return saved ?? fetch(event.request);
  })());
});
