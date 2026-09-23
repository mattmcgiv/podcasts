import { enqueue, synchronize } from "./offline/client";
import type { LocalState, Operation } from "./offline/store";
import type { FeedbackKind } from "./types";

export type { FeedbackKind } from "./types";

/** Sync entity for user-typed reports. Each report id is its own field. */
export const FEEDBACK_ENTITY = "feedback";
export const FEEDBACK_MAX_CHARS = 4000;

export function feedbackKindLabel(kind: FeedbackKind): string {
  return kind === "bug" ? "Bug report" : "Feature request";
}

export function feedbackStatusLabel(status: string): string {
  switch (status) {
    case "queued":
      return "Received — waiting on the Mac";
    case "running":
      return "The Mac is working on it";
    case "done":
      return "Fixed on the Mac";
    case "failed":
      return "The Mac could not dispatch it";
    default:
      return status;
  }
}

export interface PendingFeedback {
  id: string;
  kind: FeedbackKind;
  body: string;
  createdAt: number;
  conflict: boolean;
  error?: string;
}

function parsePending(operation: Operation): PendingFeedback | null {
  if (operation.entity !== FEEDBACK_ENTITY) return null;
  const value = operation.value as { kind?: unknown; body?: unknown; created_at?: unknown } | null;
  if (typeof value !== "object" || value == null) return null;
  if (value.kind !== "feature" && value.kind !== "bug") return null;
  if (typeof value.body !== "string") return null;
  return {
    id: operation.field,
    kind: value.kind,
    body: value.body,
    createdAt: typeof value.created_at === "number" && Number.isFinite(value.created_at) ? value.created_at : 0,
    conflict: operation.conflict != null,
    error: operation.error,
  };
}

/** Reports typed on this device that the Mac has not acknowledged yet. */
export function pendingFeedback(local: LocalState | null): PendingFeedback[] {
  if (!local) return [];
  const items: PendingFeedback[] = [];
  for (const operation of local.outbox) {
    const parsed = parsePending(operation);
    if (parsed) items.push(parsed);
  }
  return items.sort((a, b) => b.createdAt - a.createdAt);
}

/** Queue a report in the offline outbox and sync it to the Mac when connected. */
export async function submitFeedback(kind: FeedbackKind, body: string): Promise<string> {
  const text = body.trim();
  if (kind !== "feature" && kind !== "bug") throw new Error("Choose a feature request or a bug report.");
  if (!text) throw new Error("Describe the request before sending.");
  if (text.length > FEEDBACK_MAX_CHARS) throw new Error(`Keep it under ${FEEDBACK_MAX_CHARS} characters.`);
  const id = crypto.randomUUID();
  await enqueue(FEEDBACK_ENTITY, id, { kind, body: text, created_at: Math.floor(Date.now() / 1000) });
  void synchronize().catch(() => {});
  return id;
}
