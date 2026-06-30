import { act, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it } from "vitest";
import { PlayerProvider, usePlayer } from "./player";
import { episode, installApi, type MockRoutes } from "./test/mockApi";
import { FakeAudio } from "./test/fakeAudio";

function Probe() {
  const p = usePlayer();
  return (
    <div>
      <button onClick={() => p.playEpisode(episode({ id: 1, position_secs: 30 }), "recent")}>
        play1
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
    "GET /api/episodes/9": { ...episode({ id: 9 }), notes_html: "", archived_at: null },
    "PUT /api/episodes/1/position": null,
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
