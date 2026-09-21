import { useEffect, useState } from "react";
import { Api } from "../api";
import { usePlayer } from "../player";
import { fmtTime } from "../lib";
import type { EpisodeDetail } from "../types";
import { applyOverlay, offlineEnabled, state, syncError } from "./client";
import type { LocalState } from "./store";

export function useLocalState(): LocalState | null {
  const [local, setLocal] = useState<LocalState | null>(null);
  useEffect(() => {
    if (!offlineEnabled()) return;
    let active = true;
    const refresh = () => { void state().then(s => { if (active) setLocal(s); }).catch(() => {}); };
    refresh();
    window.addEventListener("pods-offline-changed", refresh);
    return () => { active = false; window.removeEventListener("pods-offline-changed", refresh); };
  }, []);
  return local;
}

export function SyncStatus() {
  const local = useLocalState();
  if (!local) return null;
  const conflicts = local.outbox.some(o => o.conflict != null || o.error);
  const status = conflicts ? "Sync needs attention in Settings" : syncError() ? "Mac unavailable" : local.outbox.length ? "Changes waiting to sync" : local.lastSync ? "Synced" : "Not synchronized yet";
  return <div className="sync-status" role="status" title={local.lastSync ? `Last sync: ${new Date(local.lastSync).toLocaleString()}` : undefined}>{status}</div>;
}

export function ContinueListening() {
  const local = useLocalState();
  const player = usePlayer();
  const [episode, setEpisode] = useState<EpisodeDetail | null>(null);
  const last = local?.snapshot ? Number(applyOverlay(local.snapshot, local.outbox).settings.last_listened) : 0;
  useEffect(() => {
    let active = true;
    if (last > 0) void Api.episode(last).then(e => { if (active) setEpisode(e); }).catch(() => { if (active) setEpisode(null); });
    else setEpisode(null);
    return () => { active = false; };
  }, [last, local]);
  if (!episode || episode.played_at != null || player.current?.id === episode.id) return null;
  return <div className="continue-listening">
    <strong>Continue listening</strong>
    <p>{episode.title} · {fmtTime(episode.position_secs)}</p>
    {episode.downloaded
      ? <button type="button" onClick={() => player.playEpisode(episode, "recent")}>Resume</button>
      : <p>Keep Pods open to download this episode on this device.</p>}
  </div>;
}
