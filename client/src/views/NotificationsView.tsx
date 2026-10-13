import { useEffect, useState } from "react";
import { navigate } from "../router";
import { clearNotifications, state } from "../offline/client";
import type { PipelineStatus } from "../offline/store";
import { visibleNotifications } from "../offline/store";
import type { ProcessingFailureCategory, ProcessingFailureOutcome, ProcessingNotification } from "../types";

export const COMPACT_NOTIFICATION_LIMIT = 1;

export function failureAreaLabel(category: ProcessingFailureCategory): string {
  switch (category) {
    case "audio_download":
      return "Audio download";
    case "speech_to_text":
      return "Speech-to-text";
    case "ad_classification":
      return "Ad classification";
    case "show_notes":
      return "Show notes";
    case "processing":
      return "Processing";
  }
}

export function failureOutcomeLabel(outcome: ProcessingFailureOutcome): string {
  return outcome === "blocked" ? "Automatic processing stopped" : "Retry scheduled";
}

export function formatNotificationTime(unixSeconds: number): string {
  return new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(
    new Date(unixSeconds * 1000),
  );
}

function episodeTitle(item: ProcessingNotification): string {
  return item.episode_title.trim() || "Untitled episode";
}

function podcastTitle(item: ProcessingNotification): string {
  return item.podcast_title.trim() || "Unknown podcast";
}

function newestFirst(items: ProcessingNotification[]): ProcessingNotification[] {
  return items.slice().sort((a, b) => b.id - a.id);
}

function useCachedNotifications() {
  const [pipeline, setPipeline] = useState<PipelineStatus | null>(null);
  const [items, setItems] = useState<ProcessingNotification[] | null>(null);
  useEffect(() => {
    let active = true;
    let generation = 0;
    const refresh = () => {
      const current = ++generation;
      void state()
        .then((local) => {
          if (active && current === generation) { setItems(newestFirst(visibleNotifications(local))); setPipeline(local.snapshot?.pipeline ?? null); }
        })
        .catch(() => {
          if (active && current === generation) setItems([]);
        });
    };
    refresh();
    window.addEventListener("pods-offline-changed", refresh);
    return () => {
      active = false;
      window.removeEventListener("pods-offline-changed", refresh);
    };
  }, []);
  return { items, pipeline };
}

export function ProcessingNotifications() {
  const { items, pipeline } = useCachedNotifications();
  if (pipeline) {
    const issues = pipeline.items.filter(item => item.state === "needs_attention" || item.state === "retry_scheduled" || item.stalled);
    if (!issues.length && !pipeline.workerError) return null;
    return <button type="button" className="notification-stack" aria-label="Open processing activity" onClick={() => navigate("#/settings")}>
      <span className="notification-bar"><span className="notification-bar-title">{pipeline.workerError || `${issues.length} processing ${issues.length === 1 ? "item needs" : "items need"} attention`}</span>
        <span className="notification-bar-meta">Your work is retained. Open activity for the reason and retry options.</span></span>
    </button>;
  }
  if (items == null || items.length === 0) return null;
  const visible = items.slice(0, COMPACT_NOTIFICATION_LIMIT);
  const label = items.length === 1
    ? "Open 1 processing failure notification"
    : `Open ${items.length} processing failure notifications`;
  return (
    <button type="button" className="notification-stack" onClick={() => navigate("#/notifications")} aria-label={label}>
      {visible.map((item) => (
        <span key={item.id} className="notification-bar">
          <span className="notification-bar-title">{episodeTitle(item)}</span>
          <span className="notification-bar-meta">
            {failureAreaLabel(item.category)} · {failureOutcomeLabel(item.outcome)}
          </span>
        </span>
      ))}
    </button>
  );
}

export function NotificationsView() {
  const cached = useCachedNotifications();
  const items = cached.items ?? [];
  const [clearing, setClearing] = useState(false);
  const [error, setError] = useState<string | null>(null);
  async function clearAll() {
    setClearing(true);
    setError(null);
    try {
      await clearNotifications(items[0].id);
    } catch {
      setError("Could not clear notifications. Try again.");
    } finally {
      setClearing(false);
    }
  }
  return (
    <section className="view">
      <header className="view-header">
        <button type="button" className="icon-btn" onClick={() => navigate("#/recent")} aria-label="Back to Listen">
          <svg viewBox="0 0 24 24" width="24" height="24" aria-hidden>
            <path d="M15 5l-7 7 7 7" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
          </svg>
        </button>
        <h1>Notifications</h1>
        {items.length > 0 && (
          <button type="button" className="notification-clear" disabled={clearing} onClick={() => { void clearAll(); }}>
            {clearing ? "Clearing…" : "Clear all"}
          </button>
        )}
      </header>
      {error && <p role="alert">{error}</p>}
      {cached.pipeline && <button type="button" className="settings-btn" onClick={() => navigate("#/settings")}>View processing activity and retry options</button>}
      {items.length === 0 ? (
        <p className="muted">No processing failures.</p>
      ) : (
        <ul className="notification-list">
          {items.map((item) => (
            <li key={item.id} className="notification-row">
              <p className="notification-row-title">
                {episodeTitle(item)}
                <span className="notification-row-show"> · {podcastTitle(item)}</span>
              </p>
              <p className="notification-row-area">
                {failureAreaLabel(item.category)} · {failureOutcomeLabel(item.outcome)}
              </p>
              <p className="notification-row-message">{item.message}</p>
              <time className="notification-row-time" dateTime={new Date(item.created_at * 1000).toISOString()}>
                {formatNotificationTime(item.created_at)}
              </time>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
