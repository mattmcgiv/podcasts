import { useEffect, useRef, useState } from "react";
import { Api } from "../api";
import { emitEpisodesChanged } from "../events";
import { refreshFeeds } from "../refreshFeeds";
import type { RefreshStatus } from "../types";

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
    return () => {
      active = false;
    };
  }, []);

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
