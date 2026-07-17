import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { useState } from "react";
import type { ReactNode } from "react";
import { PlayerProvider } from "../player";
import { FakeAudio } from "../test/fakeAudio";
import { adRemovalSettings, episode, HttpError, installApi, page, type MockRoutes } from "../test/mockApi";
import type { Show } from "../types";
import type { EpisodeItem } from "../types";
import { AD_POLL_INTERVAL_MS, EpisodeRow } from "../components/EpisodeRow";
import { AD_SETTINGS_POLL_INTERVAL_MS } from "../views/RecentView";
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

const settings: MockRoutes = {
  "GET /api/settings": { speed: 1, autoplay: true },
  "GET /api/ad-removal/settings": adRemovalSettings({ enabled: false }),
};

describe("RecentView", () => {
  it("renders, marks played optimistically, loads more", async () => {
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

  it("has no Listen refresh control and empty state does not mention refresh button", async () => {
    installApi({
      ...settings,
      "GET /api/recent": page([]),
    });
    wrap(<RecentView />);
    await screen.findByText(/Nothing new/);

    expect(screen.queryByRole("button", { name: "Refresh feeds" })).not.toBeInTheDocument();
    expect(screen.getByText(/Nothing new/).textContent).not.toMatch(/refresh button/i);
  });

  it("toggles Listen episode sort by release date", async () => {
    installApi({
      ...settings,
      "GET /api/recent": page([
        episode({ id: 1, title: "Newest", published_at: 300 }),
        episode({ id: 2, title: "Middle", published_at: 200 }),
        episode({ id: 3, title: "Oldest", published_at: 100 }),
      ]),
    });
    const user = userEvent.setup();
    wrap(<RecentView />);

    await screen.findByText("Newest");
    const titles = () =>
      within(screen.getByRole("list"))
        .getAllByRole("listitem")
        .map((item) => within(item).getByText(/Newest|Middle|Oldest/).textContent);

    expect(titles()).toEqual(["Oldest", "Middle", "Newest"]);

    const sortToggle = screen.getByRole("switch", { name: "Oldest first Newest" });
    expect(sortToggle).toHaveAttribute("aria-checked", "true");

    await user.click(sortToggle);
    expect(titles()).toEqual(["Newest", "Middle", "Oldest"]);
    expect(sortToggle).toHaveAttribute("aria-checked", "false");

    await user.click(sortToggle);
    expect(titles()).toEqual(["Oldest", "Middle", "Newest"]);
    expect(sortToggle).toHaveAttribute("aria-checked", "true");
  });

  it("renders the Listen sort control as an Oldest first / Newest toggle", async () => {
    installApi({
      ...settings,
      "GET /api/recent": page([episode({ id: 1, title: "Newest", published_at: 300 })]),
    });
    wrap(<RecentView />);

    const sortToggle = await screen.findByRole("switch", { name: "Oldest first Newest" });
    expect(sortToggle).toHaveAttribute("aria-checked", "true");
    expect(sortToggle).toHaveTextContent("Oldest first");
    expect(sortToggle).toHaveTextContent("Newest");
    expect(sortToggle.querySelector(".sort-toggle-track")).toBeTruthy();
    expect(sortToggle.querySelector(".sort-toggle-thumb")).toBeTruthy();
    expect(sortToggle.querySelectorAll("svg")).toHaveLength(0);
  });

  it("starts playback when a row is tapped", async () => {
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
    installApi({ ...settings, "GET /api/recent": new HttpError(500, { error: "db exploded" }) });
    wrap(<RecentView />);
    await screen.findByText("db exploded");
  });

  it("shows compact ad-removal state and prepares or retries without gating playback", async () => {
    const { calls } = installApi({
      ...settings,
      "GET /api/recent": page([
        episode({
          id: 21,
          title: "Needs preparation",
          ad_removal_state: "unfiltered",
          ad_removal_action: "prepare",
        }),
        episode({
          id: 22,
          title: "Failed preparation",
          ad_removal_state: "failed",
          ad_removal_action: "retry",
        }),
      ]),
      "POST /api/episodes/21/ad-removal/prepare": { stage: "queued" },
      "POST /api/episodes/22/ad-removal/retry": { stage: "downloading" },
    });
    const user = userEvent.setup();
    wrap(<RecentView />);

    const prepareRow = (await screen.findByText("Needs preparation")).closest("li")!;
    expect(within(prepareRow).getByText("Unfiltered")).toBeInTheDocument();
    await user.click(within(prepareRow).getByRole("button", { name: "Prepare ad-free" }));
    expect(within(prepareRow).getByText("Queued")).toBeInTheDocument();

    const retryRow = screen.getByText("Failed preparation").closest("li")!;
    expect(within(retryRow).getByText("Failed")).toBeInTheDocument();
    await user.click(within(retryRow).getByRole("button", { name: "Retry ad-free preparation" }));
    expect(within(retryRow).getByText("Downloading")).toBeInTheDocument();

    expect(calls.some((call) => call.key === "POST /api/episodes/21/ad-removal/prepare")).toBe(true);
    expect(calls.some((call) => call.key === "POST /api/episodes/22/ad-removal/retry")).toBe(true);
  });

  it("shows a low-storage banner below the minimum-free threshold and hides it at/above or disabled", async () => {
    // Below threshold: banner is visible.
    const low = adRemovalSettings({
      enabled: true,
      minimum_free_bytes: 10_000_000_000,
      device_available_bytes: 9_500_000_000,
    });
    installApi({
      ...settings,
      "GET /api/ad-removal/settings": low,
      "GET /api/recent": page([episode({ id: 1, title: "Any Ep" })]),
    });
    wrap(<RecentView />);
    const banner = await screen.findByRole("alert");
    expect(banner).toBeInTheDocument();
    expect(banner.textContent).toMatch(/paused/i);
    expect(banner.textContent).toMatch(/9\.5 GB free/i);
    expect(banner.textContent).toMatch(/10 GB required/i);
  });

  it("hides the low-storage banner at the exact threshold", async () => {
    const exact = adRemovalSettings({
      enabled: true,
      minimum_free_bytes: 10_000_000_000,
      device_available_bytes: 10_000_000_000,
    });
    installApi({
      ...settings,
      "GET /api/ad-removal/settings": exact,
      "GET /api/recent": page([episode({ id: 1, title: "Any Ep" })]),
    });
    wrap(<RecentView />);
    await screen.findByText("Any Ep");
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });

  it("hides the low-storage banner when ad removal is disabled even with low space", async () => {
    const disabled = adRemovalSettings({
      enabled: false,
      minimum_free_bytes: 10_000_000_000,
      device_available_bytes: 1_000_000_000,
    });
    installApi({
      ...settings,
      "GET /api/ad-removal/settings": disabled,
      "GET /api/recent": page([episode({ id: 1, title: "Any Ep" })]),
    });
    wrap(<RecentView />);
    await screen.findByText("Any Ep");
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });

  it("does not break Listen when ad-removal settings fail to load", async () => {
    installApi({
      ...settings,
      "GET /api/ad-removal/settings": new HttpError(500, { error: "no backend" }),
      "GET /api/recent": page([episode({ id: 1, title: "Still Here" })]),
    });
    wrap(<RecentView />);
    await screen.findByText("Still Here");
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });

  it("hides the low-storage banner automatically when a later settings poll recovers above threshold", async () => {
    let current = adRemovalSettings({
      enabled: true,
      minimum_free_bytes: 10_000_000_000,
      device_available_bytes: 9_500_000_000,
    });
    installApi({
      ...settings,
      "GET /api/ad-removal/settings": () => current,
      "GET /api/recent": page([episode({ id: 1, title: "Any Ep" })]),
    });
    vi.useFakeTimers();
    wrap(<RecentView />);
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    expect(screen.getByRole("alert")).toBeInTheDocument();

    // A later poll reports threshold-satisfying free space.
    current = adRemovalSettings({
      enabled: true,
      minimum_free_bytes: 10_000_000_000,
      device_available_bytes: 12_000_000_000,
    });
    await act(async () => {
      await vi.advanceTimersByTimeAsync(AD_SETTINGS_POLL_INTERVAL_MS + 100);
    });
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });

  it("shows the low-storage banner automatically when a later settings poll falls below threshold", async () => {
    let current = adRemovalSettings({
      enabled: true,
      minimum_free_bytes: 10_000_000_000,
      device_available_bytes: 12_000_000_000,
    });
    installApi({
      ...settings,
      "GET /api/ad-removal/settings": () => current,
      "GET /api/recent": page([episode({ id: 1, title: "Any Ep" })]),
    });
    vi.useFakeTimers();
    wrap(<RecentView />);
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();

    // A later poll reports below-threshold free space.
    current = adRemovalSettings({
      enabled: true,
      minimum_free_bytes: 10_000_000_000,
      device_available_bytes: 8_000_000_000,
    });
    await act(async () => {
      await vi.advanceTimersByTimeAsync(AD_SETTINGS_POLL_INTERVAL_MS + 100);
    });
    const banner = screen.getByRole("alert");
    expect(banner).toBeInTheDocument();
    expect(banner.textContent).toMatch(/8 GB free/i);
  });

  it("keeps at most one settings request in flight when the first response is slow", async () => {
    let resolveFirst: () => void = () => {};
    const firstRequest = new Promise<void>((resolve) => {
      resolveFirst = resolve;
    });
    const { calls } = installApi({
      ...settings,
      "GET /api/ad-removal/settings": () => firstRequest.then(() => adRemovalSettings({ enabled: true })),
      "GET /api/recent": page([episode({ id: 1, title: "Any Ep" })]),
    });
    vi.useFakeTimers();
    wrap(<RecentView />);
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    const initialSettingsCalls = calls.filter((c) => c.key === "GET /api/ad-removal/settings").length;
    expect(initialSettingsCalls).toBe(1);

    // Advancing several poll boundaries must not start overlapping requests.
    await act(async () => {
      await vi.advanceTimersByTimeAsync(AD_SETTINGS_POLL_INTERVAL_MS * 4);
    });
    expect(calls.filter((c) => c.key === "GET /api/ad-removal/settings").length).toBe(1);

    // Resolving the slow request cleans up without leaking overlapping calls.
    await act(async () => {
      resolveFirst();
      await Promise.resolve();
    });
    expect(calls.filter((c) => c.key === "GET /api/ad-removal/settings").length).toBe(1);
  });

  it("shows granular ad-removal stage labels instead of generic Preparing", async () => {
    installApi({
      ...settings,
      "GET /api/recent": page([
        episode({
          id: 31,
          title: "Queued Ep",
          ad_removal_state: "preparing",
          ad_removal_stage: "queued",
        }),
        episode({
          id: 32,
          title: "Downloading Ep",
          ad_removal_state: "preparing",
          ad_removal_stage: "downloading",
        }),
        episode({
          id: 33,
          title: "Transcribing Ep",
          ad_removal_state: "preparing",
          ad_removal_stage: "transcribing",
        }),
        episode({
          id: 34,
          title: "Finding Ads Ep",
          ad_removal_state: "preparing",
          ad_removal_stage: "classifying",
        }),
      ]),
    });
    wrap(<RecentView />);

    const queuedRow = (await screen.findByText("Queued Ep")).closest("li")!;
    expect(within(queuedRow).getByText("Queued")).toBeInTheDocument();
    const downloadingRow = screen.getByText("Downloading Ep").closest("li")!;
    expect(within(downloadingRow).getByText("Downloading")).toBeInTheDocument();
    const transcribingRow = screen.getByText("Transcribing Ep").closest("li")!;
    expect(within(transcribingRow).getByText("Transcribing")).toBeInTheDocument();
    const findingRow = screen.getByText("Finding Ads Ep").closest("li")!;
    expect(within(findingRow).getByText("Finding ads")).toBeInTheDocument();
    // No generic "Preparing" labels should appear.
    expect(screen.queryAllByText(/^Preparing$/)).toHaveLength(0);
  });

  it("overrides active stage wording with blocking-reason labels", async () => {
    installApi({
      ...settings,
      "GET /api/recent": page([
        episode({
          id: 41,
          title: "Storage Blocked",
          ad_removal_state: "preparing",
          ad_removal_stage: "downloading",
          ad_removal_blocking_reason: "storage_limit",
        }),
        episode({
          id: 42,
          title: "Model Blocked",
          ad_removal_state: "preparing",
          ad_removal_stage: "transcribing",
          ad_removal_blocking_reason: "model_required",
        }),
        episode({
          id: 43,
          title: "Low Power",
          ad_removal_state: "preparing",
          ad_removal_stage: "classifying",
          ad_removal_blocking_reason: "low_power",
        }),
        episode({
          id: 44,
          title: "Thermal",
          ad_removal_state: "preparing",
          ad_removal_stage: "classifying",
          ad_removal_blocking_reason: "thermal_pressure",
        }),
        episode({
          id: 45,
          title: "Playback Active",
          ad_removal_state: "preparing",
          ad_removal_stage: "transcribing",
          ad_removal_blocking_reason: "playback_active",
        }),
      ]),
    });
    wrap(<RecentView />);

    const r1 = (await screen.findByText("Storage Blocked")).closest("li")!;
    expect(within(r1).getByText(/Paused.*low storage/i)).toBeInTheDocument();
    const r2 = screen.getByText("Model Blocked").closest("li")!;
    expect(within(r2).getByText(/Waiting for model/i)).toBeInTheDocument();
    const r3 = screen.getByText("Low Power").closest("li")!;
    expect(within(r3).getByText(/Paused.*low power/i)).toBeInTheDocument();
    const r4 = screen.getByText("Thermal").closest("li")!;
    expect(within(r4).getByText(/Paused.*thermal/i)).toBeInTheDocument();
    const r5 = screen.getByText("Playback Active").closest("li")!;
    expect(within(r5).getByText(/Paused during playback/i)).toBeInTheDocument();
  });

  it("shows an obvious Failed state with a prominent Retry button", async () => {
    installApi({
      ...settings,
      "GET /api/recent": page([
        episode({
          id: 51,
          title: "Broke Ep",
          ad_removal_state: "failed",
          ad_removal_action: "retry",
        }),
      ]),
    });
    wrap(<RecentView />);

    const row = (await screen.findByText("Broke Ep")).closest("li")!;
    expect(within(row).getByText("Failed")).toBeInTheDocument();
    const retry = within(row).getByRole("button", { name: "Retry ad-free preparation" });
    expect(retry).toBeInTheDocument();
    expect(retry).toHaveClass("ad-removal-retry");
    expect(retry.textContent).toMatch(/Retry/i);
  });

  it("uses the returned stage immediately after retry instead of generic Preparing", async () => {
    installApi({
      ...settings,
      "GET /api/recent": page([
        episode({
          id: 61,
          title: "Retry Stage Ep",
          ad_removal_state: "failed",
          ad_removal_action: "retry",
        }),
      ]),
      "POST /api/episodes/61/ad-removal/retry": { stage: "transcribing" },
    });
    const user = userEvent.setup();
    wrap(<RecentView />);

    const row = (await screen.findByText("Retry Stage Ep")).closest("li")!;
    await user.click(within(row).getByRole("button", { name: "Retry ad-free preparation" }));
    expect(within(row).getByText("Transcribing")).toBeInTheDocument();
    expect(within(row).queryByText(/^Preparing$/)).not.toBeInTheDocument();
  });

  it("maps a cancelled stage returned from retry to the Unfiltered user-facing state", async () => {
    installApi({
      ...settings,
      "GET /api/recent": page([
        episode({
          id: 62,
          title: "Cancel Stage Ep",
          ad_removal_state: "failed",
          ad_removal_action: "retry",
        }),
      ]),
      "POST /api/episodes/62/ad-removal/retry": { stage: "cancelled" },
    });
    const user = userEvent.setup();
    wrap(<RecentView />);

    const row = (await screen.findByText("Cancel Stage Ep")).closest("li")!;
    await user.click(within(row).getByRole("button", { name: "Retry ad-free preparation" }));
    expect(within(row).getByText("Unfiltered")).toBeInTheDocument();
    expect(within(row).queryByText(/^Preparing$/)).not.toBeInTheDocument();
  });

  it("polls episode detail and advances an active row to Ad-free automatically", async () => {
    const detail = episode({
      id: 71,
      title: "Active Ep",
      ad_removal_state: "preparing",
      ad_removal_stage: "downloading",
      ad_removal_action: null,
    });
    installApi({
      ...settings,
      "GET /api/recent": page([detail]),
      "GET /api/episodes/71": () => ({
        ...detail,
        ad_removal_state: "ad-free",
        ad_removal_stage: "ready",
        ad_removal_action: null,
        notes_html: "",
        archived_at: null,
      }),
    });
    vi.useFakeTimers();
    wrap(<RecentView />);
    // Flush the initial mount + recent fetch under fake timers.
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    const row = screen.getByText("Active Ep").closest("li")!;
    expect(within(row).getByText("Downloading")).toBeInTheDocument();

    // Advance past one poll boundary; the row should become Ad-free without navigation.
    await act(async () => {
      await vi.advanceTimersByTimeAsync(AD_POLL_INTERVAL_MS + 100);
    });
    expect(within(row).getByText("Ad-free")).toBeInTheDocument();
  });

  it("polls episode detail and surfaces Failed plus Retry automatically", async () => {
    const detail = episode({
      id: 72,
      title: "Will Fail Ep",
      ad_removal_state: "preparing",
      ad_removal_stage: "transcribing",
      ad_removal_action: null,
    });
    installApi({
      ...settings,
      "GET /api/recent": page([detail]),
      "GET /api/episodes/72": () => ({
        ...detail,
        ad_removal_state: "failed",
        ad_removal_stage: "failed",
        ad_removal_action: "retry",
        notes_html: "",
        archived_at: null,
      }),
    });
    vi.useFakeTimers();
    wrap(<RecentView />);
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    const row = screen.getByText("Will Fail Ep").closest("li")!;
    expect(within(row).getByText("Transcribing")).toBeInTheDocument();

    await act(async () => {
      await vi.advanceTimersByTimeAsync(AD_POLL_INTERVAL_MS + 100);
    });
    expect(within(row).getByText("Failed")).toBeInTheDocument();
    expect(within(row).getByRole("button", { name: "Retry ad-free preparation" })).toBeInTheDocument();
  });

  it("stops making detail requests after an active row polls to ready", async () => {
    const detail = episode({
      id: 73,
      title: "Goes Ready Ep",
      ad_removal_state: "preparing",
      ad_removal_stage: "downloading",
      ad_removal_action: null,
    });
    const { calls } = installApi({
      ...settings,
      "GET /api/recent": page([detail]),
      "GET /api/episodes/73": () => ({
        ...detail,
        ad_removal_state: "ad-free",
        ad_removal_stage: "ready",
        ad_removal_action: null,
        notes_html: "",
        archived_at: null,
      }),
    });
    vi.useFakeTimers();
    wrap(<RecentView />);
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    const row = screen.getByText("Goes Ready Ep").closest("li")!;
    expect(within(row).getByText("Downloading")).toBeInTheDocument();

    // First poll brings the row to Ad-free.
    await act(async () => {
      await vi.advanceTimersByTimeAsync(AD_POLL_INTERVAL_MS + 100);
    });
    expect(within(row).getByText("Ad-free")).toBeInTheDocument();
    const callsAfterReady = calls.filter((c) => c.key === "GET /api/episodes/73").length;
    expect(callsAfterReady).toBe(1);

    // Advancing several more poll boundaries must not start any further requests.
    await act(async () => {
      await vi.advanceTimersByTimeAsync(AD_POLL_INTERVAL_MS * 4);
    });
    expect(calls.filter((c) => c.key === "GET /api/episodes/73").length).toBe(1);
  });

  it("stops making detail requests after an active row polls to failed", async () => {
    const detail = episode({
      id: 76,
      title: "Goes Failed Ep",
      ad_removal_state: "preparing",
      ad_removal_stage: "transcribing",
      ad_removal_action: null,
    });
    const { calls } = installApi({
      ...settings,
      "GET /api/recent": page([detail]),
      "GET /api/episodes/76": () => ({
        ...detail,
        ad_removal_state: "failed",
        ad_removal_stage: "failed",
        ad_removal_action: "retry",
        notes_html: "",
        archived_at: null,
      }),
    });
    vi.useFakeTimers();
    wrap(<RecentView />);
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    const row = screen.getByText("Goes Failed Ep").closest("li")!;

    await act(async () => {
      await vi.advanceTimersByTimeAsync(AD_POLL_INTERVAL_MS + 100);
    });
    expect(within(row).getByText("Failed")).toBeInTheDocument();
    expect(calls.filter((c) => c.key === "GET /api/episodes/76").length).toBe(1);

    await act(async () => {
      await vi.advanceTimersByTimeAsync(AD_POLL_INTERVAL_MS * 4);
    });
    expect(calls.filter((c) => c.key === "GET /api/episodes/76").length).toBe(1);
  });

  it("makes no further poll calls after the row unmounts", async () => {
    const detail = episode({
      id: 77,
      title: "Unmount Me Ep",
      ad_removal_state: "preparing",
      ad_removal_stage: "downloading",
      ad_removal_action: null,
    });
    const { calls } = installApi({
      ...settings,
      "GET /api/recent": page([detail]),
      "GET /api/episodes/77": () => ({ ...detail, notes_html: "", archived_at: null }),
    });
    vi.useFakeTimers();
    const { unmount } = wrap(<RecentView />);
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    screen.getByText("Unmount Me Ep");
    const callsBeforeUnmount = calls.filter((c) => c.key === "GET /api/episodes/77").length;

    unmount();
    await act(async () => {
      await vi.advanceTimersByTimeAsync(AD_POLL_INTERVAL_MS * 4);
    });
    expect(calls.filter((c) => c.key === "GET /api/episodes/77").length).toBe(callsBeforeUnmount);
  });

  it("keeps at most one detail request in flight when the first response is slow", async () => {
    const detail = episode({
      id: 78,
      title: "Slow Detail Ep",
      ad_removal_state: "preparing",
      ad_removal_stage: "downloading",
      ad_removal_action: null,
    });
    let resolveFirst: () => void = () => {};
    const firstRequest = new Promise<void>((resolve) => {
      resolveFirst = resolve;
    });
    const { calls } = installApi({
      ...settings,
      "GET /api/recent": page([detail]),
      "GET /api/episodes/78": () => firstRequest.then(() => ({
        ...detail,
        notes_html: "",
        archived_at: null,
      })),
    });
    vi.useFakeTimers();
    wrap(<RecentView />);
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    screen.getByText("Slow Detail Ep");

    // The first poll fires at one interval and stays unresolved.
    await act(async () => {
      await vi.advanceTimersByTimeAsync(AD_POLL_INTERVAL_MS + 100);
    });
    expect(calls.filter((c) => c.key === "GET /api/episodes/78").length).toBe(1);

    // Advancing several more intervals must NOT start overlapping requests.
    await act(async () => {
      await vi.advanceTimersByTimeAsync(AD_POLL_INTERVAL_MS * 4);
    });
    expect(calls.filter((c) => c.key === "GET /api/episodes/78").length).toBe(1);

    // Resolving the slow request cleans up without throwing and without leaks.
    await act(async () => {
      resolveFirst();
      await Promise.resolve();
    });
    expect(calls.filter((c) => c.key === "GET /api/episodes/78").length).toBe(1);
  });

  it("does not replace the visible row state when an episode-detail poll errors", async () => {
    const detail = episode({
      id: 74,
      title: "Poll Error Ep",
      ad_removal_state: "preparing",
      ad_removal_stage: "downloading",
      ad_removal_action: null,
    });
    installApi({
      ...settings,
      "GET /api/recent": page([detail]),
      "GET /api/episodes/74": new HttpError(500, { error: "boom-transient" }),
    });
    vi.useFakeTimers();
    wrap(<RecentView />);
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    const row = screen.getByText("Poll Error Ep").closest("li")!;
    expect(within(row).getByText("Downloading")).toBeInTheDocument();

    await act(async () => {
      await vi.advanceTimersByTimeAsync(AD_POLL_INTERVAL_MS + 100);
    });
    // The visible state is unchanged; no error text replaces the stage label.
    expect(within(row).getByText("Downloading")).toBeInTheDocument();
    expect(within(row).queryByText(/boom-transient/)).not.toBeInTheDocument();
  });

  it("renders a cancelled ad-removal stage as Unfiltered", async () => {
    installApi({
      ...settings,
      "GET /api/recent": page([
        episode({
          id: 79,
          title: "Cancelled Ep",
          ad_removal_state: "unfiltered",
          ad_removal_stage: "cancelled",
          ad_removal_action: null,
        }),
      ]),
    });
    vi.useFakeTimers();
    wrap(<RecentView />);
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    const row = screen.getByText("Cancelled Ep").closest("li")!;
    expect(within(row).getByText("Unfiltered")).toBeInTheDocument();
    // A cancelled/Unfiltered row is terminal and must not poll.
  });
});

describe("PlayedView", () => {
  it("lists played episodes and unmarks", async () => {
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
    installApi({ ...settings, "GET /api/played": page([]) });
    wrap(<PlayedView />);
    await screen.findByText(/Episodes you mark played/);
  });
});

describe("SearchView", () => {
  it("searches both directories and renders results", async () => {
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
    installApi({ ...settings, "GET /api/shows": [show()] });
    const user = userEvent.setup();
    wrap(<ShowsView />);
    await user.click(await screen.findByText("Alpha Show"));
    expect(window.location.hash).toBe("#/shows/5");
  });

  it("opens settings from the gear", async () => {
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

  it("adds an episode to Listen from the catalog", async () => {
    const { calls } = installApi({
      ...settings,
      "GET /api/shows/5": {
        show: show(),
        episodes: page([episode({ id: 11, title: "Archived Ep", played_at: 1_700_000_000 })]),
      },
      "DELETE /api/episodes/11/played": null,
    });
    wrap(<ShowDetailView showId={5} />);
    await screen.findByText("Archived Ep");

    vi.useFakeTimers();
    fireEvent.click(screen.getByRole("button", { name: "Add to Listen" }));
    expect(calls.some((c) => c.key === "DELETE /api/episodes/11/played")).toBe(true);
    await act(async () => {
      await Promise.resolve();
    });
    const confirmation = screen.getByRole("status", { name: "Add to Listen confirmation" });
    expect(screen.getByText("Archived Ep added to Listen")).toBeInTheDocument();
    expect(confirmation).toHaveClass("is-visible");

    await act(async () => {
      vi.advanceTimersByTime(3000);
    });
    expect(confirmation).toHaveClass("is-leaving");

    await act(async () => {
      vi.advanceTimersByTime(180);
    });
    expect(screen.queryByRole("status", { name: "Add to Listen confirmation" })).not.toBeInTheDocument();
  });

  it("searches within the selected show", async () => {
    const { calls } = installApi({
      ...settings,
      "GET /api/shows/5": {
        show: show(),
        episodes: page([episode({ id: 11, title: "Noise Episode" })]),
      },
      "GET /api/shows/5/search": (url: URL) => {
        return url.searchParams.get("q") === "quant"
          ? page([episode({ id: 12, title: "Quantum Episode" })])
          : page([]);
      },
    });
    const user = userEvent.setup();
    wrap(<ShowDetailView showId={5} />);
    await screen.findByText("Noise Episode");

    await user.type(screen.getByRole("searchbox", { name: "Search this show" }), "quant");

    await screen.findByText("Quantum Episode");
    expect(screen.queryByText("Noise Episode")).not.toBeInTheDocument();
    expect(calls.some((c) => c.key === "GET /api/shows/5/search")).toBe(true);
  });
});

describe("EpisodeRow polling", () => {
  const statefulSetters = new Map<number, (ep: EpisodeItem) => void>();

  function rowFor(item: EpisodeItem) {
    return (
      <EpisodeRow
        item={item}
        onPlay={() => {}}
        actionLabel="Mark played"
        onAction={() => {}}
      />
    );
  }

  // A stateful wrapper lets the test drive a same-id prop update from within an
  // async act so it can race an in-flight poll response before React flushes the
  // prop-sync state rerender (which RTL's synchronous rerender would otherwise
  // close immediately).
  function StatefulRow({ initial }: { initial: EpisodeItem }) {
    const [ep, setEp] = useState(initial);
    statefulSetters.set(initial.id, setEp);
    return rowFor(ep);
  }

  it("an in-flight poll must not overwrite newer same-id props", async () => {
    const initial = episode({
      id: 81,
      title: "Race Ep",
      ad_removal_state: "preparing",
      ad_removal_stage: "downloading",
      ad_removal_action: null,
      ad_removal_blocking_reason: null,
    });
    // The poll response is unresolved and, when resolved, returns the STALE older state.
    let resolvePoll: () => void = () => {};
    const pollResponse = new Promise<void>((resolve) => {
      resolvePoll = resolve;
    });
    installApi({
      ...settings,
      "GET /api/episodes/81": () =>
        pollResponse.then(() => ({
          ...initial,
          ad_removal_state: "preparing",
          ad_removal_stage: "downloading",
          ad_removal_action: null,
          ad_removal_blocking_reason: null,
          notes_html: "",
          archived_at: null,
        })),
    });
    vi.useFakeTimers();
    const { rerender } = wrap(rowFor(initial));
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    const row = screen.getByText("Race Ep").closest("li")!;
    expect(within(row).getByText("Downloading")).toBeInTheDocument();

    // Fire the first poll, which starts an unresolved detail request.
    await act(async () => {
      await vi.advanceTimersByTimeAsync(AD_POLL_INTERVAL_MS + 100);
    });

    // Parent advances the same episode id to a newer stage + blocking reason.
    const newer: EpisodeItem = {
      ...initial,
      ad_removal_state: "preparing",
      ad_removal_stage: "transcribing",
      ad_removal_action: null,
      ad_removal_blocking_reason: "low_power",
    };
    await act(async () => {
      rerender(<PlayerProvider>{rowFor(newer)}</PlayerProvider>);
    });
    expect(within(row).getByText(/Paused.*low power/i)).toBeInTheDocument();

    // Now resolve the OLD poll response returning the stale downloading state.
    await act(async () => {
      resolvePoll();
      await Promise.resolve();
    });
    // The stale response must NOT regress the UI back to Downloading.
    expect(within(row).queryByText("Downloading")).not.toBeInTheDocument();
    expect(within(row).getByText(/Paused.*low power/i)).toBeInTheDocument();
  });

  it("a same-id coarse-state-only prop update to terminal invalidates a stale in-flight poll", async () => {
    const initial = episode({
      id: 91,
      title: "Coarse Race Ep",
      ad_removal_state: "preparing",
      ad_removal_stage: "downloading",
      ad_removal_action: null,
      ad_removal_blocking_reason: null,
    });
    // The poll response is unresolved and, when resolved, returns the STALE older state.
    let resolvePoll: () => void = () => {};
    const pollResponse = new Promise<void>((resolve) => {
      resolvePoll = resolve;
    });
    const { calls } = installApi({
      ...settings,
      "GET /api/episodes/91": () =>
        pollResponse.then(() => ({
          ...initial,
          ad_removal_state: "preparing",
          ad_removal_stage: "downloading",
          ad_removal_action: null,
          ad_removal_blocking_reason: null,
          notes_html: "",
          archived_at: null,
        })),
    });
    vi.useFakeTimers();
    wrap(<StatefulRow initial={initial} />);
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    const row = screen.getByText("Coarse Race Ep").closest("li")!;
    expect(within(row).getByText("Downloading")).toBeInTheDocument();

    // Fire the first poll, which starts an unresolved detail request.
    await act(async () => {
      await vi.advanceTimersByTimeAsync(AD_POLL_INTERVAL_MS + 100);
    });
    expect(calls.filter((c) => c.key === "GET /api/episodes/91").length).toBe(1);

    // Parent advances ONLY the coarse state to terminal (ad-free), leaving the
    // nullable granular/action fields otherwise unchanged. The stale poll is
    // resolved in the SAME async flush as the prop commit so it races the
    // prop-sync state rerender; the in-flight generation must already be
    // invalidated by the coarse-state prop dependency.
    const newer: EpisodeItem = {
      ...initial,
      ad_removal_state: "ad-free",
      ad_removal_stage: "downloading",
      ad_removal_action: null,
      ad_removal_blocking_reason: null,
    };
    const setEp = statefulSetters.get(91)!;
    // Drive the prop update and resolve the stale poll in the same async flush
    // so the stale response races the prop-sync state rerender. The in-flight
    // generation must already be invalidated by the coarse-state prop dependency.
    await act(async () => {
      setEp(newer);
      resolvePoll();
      for (let i = 0; i < 8; i++) await Promise.resolve();
    });
    // The stale response must NOT regress the terminal UI back to Downloading/Preparing.
    expect(within(row).queryByText("Downloading")).not.toBeInTheDocument();
    expect(within(row).queryByText(/^Preparing$/)).not.toBeInTheDocument();
    expect(within(row).getByText("Ad-free")).toBeInTheDocument();

    // The terminal row must not restart polling: advancing several more poll
    // boundaries causes no additional detail requests.
    await act(async () => {
      await vi.advanceTimersByTimeAsync(AD_POLL_INTERVAL_MS * 4);
    });
    expect(calls.filter((c) => c.key === "GET /api/episodes/91").length).toBe(1);
    statefulSetters.delete(91);
  });
});
