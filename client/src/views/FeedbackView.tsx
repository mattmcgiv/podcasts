import { useEffect, useRef, useState } from "react";
import {
  FEEDBACK_MAX_CHARS,
  feedbackKindLabel,
  feedbackStatusLabel,
  pendingFeedback,
  submitFeedback,
  type FeedbackKind,
} from "../feedback";
import { state } from "../offline/client";
import type { LocalState } from "../offline/store";
import type { FeedbackStatus } from "../types";
import { navigate } from "../router";
import {
  deleteVoiceDraft,
  describeCaptureError,
  flushVoiceDrafts,
  formatVoiceElapsed,
  listVoiceDrafts,
  markVoicePlaced,
  saveVoiceDraft,
  startCapture,
  VOICE_CHANGED,
  VOICE_MAX_MS,
  voicePhaseLabel,
  type CaptureSession,
  type VoiceDraft,
} from "../voice";

function formatFeedbackTime(unixSeconds: number): string {
  if (!unixSeconds) return "";
  return new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(
    new Date(unixSeconds * 1000),
  );
}

function useFeedbackState(): LocalState | null {
  const [local, setLocal] = useState<LocalState | null>(null);
  useEffect(() => {
    let active = true;
    const refresh = () => {
      void state()
        .then((next) => {
          if (active) setLocal(next);
        })
        .catch(() => {
          if (active) setLocal(null);
        });
    };
    refresh();
    window.addEventListener("pods-offline-changed", refresh);
    return () => {
      active = false;
      window.removeEventListener("pods-offline-changed", refresh);
    };
  }, []);
  return local;
}

function MicIcon() {
  return (
    <svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true">
      <path
        fill="currentColor"
        d="M12 14a3 3 0 0 0 3-3V6a3 3 0 0 0-6 0v5a3 3 0 0 0 3 3zm5-3a5 5 0 0 1-10 0H5a7 7 0 0 0 6 6.9V20h2v-2.1A7 7 0 0 0 19 11h-2z"
      />
    </svg>
  );
}

