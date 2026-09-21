import { act, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { Api } from "./api";
import { POSITION_SYNC_INTERVAL_MS } from "./config";
import { PlayerProvider, usePlayer } from "./player";
import {
  adRemovalStatusItem,
  adRemovalStatuses,
  episode,
  HttpError,
  installApi,
  type MockRoutes,
} from "./test/mockApi";
import { FakeAudio } from "./test/fakeAudio";
import type { ArtifactManifest, Snapshot } from "./offline/store";
import { allDownloads, readRecord, updateState, writeRecord } from "./offline/store";
import * as store from "./offline/store";
import { IDBFactory, IDBKeyRange } from "fake-indexeddb";
import type { EpisodeItem } from "./types";

afterEach(() => {
  vi.useRealTimers();
  delete window.webkit;
  delete window.PODS_API_BASE;
  delete window.PODS_LOCAL_CLIENT;
  delete window.PodsAudioBridge;
  Object.defineProperty(document, "visibilityState", { configurable: true, value: "visible" });
});

function Probe() {
  const p = usePlayer();
  return (
    <div>
      <button onClick={() => p.playEpisode(episode({ id: 1, position_secs: 30 }), "recent")}>
        play1
      </button>
      <button
        onClick={() =>
          p.playEpisode(
            episode({
              id: 4,
              title: "Art Episode",
              podcast_title: "Art Show",
              audio_url: "https://h.example/art.mp3",
              image_url: "/api/artwork/episodes/4",
              duration_secs: 1234,
            }),
            "recent",
          )
        }
      >
        play-art
      </button>
      <button onClick={() => p.playEpisode(episode({ id: 9, position_secs: 0 }), "show")}>
        play9
      </button>
      <button onClick={p.toggle}>toggle</button>
      <button onClick={() => p.setSpeed(3)}>speed3</button>
      <button onClick={() => p.setSpeed(2.5, "speed-test")}>speed-corr</button>
      <button onClick={() => p.setAutoplay(false)}>autoplay-off</button>
      <button onClick={() => void p.markPlayedAndClose()}>done</button>
      <button onClick={p.skipForward}>fwd</button>
      <button onClick={p.skipBack}>back</button>
      <button onClick={() => p.setExpanded(false)}>collapse</button>
      <button onClick={p.retryShowNotes}>retry-notes</button>
      <button onClick={() => p.setCastOutput("local")}>cast-local</button>
      <button onClick={p.undoAdSkip}>undo-skip</button>
      <span data-testid="state">
        {p.current
          ? `${p.current.id}:${p.playing ? "playing" : "paused"}:${p.speed}:${p.autoplay ? "auto" : "manual"}`
          : "none"}
      </span>
      <span data-testid="expanded">{p.expanded ? "open" : "closed"}</span>
      <span data-testid="dur">{p.duration}</span>
      <span data-testid="pos">{Math.floor(p.position)}</span>
      <span data-testid="show-notes">
        {p.current?.show_notes?.map((note) => note.title).join("|") ?? "none"}
      </span>
      <span data-testid="show-notes-status">
        {p.showNotesGenerating ? "generating" : p.showNotesError ?? "idle"}
      </span>
    </div>
  );
}

function baseRoutes(extra: MockRoutes = {}): MockRoutes {
  return {
    "GET /api/settings": { speed: 2, autoplay: true },
    "PUT /api/settings": null,
    "GET /api/episodes/1": { ...episode({ id: 1, position_secs: 30 }), notes_html: "<p>n</p>", archived_at: null },
    "GET /api/episodes/4": {
      ...episode({
        id: 4,
        title: "Art Episode",
        podcast_title: "Art Show",
        audio_url: "https://h.example/art.mp3",
        image_url: "/api/artwork/episodes/4",
        duration_secs: 1234,
      }),
      notes_html: "",
      archived_at: null,
    },
    "GET /api/episodes/9": { ...episode({ id: 9 }), notes_html: "", archived_at: null },
    "PUT /api/episodes/1/position": null,
    "PUT /api/episodes/4/position": null,
    "PUT /api/episodes/9/position": null,
    "POST /api/episodes/1/played": null,
    "POST /api/episodes/9/played": null,
    ...extra,
  };
}

async function setup(extra: MockRoutes = {}) {
  const mocked = installApi(baseRoutes(extra));
  const user = userEvent.setup();
  render(
    <PlayerProvider>
      <Probe />
    </PlayerProvider>,
  );
  // settings load
  await waitFor(() => expect(screen.getByTestId("state")).toHaveTextContent("none"));
  return { ...mocked, user };
}

describe("PlayerProvider", () => {
  it("plays an episode, resumes position, applies persisted speed", async () => {
    const { user } = await setup();
    await user.click(screen.getByText("play1"));

    const audio = FakeAudio.last();
    expect(audio.src).toBe("https://h.example/ep.mp3");
    await waitFor(() =>
      expect(screen.getByTestId("state")).toHaveTextContent("1:playing:2:auto"),
    );

    act(() => audio.emitLoadedMetadata(1800));
    expect(audio.currentTime).toBe(30); // resumed
    expect(audio.playbackRate).toBe(2); // persisted setting
    expect(screen.getByTestId("dur")).toHaveTextContent("1800");
  });

  it("generates show notes once a ready episode detail is opened", async () => {
    const { calls, user } = await setup({
      "GET /api/episodes/1": {
        ...episode({ id: 1, position_secs: 30, ad_removal_state: "ad-free", ad_removal_stage: "ready" }),
        notes_html: "",
        show_notes: [],
        archived_at: null,
      },
      "POST /api/episodes/1/show-notes": [
        {
          id: "segment-topic",
          start_time: 125.25,
          title: "A new direction",
          summary: "The discussion moves to the next major topic.",
        },
      ],
    });

    await user.click(screen.getByText("play1"));

    await waitFor(() =>
      expect(screen.getByTestId("show-notes")).toHaveTextContent("A new direction"),
    );
    expect(calls.filter((call) => call.key === "POST /api/episodes/1/show-notes")).toHaveLength(1);
    expect(screen.getByTestId("show-notes-status")).toHaveTextContent("idle");
  });

  it("keeps one show-notes request per episode across an A-B-A switch", async () => {
    let resolveA!: (value: unknown) => void;
    let resolveB!: (value: unknown) => void;
    const pendingA = new Promise<unknown>((resolve) => { resolveA = resolve; });
    const pendingB = new Promise<unknown>((resolve) => { resolveB = resolve; });
    const readyDetail = (id: number) => ({
      ...episode({ id, ad_removal_state: "ad-free", ad_removal_stage: "ready" }),
      notes_html: "",
      show_notes: [],
      archived_at: null,
    });
    const { calls, user } = await setup({
      "GET /api/episodes/1": readyDetail(1),
      "GET /api/episodes/4": readyDetail(4),
      "POST /api/episodes/1/show-notes": () => pendingA,
      "POST /api/episodes/4/show-notes": () => pendingB,
    });

    await user.click(screen.getByText("play1"));
    await waitFor(() =>
      expect(calls.filter((call) => call.key === "POST /api/episodes/1/show-notes")).toHaveLength(1),
    );
    await user.click(screen.getByText("play-art"));
    await waitFor(() =>
      expect(calls.filter((call) => call.key === "POST /api/episodes/4/show-notes")).toHaveLength(1),
    );
    await user.click(screen.getByText("play1"));
    await waitFor(() => expect(screen.getByTestId("show-notes-status")).toHaveTextContent("generating"));
    expect(calls.filter((call) => call.key === "POST /api/episodes/1/show-notes")).toHaveLength(1);

    resolveA([{ id: "segment-a", start_time: 10, title: "Episode A", summary: "A." }]);
    resolveB([{ id: "segment-b", start_time: 20, title: "Episode B", summary: "B." }]);
    await waitFor(() => expect(screen.getByTestId("show-notes")).toHaveTextContent("Episode A"));
    expect(screen.getByTestId("show-notes-status")).toHaveTextContent("idle");
  });

  it("does not let a prior-visit A POST overwrite newer A detail after A-B-A", async () => {
    let resolveOldA!: (value: unknown) => void;
    const oldARequest = new Promise<unknown>((resolve) => { resolveOldA = resolve; });
    let episodeACalls = 0;
    const freshA = {
      ...episode({ id: 1, ad_removal_state: "ad-free", ad_removal_stage: "ready" }),
      notes_html: "",
      show_notes: [{
        id: "fresh-a",
        start_time: 20,
        title: "Fresh persisted A",
        summary: "The detail from the current visit wins.",
      }],
      archived_at: null,
    };
    const detailWithNotes = (id: number, title: string) => ({
      ...episode({ id, ad_removal_state: "ad-free", ad_removal_stage: "ready" }),
      notes_html: "",
      show_notes: [{ id: `note-${id}`, start_time: 10, title, summary: title }],
      archived_at: null,
    });
    const { calls, user } = await setup({
      "GET /api/episodes/1": () => {
        episodeACalls += 1;
        return episodeACalls === 1
          ? { ...freshA, show_notes: [] }
          : freshA;
      },
      "GET /api/episodes/4": detailWithNotes(4, "Episode B"),
      "POST /api/episodes/1/show-notes": () => oldARequest,
    });

    await user.click(screen.getByText("play1"));
    await waitFor(() =>
      expect(calls.filter((call) => call.key === "POST /api/episodes/1/show-notes")).toHaveLength(1),
    );
    await user.click(screen.getByText("play-art"));
    await user.click(screen.getByText("play1"));
    await waitFor(() =>
      expect(screen.getByTestId("show-notes")).toHaveTextContent("Fresh persisted A"),
    );

    resolveOldA([{
      id: "old-a",
      start_time: 1,
      title: "Old generated A",
      summary: "This belongs to the prior visit.",
    }]);
    await act(async () => {
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(screen.getByTestId("show-notes")).toHaveTextContent("Fresh persisted A");
    expect(screen.getByTestId("show-notes")).not.toHaveTextContent("Old generated A");
    expect(screen.getByTestId("show-notes-status")).toHaveTextContent("idle");
  });

  it("does not let a prior-visit A POST error alter newer A detail after A-B-A", async () => {
    let rejectOldA!: (reason?: unknown) => void;
    const oldARequest = new Promise<unknown>((_resolve, reject) => { rejectOldA = reject; });
    let episodeACalls = 0;
    const freshA = {
      ...episode({ id: 1, ad_removal_state: "ad-free", ad_removal_stage: "ready" }),
      notes_html: "",
      show_notes: [{
        id: "fresh-a",
        start_time: 20,
        title: "Fresh persisted A",
        summary: "The detail from the current visit wins.",
      }],
      archived_at: null,
    };
    const { calls, user } = await setup({
      "GET /api/episodes/1": () => {
        episodeACalls += 1;
        return episodeACalls === 1 ? { ...freshA, show_notes: [] } : freshA;
      },
      "GET /api/episodes/4": {
        ...episode({ id: 4 }),
        notes_html: "",
        show_notes: [{ id: "b", start_time: 5, title: "B", summary: "B" }],
        archived_at: null,
      },
      "POST /api/episodes/1/show-notes": () => oldARequest,
    });

    await user.click(screen.getByText("play1"));
    await waitFor(() =>
      expect(calls.filter((call) => call.key === "POST /api/episodes/1/show-notes")).toHaveLength(1),
    );
    await user.click(screen.getByText("play-art"));
    await user.click(screen.getByText("play1"));
    await waitFor(() =>
      expect(screen.getByTestId("show-notes")).toHaveTextContent("Fresh persisted A"),
    );

    rejectOldA(new Error("prior visit failed"));
    await act(async () => {
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(screen.getByTestId("show-notes")).toHaveTextContent("Fresh persisted A");
    expect(screen.getByTestId("show-notes-status")).toHaveTextContent("idle");
  });

  it("keeps newer POST notes when an older empty detail resolves later", async () => {
    let resolveDetail!: (value: unknown) => void;
    let resolveNotes!: (value: unknown) => void;
    const pendingDetail = new Promise<unknown>((resolve) => { resolveDetail = resolve; });
    const pendingNotes = new Promise<unknown>((resolve) => { resolveNotes = resolve; });
    const { calls, user } = await setup({
      "GET /api/episodes/1": () => pendingDetail,
      "POST /api/episodes/1/show-notes": () => pendingNotes,
    });

    await user.click(screen.getByText("play1"));
    await waitFor(() =>
      expect(calls.filter((call) => call.key === "GET /api/episodes/1")).toHaveLength(1),
    );
    await user.click(screen.getByText("retry-notes"));
    await waitFor(() =>
      expect(calls.filter((call) => call.key === "POST /api/episodes/1/show-notes")).toHaveLength(1),
    );

    resolveNotes([{
      id: "new-notes",
      start_time: 30,
      title: "New POST notes",
      summary: "These notes resolved before the older detail.",
    }]);
    await waitFor(() =>
      expect(screen.getByTestId("show-notes")).toHaveTextContent("New POST notes"),
    );

    resolveDetail({
      ...episode({ id: 1, ad_removal_state: "ad-free", ad_removal_stage: "ready" }),
      notes_html: "",
      show_notes: [],
      archived_at: null,
    });
    await act(async () => {
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(screen.getByTestId("show-notes")).toHaveTextContent("New POST notes");
    expect(calls.filter((call) => call.key === "POST /api/episodes/1/show-notes")).toHaveLength(1);
    expect(screen.getByTestId("show-notes-status")).toHaveTextContent("idle");
  });

  it("polls an active episode and generates show notes when processing becomes ready", async () => {
    vi.useFakeTimers();
    const { calls } = installApi(baseRoutes({
      "GET /api/episodes/1": {
        ...episode({ id: 1, ad_removal_state: "preparing", ad_removal_stage: "classifying" }),
        notes_html: "",
        show_notes: [],
        archived_at: null,
      },
      "GET /api/ad-removal/statuses": adRemovalStatuses([adRemovalStatusItem({
        id: 1,
        ad_removal_state: "ad-free",
        ad_removal_action: null,
        ad_removal_stage: "ready",
      })]),
      "POST /api/episodes/1/show-notes": [{
        id: "segment-ready",
        start_time: 42,
        title: "Ready chapter",
        summary: "Processing completed while the player stayed open.",
      }],
    }));
    render(
      <PlayerProvider>
        <Probe />
      </PlayerProvider>,
    );

    await act(async () => {
      screen.getByText("play1").click();
      await Promise.resolve();
      await Promise.resolve();
    });
    await act(async () => {
      await vi.advanceTimersByTimeAsync(2_100);
    });

    expect(screen.getByTestId("show-notes")).toHaveTextContent("Ready chapter");
    expect(calls.filter((call) => call.key === "GET /api/ad-removal/statuses")).toHaveLength(1);
    expect(calls.filter((call) => call.key === "POST /api/episodes/1/show-notes")).toHaveLength(1);
  });

  it("rejects an old detail response after an A-B-A switch", async () => {
    let resolveOldA!: (value: unknown) => void;
    const oldA = new Promise<unknown>((resolve) => { resolveOldA = resolve; });
    let episodeACalls = 0;
    const freshA = {
      ...episode({ id: 1, ad_removal_state: "ad-free", ad_removal_stage: "ready" }),
      notes_html: "",
      show_notes: [{
        id: "fresh",
        start_time: 20,
        title: "Fresh A detail",
        summary: "The newest request wins.",
      }],
      archived_at: null,
    };
    const { calls, user } = await setup({
      "GET /api/episodes/1": () => {
        episodeACalls += 1;
        return episodeACalls === 1 ? oldA : freshA;
      },
    });

    await user.click(screen.getByText("play1"));
    await waitFor(() =>
      expect(calls.filter((call) => call.key === "GET /api/episodes/1")).toHaveLength(1),
    );
    await user.click(screen.getByText("play-art"));
    await user.click(screen.getByText("play1"));
    await waitFor(() => expect(screen.getByTestId("show-notes")).toHaveTextContent("Fresh A detail"));

    resolveOldA({
      ...freshA,
      show_notes: [{
        id: "stale",
        start_time: 1,
        title: "Stale A detail",
        summary: "This response arrived from the first request.",
      }],
    });
    await act(async () => {
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(screen.getByTestId("show-notes")).toHaveTextContent("Fresh A detail");
    expect(screen.getByTestId("show-notes")).not.toHaveTextContent("Stale A detail");
  });

  it("sends now-playing metadata to the native audio bridge", async () => {
    const messages: unknown[] = [];
    window.PODS_API_BASE = "http://127.0.0.1:18180";
    window.webkit = {
      messageHandlers: {
        podsAudio: {
          postMessage(message) {
            messages.push(message);
          },
        },
      },
    };
    const { user } = await setup();

    await user.click(screen.getByText("play-art"));

    expect(messages).toContainEqual(
      expect.objectContaining({
        command: "metadata",
        title: "Art Episode",
        artist: "Art Show",
        artwork: "http://127.0.0.1:18180/api/artwork/episodes/4",
        duration: 1234,
      }),
    );
    expect(messages).toContainEqual(
      expect.objectContaining({ command: "load", src: "https://h.example/art.mp3", rate: 2 }),
    );
  });

  it("includes the episode id in native audio loads so native progress can persist", async () => {
    const messages: unknown[] = [];
    window.webkit = {
      messageHandlers: {
        podsAudio: {
          postMessage(message) {
            messages.push(message);
          },
        },
      },
    };
    const { user } = await setup();

    await user.click(screen.getByText("play1"));

    expect(messages).toContainEqual(
      expect.objectContaining({
        command: "load",
        episodeId: 1,
        src: "https://h.example/ep.mp3",
        position: 30,
      }),
    );
  });

  it("reopens the active native episode without reloading stale list progress", async () => {
    const messages: Array<Record<string, unknown>> = [];
    window.webkit = {
      messageHandlers: {
        podsAudio: {
          postMessage(message) {
            messages.push(message as Record<string, unknown>);
          },
        },
      },
    };
    const { user } = await setup();

    await user.click(screen.getByText("play1"));
    const firstLoad = messages.find((message) => message.command === "load");
    expect(firstLoad).toBeDefined();
    const engineId = firstLoad!.id as number;
    act(() => {
      window.PodsAudioBridge?.emit({
        id: engineId,
        type: "timeupdate",
        position: 100,
        duration: 1_800,
        paused: false,
      });
    });
    await user.click(screen.getByText("collapse"));
    expect(screen.getByTestId("expanded")).toHaveTextContent("closed");

    // The Listen row still carries its old persisted position (30), but reopening
    // the same active episode must keep the live native position (100).
    await user.click(screen.getByText("play1"));

    expect(screen.getByTestId("expanded")).toHaveTextContent("open");
    expect(screen.getByTestId("pos")).toHaveTextContent("100");
    expect(screen.getByTestId("state")).toHaveTextContent("1:playing");
    expect(messages.filter((message) => message.command === "load")).toEqual([firstLoad]);
  });

  it("does not carry a previous native playback position into a fresh episode", async () => {
    const messages: unknown[] = [];
    window.webkit = {
      messageHandlers: {
        podsAudio: {
          postMessage(message) {
            messages.push(message);
          },
        },
      },
    };
    const { user } = await setup();

    await user.click(screen.getByText("play1"));
    window.PodsAudioBridge?.emit({ type: "timeupdate", position: 4200, duration: 4800 });
    await user.click(screen.getByText("play-art"));

    expect(messages).toContainEqual(
      expect.objectContaining({
        command: "load",
        src: "https://h.example/art.mp3",
        position: 0,
      }),
    );
    expect(messages).not.toContainEqual(
      expect.objectContaining({
        command: "load",
        src: "https://h.example/art.mp3",
        position: 4200,
      }),
    );
  });

  it("keeps feed duration when native loadedmetadata reports zero", async () => {
    window.webkit = {
      messageHandlers: {
        podsAudio: {
          postMessage() {},
        },
      },
    };
    const { user } = await setup();

    await user.click(screen.getByText("play1"));
    // Default episode fixture has duration_secs: 1800
    expect(screen.getByTestId("dur")).toHaveTextContent("1800");

    act(() => {
      window.PodsAudioBridge?.emit({ type: "loadedmetadata", duration: 0, position: 30 });
    });
    expect(screen.getByTestId("dur")).toHaveTextContent("1800");
  });

  it("adopts a positive duration from later native timeupdate events", async () => {
    window.webkit = {
      messageHandlers: {
        podsAudio: {
          postMessage() {},
        },
      },
    };
    const { user } = await setup();

    await user.click(screen.getByText("play1"));
    act(() => {
      window.PodsAudioBridge?.emit({ type: "loadedmetadata", duration: 0, position: 0 });
    });
    expect(screen.getByTestId("dur")).toHaveTextContent("1800");

    act(() => {
      window.PodsAudioBridge?.emit({ type: "timeupdate", position: 12, duration: 2400 });
    });
    expect(screen.getByTestId("dur")).toHaveTextContent("2400");
    expect(screen.getByTestId("pos")).toHaveTextContent("12");
  });

  it("learns duration from native timeupdate when feed duration is missing", async () => {
    window.webkit = {
      messageHandlers: {
        podsAudio: {
          postMessage() {},
        },
      },
    };

    function NullDurProbe() {
      const p = usePlayer();
      return (
        <div>
          <button
            onClick={() =>
              p.playEpisode(episode({ id: 11, duration_secs: null, position_secs: 0 }), "recent")
            }
          >
            play-null-dur
          </button>
          <span data-testid="dur">{p.duration}</span>
          <span data-testid="pos">{Math.floor(p.position)}</span>
        </div>
      );
    }

    installApi({
      "GET /api/settings": { speed: 1, autoplay: true },
      "PUT /api/settings": null,
      "GET /api/episodes/11": {
        ...episode({ id: 11, duration_secs: null }),
        notes_html: "",
        archived_at: null,
      },
      "PUT /api/episodes/11/position": null,
    });
    const user = userEvent.setup();
    render(
      <PlayerProvider>
        <NullDurProbe />
      </PlayerProvider>,
    );

    await user.click(screen.getByText("play-null-dur"));
    expect(screen.getByTestId("dur")).toHaveTextContent("0");

    act(() => {
      window.PodsAudioBridge?.emit({ type: "loadedmetadata", duration: 0, position: 0 });
    });
    expect(screen.getByTestId("dur")).toHaveTextContent("0");

    act(() => {
      window.PodsAudioBridge?.emit({ type: "timeupdate", position: 3, duration: 999 });
    });
    expect(screen.getByTestId("dur")).toHaveTextContent("999");
    expect(screen.getByTestId("pos")).toHaveTextContent("3");
  });

  it("toggles pause/play and tracks time", async () => {
    const { user } = await setup();
    await user.click(screen.getByText("play1"));
    const audio = FakeAudio.last();

    await user.click(screen.getByText("toggle"));
    await waitFor(() => expect(screen.getByTestId("state")).toHaveTextContent("paused"));
    await user.click(screen.getByText("toggle"));
    await waitFor(() => expect(screen.getByTestId("state")).toHaveTextContent("playing"));

    act(() => audio.emitTime(125));
    expect(screen.getByTestId("pos")).toHaveTextContent("125");
  });

  it("changes speed live and persists it", async () => {
    const { calls, user } = await setup();
    await user.click(screen.getByText("play1"));
    await user.click(screen.getByText("speed3"));
    expect(FakeAudio.last().playbackRate).toBe(3);
    const put = calls.find((c) => c.key === "PUT /api/settings");
    expect(put).toBeTruthy();
    expect(JSON.parse(String(put?.init.body))).toEqual({ speed: 3, autoplay: true });
  });

  it("skips forward 30 and back 15", async () => {
    const { user } = await setup();
    await user.click(screen.getByText("play1"));
    const audio = FakeAudio.last();
    act(() => audio.emitTime(100));
    await user.click(screen.getByText("fwd"));
    expect(audio.currentTime).toBe(130);
    await user.click(screen.getByText("back"));
    expect(audio.currentTime).toBe(115);
  });

  it("on ended: marks played and autoplays the next episode", async () => {
    const next = episode({ id: 2, title: "Next", audio_url: "https://h.example/next.mp3" });
    const { calls, user } = await setup({
      "GET /api/next": next,
      "GET /api/episodes/2": { ...next, notes_html: "", archived_at: null },
      "PUT /api/episodes/2/position": null,
    });
    await user.click(screen.getByText("play1"));

    await act(async () => FakeAudio.last().emitEnded());

    await waitFor(() => expect(screen.getByTestId("state")).toHaveTextContent("2:playing"));
    expect(calls.some((c) => c.key === "POST /api/episodes/1/played")).toBe(true);
    const nextCall = calls.find((c) => c.key === "GET /api/next");
    expect(nextCall?.url.searchParams.get("after")).toBe("1");
    expect(nextCall?.url.searchParams.get("context")).toBe("recent");
    expect(FakeAudio.last().src).toBe("https://h.example/next.mp3");
  });

  it("native Mac output: replacing episode keeps Mac selected and continues with load+play only", async () => {
    const messages: Array<Record<string, unknown>> = [];
    window.webkit = {
      messageHandlers: {
        podsAudio: {
          postMessage(message) {
            messages.push(message as Record<string, unknown>);
          },
        },
      },
    };

    function CastProbe() {
      const p = usePlayer();
      return (
        <div>
          <button
            onClick={() =>
              p.playEpisode(
                episode({ id: 1, audio_url: "https://h.example/ep1.mp3", position_secs: 0 }),
                "recent",
              )
            }
          >
            play1
          </button>
          <button
            onClick={() =>
              p.playEpisode(
                episode({ id: 2, title: "Next", audio_url: "https://h.example/ep2.mp3", position_secs: 0 }),
                "recent",
              )
            }
          >
            play2
          </button>
          <button onClick={() => p.setCastOutput("mac")}>cast-mac</button>
          <span data-testid="state">
            {p.current
              ? `${p.current.id}:${p.playing ? "playing" : "paused"}`
              : "none"}
          </span>
          <span data-testid="cast">
            {`${p.cast.output}:${p.cast.connected ? "up" : "down"}`}
          </span>
        </div>
      );
    }

    installApi({
      "GET /api/settings": { speed: 1, autoplay: true },
      "PUT /api/settings": null,
      "GET /api/episodes/1": { ...episode({ id: 1 }), notes_html: "", archived_at: null },
      "GET /api/episodes/2": {
        ...episode({ id: 2, title: "Next", audio_url: "https://h.example/ep2.mp3" }),
        notes_html: "",
        archived_at: null,
      },
      "PUT /api/episodes/1/position": null,
      "PUT /api/episodes/2/position": null,
    });
    const user = userEvent.setup();
    render(
      <PlayerProvider>
        <CastProbe />
      </PlayerProvider>,
    );

    await user.click(screen.getByText("play1"));
    await user.click(screen.getByText("cast-mac"));
    act(() => {
      window.PodsAudioBridge?.emit({
        type: "cast",
        available: true,
        connected: true,
        name: "Pods Speaker",
        output: "mac",
      });
      window.PodsAudioBridge?.emit({ type: "play", paused: false, position: 10 });
    });
    await waitFor(() => expect(screen.getByTestId("cast")).toHaveTextContent("mac:up"));
    await waitFor(() => expect(screen.getByTestId("state")).toHaveTextContent("1:playing"));

    const before = messages.length;
    await user.click(screen.getByText("play2"));

    const after = messages.slice(before);
    expect(after.some((m) => m.command === "castDisconnect")).toBe(false);
    expect(after.some((m) => m.command === "stop")).toBe(false);
    expect(after).toContainEqual(
      expect.objectContaining({
        command: "load",
        src: "https://h.example/ep2.mp3",
        episodeId: 2,
      }),
    );
    expect(after).toContainEqual(expect.objectContaining({ command: "play" }));
    // Must not flip the user-selected sink back to local on the command stream.
    expect(after.filter((m) => m.command === "castConnect").length).toBeLessThanOrEqual(1);
    expect(screen.getByTestId("cast")).toHaveTextContent("mac:up");
    await waitFor(() => expect(screen.getByTestId("state")).toHaveTextContent("2:playing"));
  });

  it("native bridge ended: marks played, loads next, ignores late ended for prior episodeId", async () => {
    const messages: Array<Record<string, unknown>> = [];
    window.webkit = {
      messageHandlers: {
        podsAudio: {
          postMessage(message) {
            messages.push(message as Record<string, unknown>);
          },
        },
      },
    };

    const next = episode({ id: 2, title: "Next", audio_url: "https://h.example/next.mp3" });
    const third = episode({ id: 3, title: "Third", audio_url: "https://h.example/third.mp3" });
    const { calls, user } = await setup({
      "GET /api/next": (url: URL) => {
        const after = url.searchParams.get("after");
        if (after === "1") return next;
        if (after === "2") return third;
        return null;
      },
      "GET /api/episodes/2": { ...next, notes_html: "", archived_at: null },
      "GET /api/episodes/3": { ...third, notes_html: "", archived_at: null },
      "PUT /api/episodes/2/position": null,
      "PUT /api/episodes/3/position": null,
      "POST /api/episodes/2/played": null,
      "POST /api/episodes/3/played": null,
    });

    await user.click(screen.getByText("play1"));
    const engineId = messages.find((m) => m.command === "load")?.id as number;

    // Episode 1 completes with an identity-tagged ended event.
    await act(async () => {
      window.PodsAudioBridge?.emit({ id: engineId, type: "ended", paused: true, episodeId: 1 });
    });

    await waitFor(() => expect(screen.getByTestId("state")).toHaveTextContent("2:playing"));
    expect(calls.filter((c) => c.key === "POST /api/episodes/1/played")).toHaveLength(1);
    expect(calls.filter((c) => c.key === "GET /api/next")).toHaveLength(1);
    expect(calls.find((c) => c.key === "GET /api/next")?.url.searchParams.get("after")).toBe("1");

    const loadNext = messages.filter(
      (m) => m.command === "load" && m.src === "https://h.example/next.mp3",
    );
    expect(loadNext).toHaveLength(1);
    expect(loadNext[0]).toEqual(expect.objectContaining({ episodeId: 2 }));
    const playAfterNextLoad = messages
      .map((m, i) => ({ m, i }))
      .filter(({ m }) => m.command === "play" && m.id === engineId);
    expect(playAfterNextLoad.length).toBeGreaterThan(0);

    // New episode produces at least one timeupdate — the old suppressEndedRef heuristic
    // clears here, which is the race the identity filter must close.
    await act(async () => {
      window.PodsAudioBridge?.emit({
        id: engineId,
        type: "timeupdate",
        position: 1,
        duration: 300,
        episodeId: 2,
        paused: false,
      });
    });
    await waitFor(() => expect(screen.getByTestId("pos")).toHaveTextContent("1"));

    // Late ended tagged for the *previous* episode must not mark/skip the new one.
    const playedBeforeStale = calls.filter((c) => c.key.startsWith("POST /api/episodes/")).length;
    const nextBeforeStale = calls.filter((c) => c.key === "GET /api/next").length;
    await act(async () => {
      window.PodsAudioBridge?.emit({ id: engineId, type: "ended", paused: true, episodeId: 1 });
    });

    await waitFor(() => expect(screen.getByTestId("state")).toHaveTextContent("2:playing"));
    expect(calls.filter((c) => c.key.startsWith("POST /api/episodes/")).length).toBe(playedBeforeStale);
    expect(calls.filter((c) => c.key === "GET /api/next").length).toBe(nextBeforeStale);
    expect(calls.some((c) => c.key === "POST /api/episodes/2/played")).toBe(false);
    expect(messages.filter((m) => m.command === "load" && m.src === "https://h.example/third.mp3")).toHaveLength(
      0,
    );
  });

  it("on ended with autoplay off: marks played and closes", async () => {
    const { calls, user } = await setup();
    await user.click(screen.getByText("autoplay-off"));
    await user.click(screen.getByText("play1"));

    await act(async () => FakeAudio.last().emitEnded());

    await waitFor(() => expect(screen.getByTestId("state")).toHaveTextContent("none"));
    expect(calls.some((c) => c.key === "POST /api/episodes/1/played")).toBe(true);
    expect(calls.some((c) => c.key === "GET /api/next")).toBe(false);
  });

  it("on ended with nothing next: closes", async () => {
    const { user } = await setup({ "GET /api/next": null });
    await user.click(screen.getByText("play1"));
    await act(async () => FakeAudio.last().emitEnded());
    await waitFor(() => expect(screen.getByTestId("state")).toHaveTextContent("none"));
  });

  it("show context is passed to /api/next", async () => {
    const { calls, user } = await setup({ "GET /api/next": null });
    await user.click(screen.getByText("play9"));
    await act(async () => FakeAudio.last().emitEnded());
    await waitFor(() => expect(screen.getByTestId("state")).toHaveTextContent("none"));
    const nextCall = calls.find((c) => c.key === "GET /api/next");
    expect(nextCall?.url.searchParams.get("context")).toBe("show");
  });

  it("mark played manually closes the player", async () => {
    const { calls, user } = await setup();
    await user.click(screen.getByText("play1"));
    await user.click(screen.getByText("done"));
    await waitFor(() => expect(screen.getByTestId("state")).toHaveTextContent("none"));
    expect(calls.some((c) => c.key === "POST /api/episodes/1/played")).toBe(true);
  });

  it("flushes the playback position to the server on pause", async () => {
    const { calls, user } = await setup();
    await user.click(screen.getByText("play1"));
    const audio = FakeAudio.last();
    act(() => audio.emitTime(42));

    await user.click(screen.getByText("toggle")); // pause flushes position
    await waitFor(() => {
      const sync = calls.filter((c) => c.key === "PUT /api/episodes/1/position");
      expect(sync.length).toBeGreaterThan(0);
      expect(JSON.parse(String(sync.at(-1)?.init.body))).toEqual({ seconds: 42 });
    });
  });

  it("keeps the player paused when play() fails", async () => {
    FakeAudio.failNextPlay = true;
    const { user } = await setup();
    await user.click(screen.getByText("play1"));
    await waitFor(() => expect(screen.getByTestId("state")).toHaveTextContent("1:paused"));
  });

  it("shows a show-notes error that retry can clear", async () => {
    const { user } = await setup({
      "GET /api/episodes/1": {
        ...episode({ id: 1, position_secs: 30, ad_removal_state: "ad-free", ad_removal_stage: "ready" }),
        notes_html: "",
        show_notes: [],
        archived_at: null,
      },
      "POST /api/episodes/1/show-notes": () => {
        throw new Error("notes failed");
      },
    });
    await user.click(screen.getByText("play1"));
    await waitFor(() =>
      expect(screen.getByTestId("show-notes-status")).toHaveTextContent(
        "Show notes could not be generated. Please try again.",
      ),
    );
  });

  it("continues playback when mark-played or next fails on ended", async () => {
    const warning = vi.spyOn(console, "warn").mockImplementation(() => {});
    const { user } = await setup({
      "POST /api/episodes/1/played": new HttpError(500, { error: "offline" }),
      "GET /api/next": () => {
        throw new Error("next failed");
      },
    });
    await user.click(screen.getByText("play1"));
    await act(async () => FakeAudio.last().emitEnded());
    await waitFor(() => expect(screen.getByTestId("state")).toHaveTextContent("none"));
    expect(warning).toHaveBeenCalled();
    warning.mockRestore();
  });

  it("wires lock-screen media session actions and metadata", async () => {
    const handlers = new Map<string, ((details?: { seekTime?: number }) => void) | null>();
    const setPositionState = vi.fn();
    Object.defineProperty(navigator, "mediaSession", {
      configurable: true,
      value: {
        metadata: null,
        setActionHandler(name: string, handler: ((details?: { seekTime?: number }) => void) | null) {
          handlers.set(name, handler);
        },
        setPositionState,
      },
    });
    vi.stubGlobal(
      "MediaMetadata",
      class {
        title: string;
        artist: string;
        artwork: unknown;
        constructor(init: { title: string; artist: string; artwork?: unknown }) {
          this.title = init.title;
          this.artist = init.artist;
          this.artwork = init.artwork;
        }
      },
    );
    const intervals: Array<() => void> = [];
    vi.spyOn(window, "setInterval").mockImplementation((fn) => {
      intervals.push(fn as () => void);
      return 1 as unknown as ReturnType<typeof setInterval>;
    });
    vi.spyOn(window, "clearInterval").mockImplementation(() => {});

    const { user } = await setup();
    await user.click(screen.getByText("play1"));
    const audio = FakeAudio.last();
    act(() => audio.emitLoadedMetadata(1800));
    act(() => audio.emitTime(40));

    expect(handlers.get("play")).toEqual(expect.any(Function));
    handlers.get("pause")?.();
    await waitFor(() => expect(screen.getByTestId("state")).toHaveTextContent("paused"));
    handlers.get("play")?.();
    await waitFor(() => expect(screen.getByTestId("state")).toHaveTextContent("playing"));
    handlers.get("seekforward")?.();
    expect(audio.currentTime).toBe(70);
    handlers.get("seekbackward")?.();
    expect(audio.currentTime).toBe(55);
    handlers.get("seekto")?.({ seekTime: 12 });
    expect(audio.currentTime).toBe(12);

    act(() => {
      for (const tick of intervals) tick();
    });
    expect(setPositionState).toHaveBeenCalled();
  });

  it("sends a correlated native speed change and can undo an ad skip", async () => {
    const messages: unknown[] = [];
    window.webkit = {
      messageHandlers: {
        podsAudio: {
          postMessage(message) {
            messages.push(message);
          },
        },
      },
    };
    const { user } = await setup();
    await user.click(screen.getByText("play1"));
    await user.click(screen.getByText("speed-corr"));
    expect(messages).toContainEqual(
      expect.objectContaining({ command: "rate", rate: 2.5, correlationId: "speed-test" }),
    );
    await user.click(screen.getByText("undo-skip"));
    expect(messages).toContainEqual(expect.objectContaining({ command: "undoAdSkip" }));
    await user.click(screen.getByText("cast-local"));
    expect(messages).toContainEqual(expect.objectContaining({ command: "castDisconnect" }));
  });

  it("keeps a malformed artwork url as-is for now-playing metadata", async () => {
    function BadArtProbe() {
      const p = usePlayer();
      return (
        <button
          onClick={() =>
            p.playEpisode(
              episode({ id: 1, image_url: "http://[bad", podcast_image: "", title: "Bad Art" }),
              "recent",
            )
          }
        >
          play-bad-art
        </button>
      );
    }
    installApi({
      "GET /api/settings": { speed: 1, autoplay: true },
      "PUT /api/settings": null,
      "GET /api/episodes/1": {
        ...episode({ id: 1, image_url: "http://[bad" }),
        notes_html: "",
        archived_at: null,
      },
      "PUT /api/episodes/1/position": null,
    });
    const user = userEvent.setup();
    render(
      <PlayerProvider>
        <BadArtProbe />
      </PlayerProvider>,
    );
    await user.click(screen.getByText("play-bad-art"));
    expect(FakeAudio.last().src).toBe("https://h.example/ep.mp3");
  });
});

const ARTIFACT_HASH = "a".repeat(64);

function downloadedEpisode(overrides: Partial<EpisodeItem> = {}): EpisodeItem {
  const manifest: ArtifactManifest = {
    version: 1,
    episode_id: 1,
    hash: ARTIFACT_HASH,
    source_hash: "source",
    bytes: 8,
    duration: 1800,
    chunk_size: 1024 ** 2,
    chunks: [ARTIFACT_HASH],
    timeline: [{ original_start: 0, original_end: 1800, processed_start: 0 }],
  };
  return episode({
    id: 1,
    position_secs: 30,
    downloaded: true,
    manifest,
    ...overrides,
  });
}

function OfflinePositionProbe({ item }: { item: EpisodeItem }) {
  const p = usePlayer();
  return (
    <div>
      <button onClick={() => p.playEpisode(item, "recent")}>play-offline</button>
      <button onClick={() => p.seekTo(0)}>restart</button>
      <button onClick={p.toggle}>toggle</button>
      <span data-testid="state">
        {p.current ? `${p.current.id}:${p.playing ? "playing" : "paused"}` : "none"}
      </span>
      <span data-testid="pos">{Math.floor(p.position)}</span>
    </div>
  );
}

function hideDocument() {
  Object.defineProperty(document, "visibilityState", { configurable: true, value: "hidden" });
  document.dispatchEvent(new Event("visibilitychange"));
}

describe("PlayerProvider offline position flush", () => {
  function renderOffline(item: EpisodeItem) {
    window.PODS_LOCAL_CLIENT = true;
    const setPosition = vi.spyOn(Api, "setPosition").mockResolvedValue(undefined);
    render(
      <PlayerProvider>
        <OfflinePositionProbe item={item} />
      </PlayerProvider>,
    );
    return { setPosition };
  }

  it("retries a WebKit gesture rejection synchronously on the next Play tap", async () => {
    renderOffline(downloadedEpisode());
    const audio = FakeAudio.last();
    const play = vi.spyOn(audio, "play").mockRejectedValueOnce(new DOMException("User gesture required", "NotAllowedError"));
    await act(async () => { screen.getByText("play-offline").click(); });
    expect(screen.getByTestId("state")).toHaveTextContent("1:paused");
    expect(play).toHaveBeenCalledTimes(1);
    act(() => {
      screen.getByText("toggle").click();
      // This assertion runs before any microtask, inside the gesture's call stack.
      expect(play).toHaveBeenCalledTimes(2);
    });
    expect(screen.getByTestId("state")).toHaveTextContent("1:playing");
  });

  it("does not persist startup zero while a nonzero resume is pending", async () => {
    vi.useFakeTimers();
    const { setPosition } = renderOffline(downloadedEpisode());

    await act(async () => {
      screen.getByText("play-offline").click();
      await Promise.resolve();
    });
    const audio = FakeAudio.last();
    expect(audio.currentTime).toBe(0);
    expect(screen.getByTestId("state")).toHaveTextContent("1:playing");

    await act(async () => {
      await vi.advanceTimersByTimeAsync(POSITION_SYNC_INTERVAL_MS);
    });
    act(() => {
      hideDocument();
      window.dispatchEvent(new Event("pagehide"));
    });
    act(() => {
      screen.getByText("toggle").click();
    });
    expect(setPosition).not.toHaveBeenCalled();

    act(() => audio.emitLoadedMetadata(1800));
    expect(audio.currentTime).toBe(30);

    act(() => {
      hideDocument();
      window.dispatchEvent(new Event("pagehide"));
    });
    expect(setPosition).toHaveBeenCalledWith(1, 30, ARTIFACT_HASH);

    await act(async () => {
      screen.getByText("toggle").click();
      await Promise.resolve();
    });
    setPosition.mockClear();
    await act(async () => {
      await vi.advanceTimersByTimeAsync(POSITION_SYNC_INTERVAL_MS);
    });
    expect(setPosition).toHaveBeenCalledWith(1, 30, ARTIFACT_HASH);
  });

  it("persists an explicit restart zero before and after resume applies", async () => {
    const { setPosition } = renderOffline(downloadedEpisode());
    const user = userEvent.setup();
    await user.click(screen.getByText("play-offline"));
    const audio = FakeAudio.last();
    expect(audio.currentTime).toBe(0);

    await user.click(screen.getByText("restart"));
    expect(setPosition).toHaveBeenCalledWith(1, 0, ARTIFACT_HASH);

    act(() => audio.emitLoadedMetadata(1800));
    expect(audio.currentTime).toBe(0);

    act(() => audio.emitTime(40));
    setPosition.mockClear();
    await user.click(screen.getByText("restart"));
    expect(setPosition).toHaveBeenCalledWith(1, 0, ARTIFACT_HASH);
  });

  it("persists legitimate startup zero when no resume is waiting", async () => {
    vi.useFakeTimers();
    const { setPosition } = renderOffline(downloadedEpisode({ position_secs: 0 }));

    await act(async () => {
      screen.getByText("play-offline").click();
      await Promise.resolve();
    });
    expect(FakeAudio.last().currentTime).toBe(0);

    await act(async () => {
      await vi.advanceTimersByTimeAsync(POSITION_SYNC_INTERVAL_MS);
    });
    act(() => {
      hideDocument();
      window.dispatchEvent(new Event("pagehide"));
    });
    expect(setPosition).toHaveBeenCalledWith(1, 0, ARTIFACT_HASH);
  });
});

const NEXT_HASH = "b".repeat(64);

function offlineManifest(id: number, hash: string): ArtifactManifest {
  return {
    version: 1,
    episode_id: id,
    hash,
    source_hash: "source",
    bytes: 8,
    duration: 1800,
    chunk_size: 1024 ** 2,
    chunks: [hash],
    timeline: [{ original_start: 0, original_end: 1800, processed_start: 0 }],
  };
}

function listenItem(id: number, hash: string): EpisodeItem {
  return downloadedEpisode({
    id,
    title: `Episode ${id}`,
    audio_url: `/_media/${hash}.m4a`,
    downloaded: true,
    manifest: offlineManifest(id, hash),
    position_secs: 0,
  });
}

function OfflineCleanupProbe({ item }: { item: EpisodeItem }) {
  const p = usePlayer();
  return (
    <div>
      <button onClick={() => p.playEpisode(item, "recent")}>play-offline</button>
      <button onClick={() => void p.markPlayedAndClose()}>done</button>
      <span data-testid="state">
        {p.current ? `${p.current.id}:${p.playing ? "playing" : "paused"}` : "none"}
      </span>
    </div>
  );
}

async function seedListenDownloads() {
  const snapshot: Snapshot = {
    version: 1,
    cursor: 0,
    replace: true,
    settings: { speed: 1, autoplay: true },
    versions: {},
    shows: [{ id: 1, feed_url: "https://example.org/feed", title: "Example", description: "", image_url: "", site_url: "", episode_count: 2, unplayed_count: 2 }],
    episodes: [1, 2].map((id) => {
      const hash = id === 1 ? ARTIFACT_HASH : NEXT_HASH;
      return {
        id,
        podcast_id: 1,
        podcast_title: "Example",
        title: `Episode ${id}`,
        podcast_image: "",
        image_url: "",
        published_at: id,
        duration_secs: 1800,
        position_secs: 0,
        played_at: null,
        archived_at: null,
        notes_html: "",
        show_notes: [],
        ad_markers: [],
        audio_url: `/_media/${hash}.m4a`,
        ad_removal_state: "ad-free" as const,
        ad_removal_stage: "ready" as const,
        ad_removal_action: null,
        ad_removal_blocking_reason: null,
        manifest: offlineManifest(id, hash),
      };
    }),
  };
  await updateState((s) => { s.snapshot = snapshot; });
  for (const [id, hash] of [[1, ARTIFACT_HASH], [2, NEXT_HASH]] as const) {
    await writeRecord("meta", `manifest:${hash}`, offlineManifest(id, hash));
    await writeRecord("chunks", `${hash}:0`, new TextEncoder().encode("abcdefgh").buffer);
    await writeRecord("downloads", hash, { hash, episode: id, bytes: 8, complete: true, touched: 0 });
  }
}

describe("PlayerProvider automatic download cleanup", () => {
  beforeEach(() => {
    vi.stubGlobal("indexedDB", new IDBFactory());
    vi.stubGlobal("IDBKeyRange", IDBKeyRange);
    window.PODS_LOCAL_CLIENT = true;
    window.PODS_API_BASE = "https://sync.pods.mcgiv.dev:8443";
  });

  it("on ended: removes completed audio, keeps played metadata, and autoplays the next download", async () => {
    await seedListenDownloads();
    const first = listenItem(1, ARTIFACT_HASH);
    render(
      <PlayerProvider>
        <OfflineCleanupProbe item={first} />
      </PlayerProvider>,
    );
    await act(async () => {
      screen.getByText("play-offline").click();
      await Promise.resolve();
    });
    await waitFor(() => expect(screen.getByTestId("state")).toHaveTextContent("1:playing"));
    await act(async () => FakeAudio.last().emitEnded());
    await waitFor(() => expect(screen.getByTestId("state")).toHaveTextContent("2:playing"));
    expect(FakeAudio.last().src).toBe(`/_media/${NEXT_HASH}.m4a`);
    expect(await allDownloads()).toEqual([expect.objectContaining({ hash: NEXT_HASH, episode: 2, complete: true })]);
    expect(await readRecord("meta", `manifest:${ARTIFACT_HASH}`)).toBeUndefined();
    expect(await readRecord("chunks", `${ARTIFACT_HASH}:0`)).toBeUndefined();
    expect((await Api.played()).items.map((item) => item.id)).toEqual([1]);
    expect((await Api.recent()).items.map((item) => item.id)).toEqual([2]);
  });

  it("stops the active episode before deleting its download", async () => {
    await seedListenDownloads();
    const original = store.deleteDownload.bind(store);
    const spy = vi.spyOn(store, "deleteDownload").mockImplementation(async (hash) => {
      expect(screen.getByTestId("state")).toHaveTextContent("none");
      expect(FakeAudio.last().src).toBe("");
      expect(FakeAudio.last().paused).toBe(true);
      return original(hash);
    });
    const first = listenItem(1, ARTIFACT_HASH);
    render(
      <PlayerProvider>
        <OfflineCleanupProbe item={first} />
      </PlayerProvider>,
    );
    await act(async () => {
      screen.getByText("play-offline").click();
      await Promise.resolve();
    });
    await waitFor(() => expect(screen.getByTestId("state")).toHaveTextContent("1:playing"));
    await act(async () => {
      screen.getByText("done").click();
      await Promise.resolve();
    });
    await waitFor(() => expect(screen.getByTestId("state")).toHaveTextContent("none"));
    await waitFor(() => expect(spy).toHaveBeenCalled());
    expect(await allDownloads()).toEqual([expect.objectContaining({ hash: NEXT_HASH, episode: 2 })]);
    expect(await readRecord("downloads", ARTIFACT_HASH)).toBeUndefined();
    spy.mockRestore();
  });
});
