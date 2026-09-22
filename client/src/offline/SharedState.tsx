import { useEffect, useState } from "react";
import { Api } from "../api";
import { usePlayer } from "../player";
import { fmtTime } from "../lib";
import type { EpisodeDetail } from "../types";
import { applyOverlay, offlineEnabled, resolveConflict, state, syncError, synchronize } from "./client";
import { prefetch } from "./downloads";
import { signInAndSync } from "./signIn";
import type { LocalState, Operation } from "./store";

const NOTICE_KEY = "pods-sync-notice";

type SyncNotice =
  | { kind: "sign-in"; key: "auth"; text: string }
  | { kind: "offline"; key: string; text: string }
  | { kind: "conflict"; key: string; text: string; operationId: string }
  | { kind: "rejected"; key: string; text: string; operationId: string }
  | { kind: "pending"; key: string; text: string }
  | { kind: "unsynced"; key: "never"; text: string };

function changedThing(local: LocalState, operation: Operation): string {
  if (operation.entity === "subscription") {
    return local.snapshot?.shows.find(show => show.feed_url === operation.field)?.title ?? "a subscription";
  }
  if (operation.entity === "settings") return "a setting";
  return local.snapshot?.episodes.find(episode => String(episode.id) === operation.entity)?.title ?? "an item";
}

/** The blocking sync state, and nothing when the library is already in the good state. */
export function syncNotice(local: LocalState): SyncNotice | null {
  const error = syncError();
  if (error && /Sign in/.test(error)) {
    return { kind: "sign-in", key: "auth", text: "Sign in to update episodes from the Mac." };
  }
  if (error) {
    return { kind: "offline", key: `offline:${error}`, text: "The Mac is not reachable. Downloaded episodes still play." };
  }
  const conflicts = local.outbox.filter(operation => operation.conflict != null);
  if (conflicts.length > 0) {
    const operation = conflicts[0];
    const more = conflicts.length > 1 ? ` ${conflicts.length - 1} more need the same choice after this.` : "";
    return {
      kind: "conflict",
      key: `conflict:${operation.id}`,
      operationId: operation.id,
      text: `This device and the shared library both changed ${changedThing(local, operation)}.${more}`,
    };
  }
  const rejected = local.outbox.filter(operation => operation.error);
  if (rejected.length > 0) {
    const operation = rejected[0];
    return {
      kind: "rejected",
      key: `rejected:${operation.id}`,
      operationId: operation.id,
      text: `The Mac did not accept a change to ${changedThing(local, operation)}. ${operation.error}`,
    };
  }
  if (local.outbox.length) {
    return { kind: "pending", key: `pending:${local.outbox.length}`, text: "Changes on this device are waiting to sync." };
  }
  if (!local.lastSync) return { kind: "unsynced", key: "never", text: "This device has not synchronized with the Mac." };
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
  const [busy, setBusy] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
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

  async function run(label: string, work: () => Promise<void>) {
    setBusy(label);
    setActionError(null);
    try {
      await work();
    } catch (error) {
      setActionError(error instanceof Error ? error.message : "That did not work.");
    } finally {
      setBusy(null);
    }
  }

  async function syncNow() {
    await synchronize();
    await prefetch();
  }

  async function choose(operationId: string, keepDevice: boolean) {
    await resolveConflict(operationId, keepDevice);
    try { await prefetch(); } catch { /* A later sync retries the download. */ }
  }

  const working = busy != null;

  return <div className={`sync-badge sync-badge-${notice.kind}`}>
    <div className="sync-badge-copy">
      <p role="status">{notice.text}</p>
      {notice.kind === "sign-in" && (
        <button type="button" className={`settings-btn primary${busy === "sign-in" ? " is-busy" : ""}`} disabled={working} aria-busy={busy === "sign-in"} onClick={() => void run("sign-in", signInAndSync)}>
          {busy === "sign-in" ? "Signing in…" : "Continue with passkey"}
        </button>
      )}
      {(notice.kind === "offline" || notice.kind === "pending" || notice.kind === "unsynced") && (
        <button type="button" className={`settings-btn primary${busy === "sync" ? " is-busy" : ""}`} disabled={working} aria-busy={busy === "sync"} onClick={() => void run("sync", syncNow)}>
          {busy === "sync" ? "Syncing…" : notice.kind === "offline" ? "Try again" : "Sync now"}
        </button>
      )}
      {notice.kind === "conflict" && (
        <>
          <button type="button" className={`settings-btn primary${busy === "keep" ? " is-busy" : ""}`} disabled={working} aria-busy={busy === "keep"} onClick={() => void run("keep", () => choose(notice.operationId, true))}>
            {busy === "keep" ? "Keeping this device’s change…" : "Keep this device’s change"}
          </button>
          <button type="button" className={`settings-btn${busy === "shared" ? " is-busy" : ""}`} disabled={working} aria-busy={busy === "shared"} onClick={() => void run("shared", () => choose(notice.operationId, false))}>
            {busy === "shared" ? "Using the shared change…" : "Use the shared change"}
          </button>
        </>
      )}
      {notice.kind === "rejected" && (
        <>
          <button type="button" className={`settings-btn primary${busy === "retry" ? " is-busy" : ""}`} disabled={working} aria-busy={busy === "retry"} onClick={() => void run("retry", () => choose(notice.operationId, true))}>
            {busy === "retry" ? "Trying again…" : "Try again"}
          </button>
          <button type="button" className={`settings-btn${busy === "discard" ? " is-busy" : ""}`} disabled={working} aria-busy={busy === "discard"} onClick={() => void run("discard", () => choose(notice.operationId, false))}>
            {busy === "discard" ? "Discarding…" : "Discard this change"}
          </button>
        </>
      )}
      {actionError && <p className="auth-error" role="alert">{actionError}</p>}
    </div>
    <button type="button" className="sync-badge-dismiss" onClick={dismiss} disabled={working}>Dismiss</button>
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