export function FeedbackView() {
  const local = useFeedbackState();
  const [kind, setKind] = useState<FeedbackKind>("feature");
  const [body, setBody] = useState("");
  const [status, setStatus] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const [sending, setSending] = useState(false);
  const [recording, setRecording] = useState(false);
  const [arming, setArming] = useState(false);
  const [elapsed, setElapsed] = useState(0);
  const [drafts, setDrafts] = useState<VoiceDraft[]>([]);
  const sessionRef = useRef<CaptureSession | null>(null);
  const finishing = useRef(false);
  const alive = useRef(true);
  const finishRef = useRef<((hitLimit: boolean) => void) | null>(null);

  const pending = pendingFeedback(local);
  const sent: FeedbackStatus[] = (local?.snapshot?.feedback ?? []).slice().sort((a, b) => b.created_at - a.created_at);
  const remaining = FEEDBACK_MAX_CHARS - body.trim().length;

  useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
      sessionRef.current?.cancel();
      sessionRef.current = null;
    };
  }, []);

  useEffect(() => {
    let active = true;
    const refresh = () => {
      void listVoiceDrafts()
        .then(items => { if (active) setDrafts(items); })
        .catch(() => { if (active) setDrafts([]); });
    };
    refresh();
    window.addEventListener(VOICE_CHANGED, refresh);
    const timer = window.setInterval(() => { void flushVoiceDrafts().catch(() => {}); }, 3000);
    void flushVoiceDrafts().catch(() => {});
    return () => {
      active = false;
      window.clearInterval(timer);
      window.removeEventListener(VOICE_CHANGED, refresh);
    };
  }, []);

  useEffect(() => {
    if (recording || body.trim()) return;
    const ready = drafts.find(item => item.phase === "ready" && item.transcript && !item.placed);
    if (!ready?.transcript) return;
    setBody(ready.transcript);
    void markVoicePlaced(ready.id).catch(() => {});
  }, [drafts, recording, body]);

  useEffect(() => {
    if (!recording) return;
    const timer = window.setInterval(() => {
      const session = sessionRef.current;
      if (!session) return;
      const ms = session.elapsedMs();
      setElapsed(ms);
      if (ms >= VOICE_MAX_MS) finishRef.current?.(true);
    }, 200);
    return () => window.clearInterval(timer);
  }, [recording]);

  async function finish(hitLimit: boolean) {
    if (finishing.current) return;
    const session = sessionRef.current;
    if (!session) return;
    finishing.current = true;
    sessionRef.current = null;
    setRecording(false);
    try {
      const result = await session.stop();
      if (!alive.current) return;
      if (result === "short") {
        setNote("That recording was too short. Say a little more, then stop.");
        return;
      }
      if (result === "empty") {
        setNote("The recording was empty. Try again.");
        return;
      }
      try {
        await saveVoiceDraft(result.blob, result.mime);
        setNote(hitLimit
          ? "Stopped at 2 minutes. Saved on this phone. It transcribes when the Mac is connected."
          : "Saved on this phone. It transcribes when the Mac is connected.");
      } catch {
        setNote("Could not save this recording on this phone. Check browser storage.");
      }
    } finally {
      finishing.current = false;
    }
  }
  finishRef.current = (hitLimit) => { void finish(hitLimit); };

  async function begin() {
    if (recording || arming) return;
    setNote(null);
    setArming(true);
    try {
      const session = await startCapture();
      if (!alive.current) {
        session.cancel();
        return;
      }
      sessionRef.current = session;
      setElapsed(0);
      setRecording(true);
    } catch (error) {
      setNote(error instanceof Error ? error.message : describeCaptureError(error));
    } finally {
      setArming(false);
    }
  }

  function cancelRecording() {
    const session = sessionRef.current;
    sessionRef.current = null;
    finishing.current = false;
    session?.cancel();
    setRecording(false);
    setElapsed(0);
    setNote(null);
  }

  async function useTranscript(draft: VoiceDraft) {
    if (!draft.transcript) return;
    setBody(draft.transcript);
    setNote(null);
    try {
      await markVoicePlaced(draft.id);
    } catch {
      setNote("Could not keep that transcript on this phone.");
    }
  }

  async function send() {
    const text = body;
    setSending(true);
    setStatus(null);
    try {
      await submitFeedback(kind, text);
      const current = await listVoiceDrafts().catch(() => [] as VoiceDraft[]);
      await Promise.all(current
        .filter(item => item.placed || item.transcript?.trim() === text.trim())
        .map(item => deleteVoiceDraft(item.id).catch(() => {})));
      setBody("");
      setNote(null);
      setStatus("Saved. It syncs to the Mac when connected.");
    } catch (error) {
      setStatus(error instanceof Error ? error.message : String(error));
    } finally {
      setSending(false);
    }
  }

  return (
    <div className="feedback-view">
      <header className="sheet-header">
        <button type="button" className="ghost-btn small" onClick={() => navigate("#/settings")}>
          Settings
        </button>
        <span className="sheet-show">Feedback</span>
        <span className="sheet-spacer" />
      </header>

      <section className="settings-section" aria-labelledby="feedback-kind-title">
        <h2 className="section-title" id="feedback-kind-title">New report</h2>
        <div className="theme-picker" role="group" aria-label="Report type">
          {(["feature", "bug"] as const).map((choice) => (
            <button
              key={choice}
              type="button"
              className={`theme-choice${kind === choice ? " is-selected" : ""}`}
              onClick={() => setKind(choice)}
              aria-pressed={kind === choice}
            >
              {feedbackKindLabel(choice)}
            </button>
          ))}
        </div>
        <label className="settings-detail" htmlFor="feedback-body">
          Describe it, or dictate it. The Mac picks it up and dispatches a fix when connected.
        </label>
        <div className="feedback-compose">
          <textarea
            id="feedback-body"
            className="feedback-input"
            rows={5}
            maxLength={FEEDBACK_MAX_CHARS + 100}
            placeholder={kind === "bug" ? "What went wrong?" : "What should Pods do?"}
            value={body}
            disabled={recording || arming}
            onChange={(e) => setBody(e.target.value)}
          />
          {!recording && (
            <button
              type="button"
              className="feedback-mic"
              aria-label={arming ? "Waiting for microphone access" : "Dictate a report"}
              disabled={arming || sending}
              onClick={() => void begin()}
            >
              <MicIcon />
            </button>
          )}
        </div>
        {recording ? (
          <div className="feedback-recording" role="group" aria-label={`Recording ${formatVoiceElapsed(elapsed)}`}>
            <span className="feedback-rec-dot" aria-hidden="true" />
            <span className="feedback-rec-time" aria-hidden="true">{formatVoiceElapsed(elapsed)}</span>
            <button type="button" className="primary-btn feedback-rec-stop" onClick={() => void finish(false)}>
              Stop
            </button>
            <button type="button" className="ghost-btn small" onClick={cancelRecording}>
              Cancel
            </button>
          </div>
        ) : (
          <div className="feedback-actions">
            <span className="settings-detail" aria-live="polite">
              {remaining < 200 ? `${remaining} characters left` : ""}
            </span>
            <button type="button" className="primary-btn" onClick={() => void send()} disabled={sending || !body.trim()}>
              {sending ? "Saving…" : "Send"}
            </button>
          </div>
        )}
        {note && (
          <p className="settings-detail" role="status">
            {note}
          </p>
        )}
        {status && (
          <p className="settings-detail" role="status">
            {status}
          </p>
        )}
      </section>

      {drafts.length > 0 && (
        <section className="settings-section" aria-labelledby="feedback-voice-title">
          <h2 className="section-title" id="feedback-voice-title">Voice notes</h2>
          <ul className="feedback-list">
            {drafts.map(item => (
              <li key={item.id} className="feedback-item">
                <p className="feedback-item-kind">{voicePhaseLabel(item.phase)}</p>
                {item.transcript && <p className="feedback-item-body">{item.transcript}</p>}
                {item.error && <p className="settings-detail">{item.error}</p>}
                <div className="feedback-voice-actions">
                  {item.phase === "ready" && item.transcript && (
                    <button type="button" className="ghost-btn small" onClick={() => void useTranscript(item)}>
                      Use transcript
                    </button>
                  )}
                  <button type="button" className="ghost-btn small" onClick={() => void deleteVoiceDraft(item.id).catch(() => setNote("Could not discard that recording."))}>
                    Discard
                  </button>
                </div>
              </li>
            ))}
          </ul>
        </section>
      )}

      {pending.length > 0 && (
        <section className="settings-section" aria-labelledby="feedback-pending-title">
          <h2 className="section-title" id="feedback-pending-title">Waiting to sync</h2>
          <ul className="feedback-list">
            {pending.map((item) => (
              <li key={item.id} className="feedback-item">
                <p className="feedback-item-kind">
                  {feedbackKindLabel(item.kind)}
                  {item.error ? " — the Mac rejected it" : item.conflict ? " — needs review" : ""}
                </p>
                <p className="feedback-item-body">{item.body}</p>
                {item.error && <p className="settings-detail">{item.error}</p>}
              </li>
            ))}
          </ul>
        </section>
      )}

      {sent.length > 0 && (
        <section className="settings-section" aria-labelledby="feedback-sent-title">
          <h2 className="section-title" id="feedback-sent-title">On the Mac</h2>
          <ul className="feedback-list">
            {sent.map((item) => (
              <li key={item.id} className="feedback-item">
                <p className="feedback-item-kind">
                  {feedbackKindLabel(item.kind)} — {feedbackStatusLabel(item.status)}
                </p>
                <p className="settings-detail">{formatFeedbackTime(item.created_at)}</p>
              </li>
            ))}
          </ul>
        </section>
      )}
    </div>
  );
}
