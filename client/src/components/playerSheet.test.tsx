import { act, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it } from "vitest";
import { PlayerProvider, usePlayer } from "../player";
import { FakeAudio } from "../test/fakeAudio";
import { episode, installApi, loggedIn } from "../test/mockApi";
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
  loggedIn();
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

    // re-expand
    await user.click(mini);
    expect(screen.getByRole("dialog", { name: "Player" })).toBeInTheDocument();
  });

  it("speed chips set the playback rate", async () => {
    const { user } = setup();
    await user.click(screen.getByText("start"));
    await screen.findByRole("dialog", { name: "Player" });

    await user.click(screen.getByRole("button", { name: "2.5×" }));
    expect(FakeAudio.last().playbackRate).toBe(2.5);
    expect(screen.getByRole("button", { name: "2.5×" })).toHaveClass("active");
  });

  it("scrubber seeks and time labels track", async () => {
    const { user } = setup();
    await user.click(screen.getByText("start"));
    await screen.findByRole("dialog", { name: "Player" });
    const audio = FakeAudio.last();
    act(() => audio.emitLoadedMetadata(600));

    const scrubber = screen.getByRole("slider", { name: "Seek" });
    // range inputs: change event with a value
    act(() => {
      (scrubber as HTMLInputElement).value = "120";
      scrubber.dispatchEvent(new Event("input", { bubbles: true }));
      scrubber.dispatchEvent(new Event("change", { bubbles: true }));
    });
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
});
