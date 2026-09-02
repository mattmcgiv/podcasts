import { useEffect, useRef, useState } from "react";
import { Api } from "../api";
import { emitEpisodesChanged } from "../events";
import { refreshFeeds } from "../refreshFeeds";
import { applyThemePreference, currentThemePreference, type ThemePreference } from "../theme";
import { formatOptionalUSD, formatUSD, fmtDate, fmtDuration } from "../lib";
import type { AdRemovalSettings, CarBluetoothSettings, FeedPreview, FeedPreviewEpisode, RefreshStatus } from "../types";

function formatGB(bytes: number): string {
  return `${(Math.max(0, bytes) / 1_000_000_000).toFixed(2)} GB`;
}

function formatRefreshStatus(refreshStatus: RefreshStatus): string {
  if (refreshStatus.is_refreshing) {
    return "Refreshing feeds…";
  }
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
  // Settings is a top-level route; retain the prop for call-site compatibility.
  void onClose;
  const [status, setStatus] = useState<string | null>(null);
  const [refreshStatus, setRefreshStatus] = useState<RefreshStatus | null>(null);
  const [adRemoval, setAdRemoval] = useState<AdRemovalSettings | null>(null);
  const [carBluetooth, setCarBluetooth] = useState<CarBluetoothSettings | null>(null);
  const [deepSeekApiKey, setDeepSeekApiKey] = useState("");
  const [feedUrl, setFeedUrl] = useState("");
  const [oneOffUrl, setOneOffUrl] = useState("");
  const [oneOffQuery, setOneOffQuery] = useState("");
  const [oneOffPreview, setOneOffPreview] = useState<FeedPreview | null>(null);
  const [addedGuids, setAddedGuids] = useState<Set<string>>(new Set());
  const [addingGuid, setAddingGuid] = useState<string | null>(null);
  const [themePreference, setThemePreference] = useState<ThemePreference>(currentThemePreference);
  const [refreshing, setRefreshing] = useState(false);
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
    void Api.carBluetoothSettings()
      .then((settings) => {
        if (active) setCarBluetooth(settings);
      })
      .catch(() => {
        // Older/native-less runtimes may not expose car Bluetooth enrollment.
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

  async function lookupOneOffFeed() {
    const url = oneOffUrl.trim();
    if (!url) return;
    await run("Looking up", async () => {
      const preview = await Api.previewFeed(url);
      setOneOffPreview(preview);
      setOneOffQuery("");
      setAddedGuids(new Set());
      const count = preview.episodes.length;
      return `Found ${count} episode${count === 1 ? "" : "s"} in ${preview.title || "this feed"}`;
    });
  }

  async function addOneOffEpisode(guid: string) {
    if (!oneOffPreview || addingGuid) return;
    setAddingGuid(guid);
    try {
      await run("Adding episode", async () => {
        const episode = await Api.addListenEpisode(oneOffPreview.feed_url, guid);
        emitEpisodesChanged();
        setAddedGuids((current) => new Set(current).add(guid));
        return `Added ${episode.title} to Listen`;
      });
    } finally {
      setAddingGuid(null);
    }
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
    setRefreshing(true);
    await run("Refreshing", async () => {
      try {
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
      } finally {
        setRefreshing(false);
      }
    });
  }

  function setTheme(preference: ThemePreference) {
    setThemePreference(preference);
    applyThemePreference(preference);
  }

  async function enableAdRemoval() {
    if (!adRemoval) return;
    await run("Enabling ad removal", async () => {
      setAdRemoval(await Api.enableAdRemoval(adRemoval.model_total_bytes));
      emitEpisodesChanged();
      return "Ad removal enabled";
    });
  }

  async function saveDeepSeekApiKey() {
    const apiKey = deepSeekApiKey.trim();
    if (!apiKey) return;
    await run("Saving DeepSeek API key", async () => {
      setAdRemoval(await Api.saveDeepSeekApiKey(apiKey));
      setDeepSeekApiKey("");
      return "DeepSeek API key saved in iPhone Keychain";
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

  async function enrollCarBluetooth() {
    await run("Remembering car Bluetooth", async () => {
      setCarBluetooth(await Api.enrollCarBluetooth());
      return "Remembered this Bluetooth as your car";
    });
  }

  async function unenrollCarBluetooth() {
    await run("Forgetting car Bluetooth", async () => {
      setCarBluetooth(await Api.unenrollCarBluetooth());
      return "Forgot remembered car Bluetooth";
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
        <span className="sheet-spacer" />
        <span className="sheet-show">Settings</span>
        <span className="sheet-spacer" />
      </header>

      <div className="settings-body">
        <section className="settings-section settings-appearance" aria-labelledby="appearance-title">
          <h2 className="section-title" id="appearance-title">Appearance</h2>
          <p className="settings-detail">Choose how Pods looks on this iPhone.</p>
          <div className="theme-picker" role="group" aria-label="Appearance">
            {(["system", "light", "dark"] as const).map((preference) => (
              <button
                key={preference}
                className={`theme-choice${themePreference === preference ? " is-selected" : ""}`}
                onClick={() => setTheme(preference)}
                aria-pressed={themePreference === preference}
                aria-label={`${preference[0].toUpperCase()}${preference.slice(1)} appearance`}
              >
                {preference[0].toUpperCase()}{preference.slice(1)}
              </button>
            ))}
          </div>
        </section>
        {carBluetooth && (
          <section className="settings-section" aria-labelledby="car-bluetooth-title">
            <h2 className="section-title" id="car-bluetooth-title">Car Bluetooth</h2>
            <p className="settings-detail">
              Remember the Bluetooth output that should auto-resume playback.
              A Tesla that still uses its factory name works automatically.
              A renamed car needs to be remembered once. Headphones are never remembered.
            </p>
            {carBluetooth.current_device_name && (
              <p className="settings-detail">
                Connected: {carBluetooth.current_device_name}
              </p>
            )}
            {carBluetooth.current_enrolled && (
              <p className="settings-detail" role="status">
                {carBluetooth.current_device_name ?? "This output"} is remembered as your car.
              </p>
            )}
            {carBluetooth.enrolled && !carBluetooth.current_enrolled && (
              <p className="settings-detail" role="status">
                A car is already remembered.
                {carBluetooth.enrollable
                  ? " Remembering this output replaces it."
                  : " Connect to change it."}
              </p>
            )}
            {!carBluetooth.enrolled && !carBluetooth.enrollable && (
              <p className="settings-detail">
                Connect to the car&apos;s Bluetooth, then remember it here.
              </p>
            )}
            {carBluetooth.enrollable && !carBluetooth.current_enrolled && (
              <button className="ghost-btn" onClick={() => void enrollCarBluetooth()}>
                Remember this Bluetooth as my car
              </button>
            )}
            {carBluetooth.enrolled && (
              <button className="ghost-btn" onClick={() => void unenrollCarBluetooth()}>
                Forget remembered car
              </button>
            )}
          </section>
        )}
        {adRemoval && (
          <section className="ad-removal-settings settings-section" aria-labelledby="ad-removal-title">
            <h2 className="section-title" id="ad-removal-title">Ad removal</h2>
            <p className="settings-detail">
              Transcript text is sent to DeepSeek V4 Pro for ad classification and generated show notes.
              Audio stays on this iPhone.
            </p>
            <input
              type="password"
              autoComplete="off"
              aria-label="DeepSeek API key"
              placeholder={adRemoval.cloud_classifier_configured ? "DeepSeek API key saved" : "DeepSeek API key"}
              value={deepSeekApiKey}
              onChange={(event) => setDeepSeekApiKey(event.target.value)}
            />
            <button className="ghost-btn" disabled={!deepSeekApiKey.trim()} onClick={() => void saveDeepSeekApiKey()}>
              Save DeepSeek API key
            </button>
            {adRemoval.enabled ? (
              <>
                <button className="ghost-btn" onClick={() => void disableAdRemoval()}>
                  Disable ad removal
                </button>
                {!adRemoval.cloud_classifier_configured && (
                  <p className="settings-detail" role="status">
                    Ad removal is on, but classification is paused until a DeepSeek API key is saved.
                  </p>
                )}
              </>
            ) : (
              <button
                className="ghost-btn"
                disabled={!adRemoval.cloud_classifier_configured}
                onClick={() => void enableAdRemoval()}
              >
                Enable ad removal
              </button>
            )}
            <p className="settings-detail" role="status">
              Cloud classifier: {adRemoval.cloud_classifier_configured ? "DeepSeek V4 Pro ready" : "API key required"}
            </p>
            <p className="settings-detail settings-revision">
              Revision {adRemoval.model_revision}
            </p>
            <p className="settings-detail">
              Prepared episode storage: {formatGB(adRemoval.episode_storage_bytes)} of{" "}
              {formatGB(adRemoval.episode_storage_limit_bytes)} · {formatGB(adRemoval.device_available_bytes)} free
            </p>
            <div className="deepseek-usage" aria-labelledby="deepseek-usage-title">
              <p className="settings-detail" id="deepseek-usage-title">DeepSeek usage</p>
              <p className="settings-detail">
                Total cost: {formatUSD(adRemoval.deepseek_usage.total_cost_usd)}
              </p>
              <p className="settings-detail">
                Average per episode: {formatOptionalUSD(adRemoval.deepseek_usage.average_cost_per_episode_usd)}
              </p>
              <p className="settings-detail">
                Average per podcast minute:{" "}
                {formatOptionalUSD(adRemoval.deepseek_usage.average_cost_per_podcast_minute_usd)}
              </p>
              <p className="settings-detail">
                Ad detection: {formatUSD(adRemoval.deepseek_usage.ad_detection_cost_usd)}
                {" · "}
                Show notes: {formatUSD(adRemoval.deepseek_usage.show_notes_cost_usd)}
              </p>
              {!adRemoval.deepseek_usage.telemetry_complete && (
                <p className="settings-detail" role="status">
                  Usage totals are incomplete; some billed DeepSeek requests may be missing or unpriced.
                </p>
              )}
            </div>

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

        <section className="settings-section" aria-labelledby="add-feed-title">
          <h2 className="section-title" id="add-feed-title">Add a feed</h2>
          <p className="settings-detail">Paste a podcast RSS feed URL.</p>
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
        </section>

        <section className="settings-section" aria-labelledby="add-episode-title">
          <h2 className="section-title" id="add-episode-title">Add one episode</h2>
          <p className="settings-detail">
            Paste an RSS feed URL, then pick one episode for Listen without subscribing to the show.
          </p>
          <div className="add-url-row">
            <input
              type="url"
              placeholder="https://example.com/feed.xml"
              value={oneOffUrl}
              onChange={(e) => setOneOffUrl(e.target.value)}
              aria-label="One-off feed URL"
            />
            <button onClick={() => void lookupOneOffFeed()} disabled={!oneOffUrl.trim()}>
              Look up
            </button>
          </div>
          {oneOffPreview && (
            <div className="one-off-preview">
              <p className="settings-detail" role="status">
                {oneOffPreview.title || "Untitled feed"}
              </p>
              <input
                type="search"
                placeholder="Filter episodes"
                value={oneOffQuery}
                onChange={(e) => setOneOffQuery(e.target.value)}
                aria-label="Filter episodes"
              />
              <OneOffEpisodeList
                episodes={oneOffPreview.episodes}
                query={oneOffQuery}
                addedGuids={addedGuids}
                addingGuid={addingGuid}
                onAdd={(guid) => void addOneOffEpisode(guid)}
              />
            </div>
          )}
        </section>

        <section className="settings-section" aria-labelledby="subscriptions-title">
          <h2 className="section-title" id="subscriptions-title">Library</h2>
          <p className="settings-detail">Import, export, or refresh your subscriptions.</p>
          <div className="settings-action-list">
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
            <button className={`ghost-btn refresh-action${refreshing ? " is-refreshing" : ""}`} onClick={() => void refreshAll()} disabled={refreshing}>
              {refreshing ? (
                <>
                  <span>Refreshing feeds</span>
                  <span className="refresh-progress" role="progressbar" aria-label="Refreshing feeds" aria-valuetext="Refreshing feeds" />
                </>
              ) : "Refresh all feeds"}
            </button>
          </div>

          {refreshStatus && <p className="muted">{formatRefreshStatus(refreshStatus)}</p>}
        </section>

        {status && <p className="status">{status}</p>}
      </div>
    </div>
  );
}

function OneOffEpisodeList({
  episodes,
  query,
  addedGuids,
  addingGuid,
  onAdd,
}: {
  episodes: FeedPreviewEpisode[];
  query: string;
  addedGuids: Set<string>;
  addingGuid: string | null;
  onAdd: (guid: string) => void;
}) {
  const needle = query.trim().toLowerCase();
  const visible = needle
    ? episodes.filter((episode) => episode.title.toLowerCase().includes(needle))
    : episodes;
  if (episodes.length === 0) {
    return <p className="muted">No episodes in this feed.</p>;
  }
  if (visible.length === 0) {
    return <p className="muted">No matching episodes.</p>;
  }
  return (
    <ul className="one-off-episode-list">
      {visible.map((episode) => {
        const added = addedGuids.has(episode.guid);
        const busy = addingGuid === episode.guid;
        const meta = [fmtDate(episode.published_at), fmtDuration(episode.duration_secs)]
          .filter(Boolean)
          .join(" · ");
        return (
          <li className="one-off-episode-row" key={episode.guid}>
            <span className="row-text">
              <span className="row-title">{episode.title}</span>
              {meta ? <span className="row-sub">{meta}</span> : null}
            </span>
            <button
              className={`subscribe-btn${added ? " done" : ""}`}
              disabled={added || addingGuid != null}
              aria-label={added ? `Added ${episode.title}` : `Add ${episode.title} to Listen`}
              onClick={() => onAdd(episode.guid)}
            >
              {added ? "Added" : busy ? "…" : "Add"}
            </button>
          </li>
        );
      })}
    </ul>
  );
}
