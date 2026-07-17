import { act, fireEvent, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { PlayerProvider, usePlayer } from "../player";
import { FakeAudio } from "../test/fakeAudio";
import { episode, installApi } from "../test/mockApi";
import { MiniPlayer } from "./MiniPlayer";
import { PlayerSheet } from "./PlayerSheet";

function Starter() {
  const p = usePlayer();
  return (
    <button onClick={() => p.playEpisode(episode({ id: 1, title: "Sheet Episode" }), "recent")}>
      start
    </button>
  );
}

function setup() {
  const mocked = installApi({
    "GET /api/settings": { speed: 1, autoplay: true },
    "PUT /api/settings": null,
    "GET /api/episodes/1": {
      ...episode({ id: 1, title: "Sheet Episode" }),
      notes_html: "<p>The show notes</p>",
      archived_at: null,
    },
    "PUT /api/episodes/1/position": null,
    "POST /api/episodes/1/played": null,
  });
  const user = userEvent.setup();
  render(
    <PlayerProvider>
      <Starter />
      <MiniPlayer />
      <PlayerSheet />
    </PlayerProvider>,
  );
  return { ...mocked, user };
}

describe("PlayerSheet + MiniPlayer", () => {
  it("shows a minimal indicator while the audio stream initializes", async () => {
    const { user } = setup();
    await user.click(screen.getByText("start"));

    expect(await screen.findByRole("status", { name: "Loading audio" })).toBeInTheDocument();
    act(() => FakeAudio.last().emitLoadedMetadata(600));
    expect(screen.queryByRole("status", { name: "Loading audio" })).not.toBeInTheDocument();
  });

  it("opens expanded with controls, collapses to the mini player, re-expands", async () => {
    const { user } = setup();
    await user.click(screen.getByText("start"));

    // expanded sheet
    const sheet = await screen.findByRole("dialog", { name: "Player" });
    expect(sheet).toBeInTheDocument();
    await screen.findByText("The show notes");

    // collapse -> mini player visible
    await user.click(screen.getByRole("button", { name: "Minimize player" }));
    expect(screen.queryByRole("dialog", { name: "Player" })).not.toBeInTheDocument();
    const mini = screen.getByRole("button", { name: "Open player" });
    expect(mini).toHaveTextContent("Sheet Episode");
    expect(screen.getByText("Sheet Episode")).toHaveClass("episode-title-full");

    // re-expand
    await user.click(mini);
    expect(screen.getByRole("dialog", { name: "Player" })).toBeInTheDocument();
  });

  it("keeps the minimize control outside the momentum-scrolling region", async () => {
    const { user } = setup();
    await user.click(screen.getByText("start"));

    const sheet = await screen.findByRole("dialog", { name: "Player" });
    const scrollRegion = sheet.querySelector(".sheet-scroll-region");
    const minimize = screen.getByRole("button", { name: "Minimize player" });

    expect(scrollRegion).not.toBeNull();
    expect(scrollRegion).not.toContainElement(minimize);
  });

  it("speed chips set the playback rate", async () => {
    const { user } = setup();
    await user.click(screen.getByText("start"));
    await screen.findByRole("dialog", { name: "Player" });

    await user.click(screen.getByRole("button", { name: "2.5×" }));
    expect(FakeAudio.last().playbackRate).toBe(2.5);
    expect(screen.getByRole("button", { name: "2.5×" })).toHaveClass("active");
  });

  it("gives every playback speed control a full-size touch target", async () => {
    const { user } = setup();
    await user.click(screen.getByText("start"));
    await screen.findByRole("dialog", { name: "Player" });

    for (const speed of ["1×", "1.5×", "2×", "2.5×", "3×"]) {
      expect(screen.getByRole("button", { name: speed })).toHaveClass("speed-chip");
    }
  });

  it("correlates pointer receipt and click for a speed selection", async () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    const { user } = setup();
    await user.click(screen.getByText("start"));

    await user.click(await screen.findByRole("button", { name: "2×" }));

    const pointer = log.mock.calls.find(([message]) => String(message).includes("speed_pointer_received"));
    const click = log.mock.calls.find(([message]) => String(message).includes("speed_click"));
    expect(pointer).toBeDefined();
    expect(click).toBeDefined();
    expect(String(click?.[0]).match(/correlation_id=([^ ]+)/)?.[1]).toBe(
      String(pointer?.[0]).match(/correlation_id=([^ ]+)/)?.[1],
    );
    log.mockRestore();
  });

  it("scrubber seeks and time labels track", async () => {
    const { user } = setup();
    await user.click(screen.getByText("start"));
    await screen.findByRole("dialog", { name: "Player" });
    const audio = FakeAudio.last();
    act(() => audio.emitLoadedMetadata(600));

    const scrubber = screen.getByRole("slider", { name: "Seek" });
    fireEvent.change(scrubber, { target: { value: "120" } });
    expect(audio.currentTime).toBe(120);
    expect(screen.getByText("2:00")).toBeInTheDocument();
    expect(screen.getByText("-8:00")).toBeInTheDocument();
  });

  it("autoplay switch persists the setting", async () => {
    const { calls, user } = setup();
    await user.click(screen.getByText("start"));
    await screen.findByRole("dialog", { name: "Player" });

    await user.click(screen.getByRole("switch"));
    const put = calls.filter((c) => c.key === "PUT /api/settings").at(-1);
    expect(JSON.parse(String(put?.init.body))).toEqual({ speed: 1, autoplay: false });
  });

  it("mark played closes the sheet", async () => {
    const { calls, user } = setup();
    await user.click(screen.getByText("start"));
    await screen.findByRole("dialog", { name: "Player" });
    await user.click(screen.getByRole("button", { name: "Mark played" }));
    expect(await screen.findByText("start")).toBeInTheDocument();
    expect(screen.queryByRole("dialog", { name: "Player" })).not.toBeInTheDocument();
    expect(calls.some((c) => c.key === "POST /api/episodes/1/played")).toBe(true);
  });

  it("mini player toggle pauses without expanding", async () => {
    const { user } = setup();
    await user.click(screen.getByText("start"));
    await user.click(screen.getByRole("button", { name: "Minimize player" }));

    await user.click(screen.getByRole("button", { name: "Pause" }));
    expect(FakeAudio.last().paused).toBe(true);
    expect(screen.getByRole("button", { name: "Play" })).toBeInTheDocument();
    expect(screen.queryByRole("dialog", { name: "Player" })).not.toBeInTheDocument();
  });

  it("shows one pending skipped-duration action and sends Undo to native playback", async () => {
    const { user } = setup();
    await user.click(screen.getByText("start"));
    await screen.findByRole("dialog", { name: "Player" });
    const audio = FakeAudio.last() as FakeAudio & { undoAdSkip?: () => void };
    const undo = vi.fn();
    audio.undoAdSkip = undo;

    act(() => audio.dispatchEvent(new CustomEvent("adSkip", {
      detail: {
        rangeId: "range-1",
        rangeStart: 10,
        rangeEnd: 30,
        skippedDuration: 20,
      },
    })));

    expect(screen.getByText("Skipped 0:20")).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Undo skipped section" }));
    expect(undo).toHaveBeenCalledOnce();

    act(() => audio.dispatchEvent(new CustomEvent("adSkipUndone")));
    expect(screen.queryByText("Skipped 0:20")).not.toBeInTheDocument();
  });
});
