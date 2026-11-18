import { describe, expect, it } from "vitest";
import raw from "./sync-vectors.json?raw";
import { applyOverlay, coalesceOutbox, nextBatch, originalTime, processedTime, validateSnapshot } from "./client";
import type { Operation, Snapshot } from "./store";

// The same file drives ios/PodsTests/SyncVectorTests.swift and backend/tests/sync_vectors.rs.
type Span = { original_start: number; original_end: number; processed_start: number };
type TimelineCase = { name: string; timeline: Span[]; to_original: [number, number][]; to_processed: [number, number][] };
type OverlayEpisode = { id: number; podcast_id: number; played: boolean; position: number; timeline?: Span[] };
type OverlayCase = {
  name: string; shows: { id: number; feed_url: string }[]; settings: Record<string, unknown>; episodes: OverlayEpisode[];
  outbox: { entity: string; field: string; value: unknown }[];
  expect: { shows: number[]; settings: Record<string, unknown>; episodes: { id: number; played: boolean; position: number }[] };
};
type OutboxCase = { name: string; outbox: { id: string; entity: string; field: string; sent?: boolean; error?: string }[]; expect: string[] };
type ValidateCase = {
  name: string; snapshot_version: number; replace?: boolean; duplicate?: boolean; valid: boolean;
  episode_patch?: Record<string, unknown>; manifest_patch?: Record<string, unknown>;
};
const vectors = JSON.parse(raw) as {
  timeline: TimelineCase[]; overlay: OverlayCase[]; coalesce: OutboxCase[]; next_batch: OutboxCase[];
  validate: { base_episode: Record<string, unknown> & { manifest: Record<string, unknown> }; cases: ValidateCase[] };
};

function operations(list: { entity: string; field: string; value?: unknown; id?: string; sent?: boolean; error?: string }[]): Operation[] {
  return list.map((item, index) => ({ id: item.id ?? `op-${index}`, sequence: index + 1, entity: item.entity, field: item.field,
    value: item.value ?? true, base_revision: 0, changed_at: 1_700_000_000_000 + index, sent: item.sent, error: item.error }));
}

function overlaySnapshot(input: OverlayCase): Snapshot {
  const episodes = input.episodes.map(e => ({ ...vectors.validate.base_episode, id: e.id, podcast_id: e.podcast_id,
    played_at: e.played ? 1_700_000_100 : null, position_secs: e.position,
    manifest: { ...vectors.validate.base_episode.manifest, episode_id: e.id, timeline: e.timeline ?? [] } }));
  return { version: 1, cursor: 0, replace: true, versions: {}, settings: { ...input.settings },
    shows: input.shows.map(s => ({ ...s, title: "Show", description: "", image_url: "", site_url: "", episode_count: 0, unplayed_count: 0 })),
    episodes } as unknown as Snapshot;
}

describe("shared sync vectors", () => {
  for (const input of vectors.timeline) it(`timeline: ${input.name}`, () => {
    for (const [processed, original] of input.to_original) expect(originalTime(input.timeline, processed)).toBeCloseTo(original, 9);
    for (const [original, processed] of input.to_processed) expect(processedTime(input.timeline, original)).toBeCloseTo(processed, 9);
  });

  for (const input of vectors.overlay) it(`overlay: ${input.name}`, () => {
    const result = applyOverlay(overlaySnapshot(input), operations(input.outbox));
    expect(result.shows.map(s => s.id)).toEqual(input.expect.shows);
    expect(result.settings).toEqual(input.expect.settings);
    expect(result.episodes.map(e => ({ id: e.id, played: e.played_at != null, position: e.position_secs }))).toEqual(input.expect.episodes);
  });

  for (const input of vectors.coalesce) it(`coalesce: ${input.name}`, () => {
    expect(coalesceOutbox(operations(input.outbox)).map(o => o.id)).toEqual(input.expect);
  });

  for (const input of vectors.next_batch) it(`next batch: ${input.name}`, () => {
    expect(nextBatch(operations(input.outbox)).map(o => o.id)).toEqual(input.expect);
  });

  // The browser reads the full (version 1) snapshot only; compact cases belong to the iPhone.
  for (const input of vectors.validate.cases.filter(c => c.snapshot_version !== 2)) it(`validate: ${input.name}`, () => {
    const base = vectors.validate.base_episode;
    const episode = { ...base, ...input.episode_patch, manifest: { ...base.manifest, ...input.manifest_patch } };
    const snapshot = { version: input.snapshot_version, cursor: 0, replace: input.replace ?? true, versions: {}, settings: {}, shows: [],
      episodes: input.duplicate ? [episode, episode] : [episode] } as unknown as Snapshot;
    if (input.valid) expect(() => validateSnapshot(snapshot)).not.toThrow();
    else expect(() => validateSnapshot(snapshot)).toThrow();
  });
});
