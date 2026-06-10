import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import type { ReactNode } from "react";
import { PlayerProvider } from "../player";
import { FakeAudio } from "../test/fakeAudio";
import { episode, HttpError, installApi, loggedIn, page, type MockRoutes } from "../test/mockApi";
import type { Show } from "../types";
import { PlayedView } from "./PlayedView";
import { RecentView } from "./RecentView";
import { SearchView } from "./SearchView";
import { ShowDetailView } from "./ShowDetailView";
import { ShowsView } from "./ShowsView";

function wrap(ui: ReactNode) {
  return render(<PlayerProvider>{ui}</PlayerProvider>);
}

function show(overrides: Partial<Show> = {}): Show {
  return {
    id: 5,
    feed_url: "https://x.example/feed",
    title: "Alpha Show",
    description: "<p>About alpha</p>",
    image_url: "",
    site_url: "",
    episode_count: 12,
    unplayed_count: 3,
    ...overrides,
  };
}

const settings: MockRoutes = { "GET /api/settings": { speed: 1, autoplay: true } };

describe("RecentView", () => {
  it("renders, marks played optimistically, loads more", async () => {
    loggedIn();
    const ep1 = episode({ id: 1, title: "First" });
    const ep2 = episode({ id: 2, title: "Second" });
    const ep3 = episode({ id: 3, title: "Third" });
    let recentCalls = 0;
    let ep1Played = false;
    const { calls } = installApi({
      ...settings,
      "GET /api/recent": (url: URL) => {
        recentCalls += 1;
        if (url.searchParams.get("offset") === "50") return page([ep3]);
        return ep1Played ? page([ep2], 50) : page([ep1, ep2], 50);
      },
      "POST /api/episodes/1/played": () => {
        ep1Played = true;
        return null;
      },
    });
    const user = userEvent.setup();
    wrap(<RecentView />);

    await screen.findByText("First");
    expect(screen.getByText("Second")).toBeInTheDocument();

    // load more appends
    await user.click(screen.getByRole("button", { name: "Load more" }));
    await screen.findByText("Third");

    // mark played: row vanishes immediately, then the changed event reloads
    const row = screen.getByText("First").closest("li")!;
    await user.click(within(row).getByRole("button", { name: "Mark played" }));
    await waitFor(() => expect(screen.queryByText("First")).not.toBeInTheDocument());
    expect(calls.some((c) => c.key === "POST /api/episodes/1/played")).toBe(true);
    await waitFor(() => expect(recentCalls).toBeGreaterThanOrEqual(3)); // initial + loadMore + reload
  });

  it("shows the empty state and triggers refresh", async () => {
    loggedIn();
    const { calls } = installApi({
      ...settings,
      "GET /api/recent": page([]),
      "POST /api/refresh": { refreshed: 2, errors: 0 },
    });
    const user = userEvent.setup();
    wrap(<RecentView />);
    await screen.findByText(/Nothing new/);

    await user.click(screen.getByRole("button", { name: "Refresh feeds" }));
    await waitFor(() => expect(calls.some((c) => c.key === "POST /api/refresh")).toBe(true));
  });

  it("starts playback when a row is tapped", async () => {
    loggedIn();
    installApi({
      ...settings,
      "GET /api/recent": page([episode({ id: 7, title: "Tap me", audio_url: "https://h.example/7.mp3" })]),
      "GET /api/episodes/7": { ...episode({ id: 7 }), notes_html: "", archived_at: null },
      "PUT /api/episodes/7/position": null,
    });
    const user = userEvent.setup();
    wrap(<RecentView />);
    await user.click(await screen.findByText("Tap me"));
    expect(FakeAudio.last().src).toBe("https://h.example/7.mp3");
  });

  it("surfaces list errors", async () => {
    loggedIn();
    installApi({ ...settings, "GET /api/recent": new HttpError(500, { error: "db exploded" }) });
    wrap(<RecentView />);
    await screen.findByText("db exploded");
  });
});

describe("PlayedView", () => {
  it("lists played episodes and unmarks", async () => {
    loggedIn();
    const { calls } = installApi({
      ...settings,
      "GET /api/played": page([episode({ id: 4, title: "Old One", played_at: 1_750_000_100 })]),
      "DELETE /api/episodes/4/played": null,
    });
    const user = userEvent.setup();
    wrap(<PlayedView />);
    await screen.findByText("Old One");

    await user.click(screen.getByRole("button", { name: "Mark unplayed" }));
    await waitFor(() =>
      expect(calls.some((c) => c.key === "DELETE /api/episodes/4/played")).toBe(true),
    );
  });

  it("shows its empty state", async () => {
    loggedIn();
    installApi({ ...settings, "GET /api/played": page([]) });
    wrap(<PlayedView />);
    await screen.findByText(/Episodes you mark played/);
  });
});

