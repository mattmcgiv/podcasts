import { useEffect, useState } from "react";
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

export function FeedbackView() {
  const local = useFeedbackState();
  const [kind, setKind] = useState<FeedbackKind>("feature");
  const [body, setBody] = useState("");
  const [status, setStatus] = useState<string | null>(null);
  const [sending, setSending] = useState(false);

  const pending = pendingFeedback(local);
  const sent: FeedbackStatus[] = (local?.snapshot?.feedback ?? []).slice().sort((a, b) => b.created_at - a.created_at);
  const remaining = FEEDBACK_MAX_CHARS - body.trim().length;

  async function send() {
    setSending(true);
    setStatus(null);
    try {
      await submitFeedback(kind, body);
      setBody("");
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
          Describe it. The Mac picks it up and dispatches a fix when connected.
        </label>
        <textarea
          id="feedback-body"
          className="feedback-input"
          rows={5}
          maxLength={FEEDBACK_MAX_CHARS + 100}
          placeholder={kind === "bug" ? "What went wrong?" : "What should Pods do?"}
          value={body}
          onChange={(e) => setBody(e.target.value)}
        />
        <div className="feedback-actions">
          <span className="settings-detail" aria-live="polite">
            {remaining < 200 ? `${remaining} characters left` : ""}
          </span>
          <button type="button" className="primary-btn" onClick={() => void send()} disabled={sending || !body.trim()}>
            {sending ? "Saving…" : "Send"}
          </button>
        </div>
        {status && (
          <p className="settings-detail" role="status">
            {status}
          </p>
        )}
      </section>

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
