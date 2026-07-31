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
      notes_html: "<p>Publisher-provided notes should stay hidden.</p>",
      show_notes: [
        {
          id: "segment-topic",
          start_time: 125.25,
          title: "A new direction",
          summary: "The discussion moves to the next major topic.",
        },
        {
          id: "segment-closing",
          start_time: 240,
          title: "Closing lessons",
          summary: "The episode closes with practical lessons.",
        },
        {
          id: "segment-long-form",
          start_time: 3661,
          title: "Long-form takeaway",
          summary: "A final takeaway after the first hour.",
        },
      ],
      ad_markers: [
        { id: "ad-range-1", start_time: 42.5 },
        { id: "ad-range-2", start_time: 60 },
      ],
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
    expect(screen.queryByText("Publisher-provided notes should stay hidden.")).not.toBeInTheDocument();

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

  it("seeks to a generated show-note timestamp", async () => {
    const { user } = setup();
    await user.click(screen.getByText("start"));
    await screen.findByRole("dialog", { name: "Player" });
    const audio = FakeAudio.last();

    await user.click(screen.getByRole("button", { name: "2:05 A new direction" }));

    expect(audio.currentTime).toBe(125.25);
  });

  it("links to the next generated chapter while excluding Ads markers", async () => {
    const { user } = setup();
    await user.click(screen.getByText("start"));
    await screen.findByRole("dialog", { name: "Player" });
    const audio = FakeAudio.last();

    const firstNext = screen.getByRole("button", { name: "Next: A new direction (0hrs 2mins)" });
    expect(firstNext.querySelector(".next-chapter-prefix")).toHaveTextContent("Next:");
    expect(firstNext.querySelector(".next-chapter-time")).toHaveTextContent("(0hrs 2mins)");
    expect(screen.queryByRole("button", { name: /Next: Ads/ })).not.toBeInTheDocument();
    await user.click(firstNext);
    expect(audio.currentTime).toBe(125.25);
    const closing = screen.getByRole("button", { name: "Next: Closing lessons (0hrs 4mins)" });
    await user.click(closing);
    expect(screen.getByRole("button", { name: "Next: Long-form takeaway (1hr 1min)" })).toBeInTheDocument();
  });

  it("places playback options above Chapters and collapses consecutive ad markers", async () => {
    const { user } = setup();
    await user.click(screen.getByText("start"));
    const sheet = await screen.findByRole("dialog", { name: "Player" });

    const playOn = screen.getByText("Play on");
    const chapters = screen.getByRole("heading", { name: "Chapters" });
    expect(playOn.compareDocumentPosition(chapters) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    const markPlayed = screen.getByRole("button", { name: "Mark played" });
    const autoplay = screen.getByRole("switch", { name: "Autoplay next" });
    expect(markPlayed.parentElement).toBe(autoplay.parentElement);
    expect(markPlayed).toHaveClass("chip", "mark-played-btn");
    expect(autoplay.querySelector(".autoplay-toggle-track")).toBeTruthy();
    expect(autoplay.querySelector(".autoplay-toggle-thumb")).toBeTruthy();

    const ad = screen.getByRole("button", { name: "0:42 Ads" });
    expect(ad).toHaveTextContent("0:42");
    expect(ad).toHaveTextContent("Ads");
    await user.click(ad);
    expect(FakeAudio.last().currentTime).toBe(42.5);
    expect(sheet.querySelectorAll(".show-note.is-ad")).toHaveLength(1);
  });

  it("keeps the Mac output label stable after the speaker identifies itself", async () => {
    window.webkit = {
      messageHandlers: { podsAudio: { postMessage() {} } },
    };
    try {
      const { user } = setup();
      await user.click(screen.getByText("start"));
      await screen.findByRole("dialog", { name: "Player" });

      window.PodsAudioBridge?.emit({
        type: "cast",
        cast: { available: true, connected: true, name: "Matthew's Mac", output: "mac" },
      });

      expect(await screen.findByRole("button", { name: "Mac" })).toHaveTextContent("Mac");
      expect(screen.getByRole("button", { name: "Mac" })).not.toHaveTextContent("Matthew's Mac");
    } finally {
      window.webkit = undefined;
    }
  });

  it("autoplay switch persists the setting", async () => {
    const { calls, user } = setup();
    await user.click(screen.getByText("start"));
    await screen.findByRole("dialog", { name: "Player" });

    const autoplay = screen.getByRole("switch", { name: "Autoplay next" });
    expect(autoplay).toHaveAttribute("aria-checked", "true");
    await user.click(autoplay);
    expect(autoplay).toHaveAttribute("aria-checked", "false");
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

  it("shows skipped-duration Undo as a 10-second top-banner toast", async () => {
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

    const toast = screen.getByRole("status", { name: "Ad skip notification" });
    expect(toast).toHaveClass("top-confirmation", "is-visible");
    expect(toast).toHaveTextContent("Skipped 0:20");
    await user.click(screen.getByRole("button", { name: "Undo skipped section" }));
    expect(undo).toHaveBeenCalledOnce();

    act(() => audio.dispatchEvent(new CustomEvent("adSkipUndone")));
    expect(screen.queryByText("Skipped 0:20")).not.toBeInTheDocument();
  });

  it("dismisses the ad-skip toast after ten seconds", async () => {
    const { user } = setup();
    await user.click(screen.getByText("start"));
    await screen.findByRole("dialog", { name: "Player" });
    const audio = FakeAudio.last();
    vi.useFakeTimers();

    act(() => audio.dispatchEvent(new CustomEvent("adSkip", {
      detail: {
        rangeId: "range-timed",
        rangeStart: 10,
        rangeEnd: 30,
        skippedDuration: 20,
      },
    })));
    expect(screen.getByRole("status", { name: "Ad skip notification" })).toBeInTheDocument();

    act(() => vi.advanceTimersByTime(9_840));
    expect(screen.getByRole("status", { name: "Ad skip notification" })).toHaveClass("is-leaving");
    act(() => vi.advanceTimersByTime(160));
    expect(screen.queryByRole("status", { name: "Ad skip notification" })).not.toBeInTheDocument();
    vi.useRealTimers();
  });
});
