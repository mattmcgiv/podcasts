export const DOWNLOAD_PROGRESS_EVENT = "pods-download-progress";

export interface DownloadProgress {
  episode: number;
  received: number;
  total: number;
}

let current: DownloadProgress | null = null;

export function currentDownloadProgress(): DownloadProgress | null {
  return current;
}

export function setDownloadProgress(next: DownloadProgress | null): void {
  current = next;
  window.dispatchEvent(new CustomEvent(DOWNLOAD_PROGRESS_EVENT, { detail: next }));
}

export function onDownloadProgress(cb: (next: DownloadProgress | null) => void): () => void {
  const handler = (event: Event) => {
    cb((event as CustomEvent<DownloadProgress | null>).detail ?? null);
  };
  window.addEventListener(DOWNLOAD_PROGRESS_EVENT, handler);
  return () => window.removeEventListener(DOWNLOAD_PROGRESS_EVENT, handler);
}

/** Test-only: drop in-memory progress between cases. No-op in production builds. */
export function resetDownloadProgressForTests(): void {
  if (import.meta.env.PROD) return;
  current = null;
}
