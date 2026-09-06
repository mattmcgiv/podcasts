import { backendBase, offlineEnabled, synchronize } from "./client";
import { prefetch, sweepStaleDownloads } from "./downloads";

export async function bootstrapOffline(): Promise<void> {
  if (!offlineEnabled()) return;
  window.PODS_API_BASE = backendBase();
  if (!navigator.serviceWorker) throw new Error("This browser cannot store offline playback.");
  await navigator.serviceWorker.register("/sw.js", { type: "module" });
  await new Promise<void>((resolve, reject) => {
    const timeout = window.setTimeout(() => reject(new Error("Offline installation did not finish. Reload Pods while connected.")), 30000);
    void navigator.serviceWorker.ready.then(() => { window.clearTimeout(timeout); resolve(); }, reject);
  });
  void navigator.storage?.persist?.();
  const sync = () => {
    if (document.visibilityState === "hidden") {
      void sweepStaleDownloads().catch(() => {});
      return;
    }
    void synchronize().catch(() => {}).then(() => prefetch()).catch(() => {});
  };
  document.addEventListener("visibilitychange", sync);
  window.addEventListener("online", sync);
  window.addEventListener("pods-authenticated", sync);
  window.setInterval(sync, 60000);
  sync();
}
