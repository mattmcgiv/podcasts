import { flushVoiceDrafts } from "../voice";
import { backendBase, offlineEnabled, synchronize } from "./client";
import { DOWNLOAD_QUEUE_EVENT, listenForDownloadChanges, prefetch, sweepStaleDownloads } from "./downloads";
import { logDiagnostic } from "./diagnostics";

declare const __PODS_BUILD_ID__: string;

export async function bootstrapOffline(): Promise<(() => void) | undefined> {
  if (!offlineEnabled()) return;
  window.PODS_API_BASE = backendBase();
  if (!navigator.serviceWorker) throw new Error("This browser cannot store offline playback.");
  logDiagnostic("app-build", __PODS_BUILD_ID__);
  // Updating the app shell must not disable downloads when a worker already
  // controls this page (for example, Pages is offline but the Mac is reachable).
  const registration = navigator.serviceWorker.register("/sw.js", { type: "module", updateViaCache: "none" });
  if (navigator.serviceWorker.controller) void registration.catch(() => logDiagnostic("shell-update", "Using the installed offline shell; update unavailable."));
  else await registration;
  await new Promise<void>((resolve, reject) => {
    const timeout = window.setTimeout(() => reject(new Error("Offline installation did not finish. Reload Pods while connected.")), 30000);
    void navigator.serviceWorker.ready.then(() => { window.clearTimeout(timeout); resolve(); }, reject);
  });
  void navigator.storage?.persist?.();
  let retryTimer: number | null = null;
  let retryDelay = 5_000;
  let active = true;
  const stopDownloads = listenForDownloadChanges();
  const download = () => { if (active) void prefetch().catch(() => {}); };
  const sync = () => {
    if (!active) return;
    if (document.visibilityState === "hidden") {
      void sweepStaleDownloads().catch(() => {});
      return;
    }
    // Cached, verified manifests can download independently of metadata sync.
    // A slow probe, rejected action or failed snapshot must not gate the queue.
    download();
    void synchronize()
      .then(() => {
        if (!active) return;
        void flushVoiceDrafts().catch(() => {});
        download();
        if (retryTimer) window.clearTimeout(retryTimer);
        retryTimer = null;
        retryDelay = 5_000;
      })
      .catch(() => {
        if (!active) return;
        if (retryTimer) window.clearTimeout(retryTimer);
        retryTimer = window.setTimeout(sync, retryDelay);
        retryDelay = Math.min(retryDelay * 3, 300_000);
      });
  };
  document.addEventListener("visibilitychange", sync);
  window.addEventListener("pageshow", sync);
  window.addEventListener("focus", sync);
  window.addEventListener("online", sync);
  window.addEventListener("pods-authenticated", sync);
  window.addEventListener(DOWNLOAD_QUEUE_EVENT, download);
  const interval = window.setInterval(sync, 60000);
  sync();
  return () => {
    active = false;
    stopDownloads();
    if (retryTimer) window.clearTimeout(retryTimer);
    window.clearInterval(interval);
    document.removeEventListener("visibilitychange", sync);
    for (const event of ["pageshow", "focus", "online", "pods-authenticated"]) window.removeEventListener(event, sync);
    window.removeEventListener(DOWNLOAD_QUEUE_EVENT, download);
  };
}
