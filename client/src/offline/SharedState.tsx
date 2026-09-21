import { useEffect, useState } from "react";
import { Api } from "../api";
import { usePlayer } from "../player";
import { fmtTime } from "../lib";
import type { EpisodeDetail } from "../types";
import { applyOverlay, offlineEnabled, state, syncError } from "./client";
import { signInAndSync } from "./signIn";
import type { LocalState } from "./store";

const NOTICE_KEY = "pods-sync-notice";

type SyncNotice = { key: string; tone: "auth" | "offline" | "pending"; text: string };

function syncNotice(local: LocalState): SyncNotice | null {
  const error = syncError();
  if (error && /Sign in/.test(error)) {
    return { key: "auth", tone: "auth", text: "Sign in to update episodes from the Mac." };
  }
  if (error) return { key: `offline:${error}`, tone: "offline", text: "Offline. Downloaded episodes still play." };
  if (local.outbox.some(operation => operation.conflict != null || operation.error)) {
    return { key: "attention", tone: "pending", text: "Sync needs a choice in Settings." };
  }
  if (local.outbox.length) return { key: `pending:${local.outbox.length}`, tone: "pending", text: "Changes waiting to sync." };
  if (!local.lastSync) return { key: "never", tone: "pending", text: "Not synchronized yet." };
  return null;
}

function readDismissedNotice(): string | null {
  try { return sessionStorage.getItem(NOTICE_KEY); } catch { return null; }
}

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
  const [dismissed, setDismissed] = useState<string | null>(readDismissedNotice);
  const [signingIn, setSigningIn] = useState(false);
  const [signInError, setSignInError] = useState<string | null>(null);
  const notice = local ? syncNotice(local) : null;
  const noticeKey = notice?.key ?? "";
  useEffect(() => {
    if (!local || noticeKey) return;
    setDismissed(null);
    try { sessionStorage.removeItem(NOTICE_KEY); } catch { /* Private mode can reject storage. */ }
  }, [local, noticeKey]);
  if (!local || !notice || dismissed === notice.key) return null;

  function dismiss() {
    setDismissed(notice!.key);
    try { sessionStorage.setItem(NOTICE_KEY, notice!.key); } catch { /* The notice still hides for this view. */ }
  }

  async function signIn() {
    setSigningIn(true);
    setSignInError(null);
    try {
      await signInAndSync();
    } catch (error) {
      setSignInError(error instanceof Error ? error.message : "Passkey sign-in failed");
    } finally {
      setSigningIn(false);
    }
  }

  return <div className={`sync-badge sync-badge-${notice.tone}`}>
    <div className="sync-badge-copy">
      <p role="status">{notice.text}</p>
      {notice.tone === "auth" && (
        <button type="button" className={`settings-btn primary${signingIn ? " is-busy" : ""}`} disabled={signingIn} aria-busy={signingIn} onClick={() => void signIn()}>
          {signingIn ? "Signing in…" : "Continue with passkey"}
        </button>
      )}
      {signInError && <p className="auth-error" role="alert">{signInError}</p>}
    </div>
    <button type="button" className="sync-badge-dismiss" onClick={dismiss}>Dismiss</button>
  </div>;
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