describe("SearchView", () => {
  it("searches both directories and renders results", async () => {
    loggedIn();
    const { calls } = installApi({
      ...settings,
      "GET /api/search": {
        directory_configured: true,
        podcasts: [
          { title: "Found Pod", author: "Au", feed_url: "https://f.example/rss", image_url: "", description: "", subscribed: false },
          { title: "Already Sub", author: "Au2", feed_url: "https://g.example/rss", image_url: "", description: "", subscribed: true },
        ],
        episodes: [episode({ id: 8, title: "Matching Episode" })],
      },
      "POST /api/shows": show({ title: "Found Pod" }),
    });
    const user = userEvent.setup();
    wrap(<SearchView />);

    await user.type(screen.getByRole("searchbox"), "found");
    await user.click(screen.getByRole("button", { name: "Search" }));

    await screen.findByText("Found Pod");
    expect(screen.getByText("Matching Episode")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Subscribed" })).toBeDisabled();
    expect(calls.find((c) => c.key === "GET /api/search")?.url.searchParams.get("q")).toBe("found");

    // subscribe the unsubscribed one
    await user.click(screen.getByRole("button", { name: "Subscribe" }));
    await screen.findAllByRole("button", { name: "Subscribed" });
    const sub = calls.find((c) => c.key === "POST /api/shows");
    expect(JSON.parse(String(sub?.init.body))).toEqual({ feed_url: "https://f.example/rss" });
  });

  it("shows subscribe errors inline and recovers", async () => {
    loggedIn();
    installApi({
      ...settings,
      "GET /api/search": {
        directory_configured: true,
        podcasts: [{ title: "Broken Pod", author: "", feed_url: "https://b.example/rss", image_url: "", description: "", subscribed: false }],
        episodes: [],
      },
      "POST /api/shows": new HttpError(502, { error: "upstream error: timeout" }),
    });
    const user = userEvent.setup();
    wrap(<SearchView />);
    await user.type(screen.getByRole("searchbox"), "broken");
    await user.click(screen.getByRole("button", { name: "Search" }));
    await user.click(await screen.findByRole("button", { name: "Subscribe" }));
    await screen.findByText(/upstream error/);
    expect(screen.getByRole("button", { name: "Subscribe" })).toBeEnabled();
  });

  it("clears the input with the × button in one tap", async () => {
    loggedIn();
    installApi({ ...settings });
    const user = userEvent.setup();
    wrap(<SearchView />);
    const box = screen.getByRole("searchbox");
    expect(screen.queryByRole("button", { name: "Clear search" })).not.toBeInTheDocument();
    await user.type(box, "quantum");
    await user.click(screen.getByRole("button", { name: "Clear search" }));
    expect(box).toHaveValue("");
    expect(box).toHaveFocus();
    expect(screen.queryByRole("button", { name: "Clear search" })).not.toBeInTheDocument();
  });

  it("explains when the directory is not configured", async () => {
    loggedIn();
    installApi({
      ...settings,
      "GET /api/search": { directory_configured: false, podcasts: [], episodes: [] },
    });
    const user = userEvent.setup();
    wrap(<SearchView />);
    await user.type(screen.getByRole("searchbox"), "x");
    await user.click(screen.getByRole("button", { name: "Search" }));
    await screen.findByText(/Directory search is off/);
  });
});

describe("ShowsView", () => {
  it("lists shows and navigates into one", async () => {
    loggedIn();
    installApi({ ...settings, "GET /api/shows": [show()] });
    const user = userEvent.setup();
    wrap(<ShowsView />);
    await user.click(await screen.findByText("Alpha Show"));
    expect(window.location.hash).toBe("#/shows/5");
  });

  it("opens settings from the gear", async () => {
    loggedIn();
    installApi({ ...settings, "GET /api/shows": [] });
    const user = userEvent.setup();
    wrap(<ShowsView />);
    await screen.findByText(/No subscriptions yet/);
    await user.click(screen.getByRole("button", { name: "Settings" }));
    expect(screen.getByRole("dialog", { name: "Settings" })).toBeInTheDocument();
  });
});

describe("ShowDetailView", () => {
  it("renders episodes and unsubscribes with confirmation", async () => {
    loggedIn();
    const { calls } = installApi({
      ...settings,
      "GET /api/shows/5": {
        show: show(),
        episodes: page([episode({ id: 11, title: "Catalog Ep", played_at: 1_700_000_000 })]),
      },
      "DELETE /api/shows/5": null,
    });
    vi.spyOn(window, "confirm").mockReturnValue(true);
    const user = userEvent.setup();
    wrap(<ShowDetailView showId={5} />);

    await screen.findByText("Catalog Ep");
    expect(screen.getByText(/12 episodes · 3 unplayed/)).toBeInTheDocument();
    expect(screen.getByText("About alpha")).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "Unsubscribe" }));
    await waitFor(() => expect(calls.some((c) => c.key === "DELETE /api/shows/5")).toBe(true));
    expect(window.location.hash).toBe("#/shows");
  });

  it("does nothing when unsubscribe is cancelled", async () => {
    loggedIn();
    const { calls } = installApi({
      ...settings,
      "GET /api/shows/5": { show: show(), episodes: page([]) },
    });
    vi.spyOn(window, "confirm").mockReturnValue(false);
    const user = userEvent.setup();
    wrap(<ShowDetailView showId={5} />);
    await screen.findByRole("button", { name: "Unsubscribe" });
    await user.click(screen.getByRole("button", { name: "Unsubscribe" }));
    expect(calls.some((c) => c.key === "DELETE /api/shows/5")).toBe(false);
  });

  it("toggles played state from the catalog", async () => {
    loggedIn();
    const { calls } = installApi({
      ...settings,
      "GET /api/shows/5": {
        show: show(),
        episodes: page([episode({ id: 11, title: "Unplayed Ep" })]),
      },
      "POST /api/episodes/11/played": null,
    });
    const user = userEvent.setup();
    wrap(<ShowDetailView showId={5} />);
    await screen.findByText("Unplayed Ep");
    await user.click(screen.getByRole("button", { name: "Mark played" }));
    await waitFor(() =>
      expect(calls.some((c) => c.key === "POST /api/episodes/11/played")).toBe(true),
    );
  });
});
