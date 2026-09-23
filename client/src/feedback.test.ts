import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { IDBFactory, IDBKeyRange } from "fake-indexeddb";
import { webcrypto } from "node:crypto";
import {
  FEEDBACK_ENTITY,
  FEEDBACK_MAX_CHARS,
  feedbackKindLabel,
  feedbackStatusLabel,
  pendingFeedback,
  submitFeedback,
} from "./feedback";
import { state, synchronize } from "./offline/client";
import { emptyState } from "./offline/store";

beforeEach(() => {
  vi.stubGlobal("indexedDB", new IDBFactory());
  vi.stubGlobal("IDBKeyRange", IDBKeyRange);
  vi.stubGlobal("crypto", webcrypto);
  vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new Error("Mac unavailable")));
  window.PODS_LOCAL_CLIENT = true;
});

afterEach(async () => {
  await synchronize().catch(() => {});
  delete window.PODS_LOCAL_CLIENT;
  vi.unstubAllGlobals();
});

describe("feedback labels", () => {
  it("names kinds and dispatch states", () => {
    expect(feedbackKindLabel("feature")).toBe("Feature request");
    expect(feedbackKindLabel("bug")).toBe("Bug report");
    expect(feedbackStatusLabel("queued")).toBe("Received — waiting on the Mac");
    expect(feedbackStatusLabel("running")).toBe("The Mac is working on it");
    expect(feedbackStatusLabel("done")).toBe("Fixed on the Mac");
    expect(feedbackStatusLabel("failed")).toBe("The Mac could not dispatch it");
    expect(feedbackStatusLabel("stale")).toBe("stale");
  });
});

describe("submitFeedback", () => {
  it("rejects an unknown kind, an empty body, and an overlong body", async () => {
    await expect(submitFeedback("rant" as never, "nope")).rejects.toThrow("Choose a feature request");
    await expect(submitFeedback("bug", "   ")).rejects.toThrow("Describe the request");
    await expect(submitFeedback("feature", "x".repeat(FEEDBACK_MAX_CHARS + 1))).rejects.toThrow("under 4000");
    expect((await state()).outbox).toEqual([]);
  });

  it("queues a trimmed report in the offline outbox for Mac sync", async () => {
    const id = await submitFeedback("bug", "  crash on launch  ");
    const outbox = (await state()).outbox;
    expect(outbox).toHaveLength(1);
    expect(outbox[0].entity).toBe(FEEDBACK_ENTITY);
    expect(outbox[0].field).toBe(id);
    expect(outbox[0].value).toMatchObject({ kind: "bug", body: "crash on launch" });
    expect(typeof (outbox[0].value as { created_at: unknown }).created_at).toBe("number");
  });
});

describe("pendingFeedback", () => {
  it("returns nothing without local state", () => {
    expect(pendingFeedback(null)).toEqual([]);
  });

  it("lists only well-formed feedback ops, newest first", async () => {
    const local = emptyState();
    local.outbox = [
      { id: "1", sequence: 1, entity: "1", field: "played", value: true, base_revision: 0 },
      { id: "2", sequence: 2, entity: FEEDBACK_ENTITY, field: "old", value: { kind: "feature", body: "Old", created_at: 10 }, base_revision: 0 },
      { id: "3", sequence: 3, entity: FEEDBACK_ENTITY, field: "bad-kind", value: { kind: "rant", body: "x" }, base_revision: 0 },
      { id: "4", sequence: 4, entity: FEEDBACK_ENTITY, field: "bad-body", value: { kind: "bug", body: 7 }, base_revision: 0 },
      { id: "5", sequence: 5, entity: FEEDBACK_ENTITY, field: "null-value", value: null, base_revision: 0 },
      { id: "6", sequence: 6, entity: FEEDBACK_ENTITY, field: "new", value: { kind: "bug", body: "New", created_at: 20 }, base_revision: 0, error: "rejected" },
    ];
    expect(pendingFeedback(local)).toEqual([
      { id: "new", kind: "bug", body: "New", createdAt: 20, conflict: false, error: "rejected" },
      { id: "old", kind: "feature", body: "Old", createdAt: 10, conflict: false, error: undefined },
    ]);
  });

  it("treats a missing timestamp as oldest and surfaces conflicts", () => {
    const local = emptyState();
    local.outbox = [
      { id: "1", sequence: 1, entity: FEEDBACK_ENTITY, field: "a", value: { kind: "bug", body: "A" }, base_revision: 0, conflict: 4 },
    ];
    expect(pendingFeedback(local)).toEqual([
      { id: "a", kind: "bug", body: "A", createdAt: 0, conflict: true, error: undefined },
    ]);
  });
});
