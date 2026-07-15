import { act, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it } from "vitest";
import { PlayerProvider, usePlayer } from "./player";
import { episode, installApi, type MockRoutes } from "./test/mockApi";
import { FakeAudio } from "./test/fakeAudio";

afterEach(() => {
  delete window.webkit;
  delete window.PODS_API_BASE;
  delete window.PodsAudioBridge;
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
      <button onClick={() => p.setAutoplay(false)}>autoplay-off</button>
      <button onClick={() => void p.markPlayedAndClose()}>done</button>
      <button onClick={p.skipForward}>fwd</button>
      <button onClick={p.skipBack}>back</button>
      <span data-testid="state">
        {p.current
          ? `${p.current.id}:${p.playing ? "playing" : "paused"}:${p.speed}:${p.autoplay ? "auto" : "manual"}`
          : "none"}
      </span>
      <span data-testid="dur">{p.duration}</span>
      <span data-testid="pos">{Math.floor(p.position)}</span>
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
});
