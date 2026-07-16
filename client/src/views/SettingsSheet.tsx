import { useEffect, useRef, useState } from "react";
import { Api } from "../api";
import { emitEpisodesChanged } from "../events";
import { refreshFeeds } from "../refreshFeeds";
import type { AdRemovalSettings, RefreshStatus } from "../types";

function formatGB(bytes: number): string {
  return `${(Math.max(0, bytes) / 1_000_000_000).toFixed(2)} GB`;
}

function modelStateLabel(state: string): string {
  return state
    .split("_")
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ");
}

function formatRefreshStatus(refreshStatus: RefreshStatus): string {
  if (refreshStatus.last_success_at == null) {
    return "No successful feed refresh yet.";
  }

  const when = new Intl.DateTimeFormat(undefined, {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date(refreshStatus.last_success_at * 1000));
  const source = refreshStatus.last_source === "manual" ? "Manual" : "Automatic";
  const failures = refreshStatus.last_errors
    ? ` · ${refreshStatus.last_errors} feed${refreshStatus.last_errors === 1 ? "" : "s"} failed`
    : "";
  return `Last feed refresh: ${when} (${source})${failures}`;
}

export function SettingsSheet({ onClose }: { onClose: () => void }) {
  const [status, setStatus] = useState<string | null>(null);
  const [refreshStatus, setRefreshStatus] = useState<RefreshStatus | null>(null);
  const [adRemoval, setAdRemoval] = useState<AdRemovalSettings | null>(null);
  const [feedUrl, setFeedUrl] = useState("");
  const fileRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    let active = true;
    void Api.refreshStatus()
      .then((nextStatus) => {
        if (active) setRefreshStatus(nextStatus);
      })
      .catch(() => {
        // Refresh status is informational; it must not block Settings if unavailable.
      });
    void Api.adRemovalSettings()
      .then((settings) => {
        if (active) setAdRemoval(settings);
      })
      .catch(() => {
        // Older/native-less runtimes may not expose this optional settings section.
      });
    return () => {
      active = false;
    };
  }, []);

  useEffect(() => {
    if (adRemoval?.model_download_state !== "downloading") return;
    const timer = window.setInterval(() => {
      void Api.adRemovalSettings().then(setAdRemoval).catch(() => {});
    }, 5_000);
    return () => window.clearInterval(timer);
  }, [adRemoval?.model_download_state]);

  async function run(label: string, fn: () => Promise<string>) {
    setStatus(`${label}…`);
    try {
      setStatus(await fn());
    } catch (e) {
      setStatus(e instanceof Error ? e.message : String(e));
    }
  }

  async function addByUrl() {
    const url = feedUrl.trim();
    if (!url) return;
    await run("Subscribing", async () => {
      const show = await Api.subscribe(url);
      emitEpisodesChanged();
      setFeedUrl("");
      return `Subscribed to ${show.title}`;
    });
  }

  async function importOpml(file: File) {
    await run("Importing", async () => {
      const text = await file.text();
      const r = await Api.opmlImport(text);
      emitEpisodesChanged();
      return `Imported ${r.imported}, skipped ${r.skipped}, failed ${r.failed}`;
    });
  }

  async function exportOpml() {
    await run("Exporting", async () => {
      const xml = await Api.opmlExport();
      const blob = new Blob([xml], { type: "text/xml" });
      const a = document.createElement("a");
      a.href = URL.createObjectURL(blob);
      a.download = "pods.opml";
      a.click();
      URL.revokeObjectURL(a.href);
      return "Exported pods.opml";
    });
  }

  async function refreshAll() {
    await run("Refreshing", async () => {
      const r = await refreshFeeds();
      // Always reload after an explicit user-initiated refresh so the UI
      // reflects current state (even if no feeds were pulled this pass).
      emitEpisodesChanged();
      try {
        setRefreshStatus(await Api.refreshStatus());
      } catch {
        // The manual refresh succeeded; leave the previous audit status in place.
      }
      return `Refreshed ${r.refreshed} feeds${r.errors ? `, ${r.errors} failed` : ""}`;
    });
  }

  async function enableAdRemoval() {
    if (!adRemoval) return;
    await run("Enabling ad removal", async () => {
      setAdRemoval(await Api.enableAdRemoval(adRemoval.model_total_bytes));
      emitEpisodesChanged();
      return "Ad removal enabled";
    });
  }

  async function disableAdRemoval() {
    await run("Disabling ad removal", async () => {
      setAdRemoval(await Api.disableAdRemoval());
      emitEpisodesChanged();
      return "Ad removal disabled; existing data retained";
    });
  }

  async function resetCorrections(podcastId: number, podcastTitle: string) {
    await run("Resetting corrections", async () => {
      setAdRemoval(await Api.resetAdRemovalCorrections(podcastId));
      return `Reset learned corrections for ${podcastTitle}`;
    });
  }

  async function exportAdRemovalDiagnostics() {
    await run("Exporting diagnostics", async () => {
      const blob = await Api.exportAdRemovalDiagnostics();
      const a = document.createElement("a");
      a.href = URL.createObjectURL(blob);
      a.download = "pods-ad-removal-diagnostics.zip";
      a.click();
      URL.revokeObjectURL(a.href);
      return "Exported ad-removal diagnostics";
    });
  }

  async function clearAdRemovalDiagnostics() {
    await run("Clearing diagnostics", async () => {
      await Api.clearAdRemovalDiagnostics();
      return "Cleared ad-removal diagnostics";
    });
  }

  async function cleanupAdRemovalData() {
    if (!window.confirm(
      "Delete the classifier model, every prepared episode, and all learned corrections? This cannot be undone.",
    )) return;
    await run("Deleting ad-removal data", async () => {
      setAdRemoval(await Api.cleanupAdRemovalData());
      emitEpisodesChanged();
      return "Deleted all ad-removal data";
    });
  }

  return (
    <div className="settings-sheet" role="dialog" aria-label="Settings">
      <header className="sheet-header">
        <button className="icon-btn" onClick={onClose} aria-label="Close settings">
          <svg viewBox="0 0 24 24" width="24" height="24" aria-hidden>
            <path d="M6 6l12 12M18 6L6 18" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
          </svg>
        </button>
        <span className="sheet-show">Settings</span>
        <span className="sheet-spacer" />
      </header>

      <div className="settings-body">
        {adRemoval && (
          <section className="ad-removal-settings" aria-labelledby="ad-removal-title">
            <h2 className="section-title" id="ad-removal-title">Ad removal</h2>
            <p className="settings-detail">
              On-device transcript classification. The {formatGB(adRemoval.model_total_bytes)} model downloads
              over Wi-Fi only.
            </p>
            {adRemoval.enabled ? (
              <>
                <button className="ghost-btn" onClick={() => void disableAdRemoval()}>
                  Disable ad removal
                </button>
                {(adRemoval.model_download_state === "failed"
                  || adRemoval.model_download_state === "not_downloaded") && (
                  <button className="ghost-btn" onClick={() => void enableAdRemoval()}>
                    Retry {formatGB(adRemoval.model_total_bytes)} model download
                  </button>
                )}
              </>
            ) : (
              <button className="ghost-btn" onClick={() => void enableAdRemoval()}>
                Enable and download {formatGB(adRemoval.model_total_bytes)}
              </button>
            )}
            <p className="settings-detail">
              Model download: {modelStateLabel(adRemoval.model_download_state)} ·{" "}
              {formatGB(Math.min(adRemoval.model_downloaded_bytes, adRemoval.model_total_bytes))} of{" "}
              {formatGB(adRemoval.model_total_bytes)}
            </p>
            <p className="settings-detail settings-revision">
              Revision {adRemoval.model_revision}
            </p>
            <p className="settings-detail">
              Prepared episode storage: {formatGB(adRemoval.episode_storage_bytes)} of{" "}
              {formatGB(adRemoval.episode_storage_limit_bytes)} · {formatGB(adRemoval.device_available_bytes)} free
            </p>

            {adRemoval.corrections.length > 0 && (
              <div className="correction-list">
                <p className="settings-detail">Learned corrections</p>
                {adRemoval.corrections.map((correction) => (
                  <div className="correction-row" key={correction.podcast_id}>
                    <span>{correction.podcast_title}: {correction.count}</span>
                    <button
                      className="ghost-btn small"
                      aria-label={`Reset learned corrections for ${correction.podcast_title}`}
                      onClick={() => void resetCorrections(correction.podcast_id, correction.podcast_title)}
                    >
                      Reset
                    </button>
                  </div>
                ))}
              </div>
            )}

            <button className="ghost-btn" onClick={() => void exportAdRemovalDiagnostics()}>
              Export ad-removal diagnostics
            </button>
            <button className="ghost-btn" onClick={() => void clearAdRemovalDiagnostics()}>
              Clear ad-removal diagnostics
            </button>
            <button className="ghost-btn danger" onClick={() => void cleanupAdRemovalData()}>
              Delete all ad-removal data
            </button>
          </section>
        )}

        <h2 className="section-title">Add a feed by URL</h2>
        <div className="add-url-row">
          <input
            type="url"
            placeholder="https://example.com/feed.xml"
            value={feedUrl}
            onChange={(e) => setFeedUrl(e.target.value)}
            aria-label="Feed URL"
          />
          <button onClick={() => void addByUrl()} disabled={!feedUrl.trim()}>
            Add
          </button>
        </div>

        <h2 className="section-title">Subscriptions</h2>
        <button className="ghost-btn" onClick={() => fileRef.current?.click()}>
          Import OPML
        </button>
        <input
          ref={fileRef}
          type="file"
          accept=".opml,.xml,text/xml"
          hidden
          data-testid="opml-file"
          onChange={(e) => {
            const f = e.target.files?.[0];
            if (f) void importOpml(f);
            e.target.value = "";
          }}
        />
        <button className="ghost-btn" onClick={() => void exportOpml()}>
          Export OPML
        </button>
        <button className="ghost-btn" onClick={() => void refreshAll()}>
          Refresh all feeds
        </button>

        {refreshStatus && <p className="muted">{formatRefreshStatus(refreshStatus)}</p>}

        {status && <p className="status">{status}</p>}
      </div>
    </div>
  );
}
