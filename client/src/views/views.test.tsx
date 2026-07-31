import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import type { ReactNode } from "react";
import { PlayerProvider } from "../player";
import { installReliableTapActivation } from "../reliableTap";
import { FakeAudio } from "../test/fakeAudio";
import { adRemovalSettings, adRemovalStatusItem, adRemovalStatuses, episode, HttpError, installApi, page, type MockRoutes } from "../test/mockApi";
import type { Show } from "../types";
import type { EpisodeItem } from "../types";
import { AD_SETTINGS_POLL_INTERVAL_MS, AD_STATUS_POLL_INTERVAL_MS } from "../views/RecentView";
import { PlayedView } from "./PlayedView";
import { RecentView } from "./RecentView";
import { SearchView } from "./SearchView";
import { ShowDetailView } from "./ShowDetailView";
import { ShowsView } from "./ShowsView";
import { FollowsView } from "./FollowsView";

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
  "GET /api/refresh-status": {
    last_attempt_at: null,
    last_success_at: null,
    last_source: null,
    last_refreshed: 0,
    last_errors: 0,
  },
};

describe("RecentView", () => {
  it("shows the latest successful feed refresh above the footer nav and updates it", async () => {
    let statusCalls = 0;
    installApi({
      ...settings,
      "GET /api/recent": page([episode()]),
      "GET /api/refresh-status": () => ({
        is_refreshing: statusCalls === 0,
        last_attempt_at: 1_784_071_860,
        last_success_at: statusCalls++ === 0 ? 1_784_071_800 : 1_784_075_400,
        last_source: "foreground",
        last_refreshed: 1,
        last_errors: 0,
      }),
    });
    wrap(<RecentView />);

    const initial = await screen.findByText(/Latest feed refresh:/);
    const initialText = initial.textContent;
    expect(initial).toHaveClass("feed-refresh-status");
    expect(initialText).toMatch(/^Refreshing feeds/);

    window.dispatchEvent(new Event("pods-episodes-changed"));
    await waitFor(() => expect(screen.getByText(/^Latest feed refresh:/).textContent).not.toBe(initialText));
    expect(screen.getByText(/^Latest feed refresh:/).textContent).not.toMatch(/^Refreshing feeds/);
  });

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

  it("does not mark the newly exposed row played during the same rapid interaction", async () => {
    const first = episode({ id: 1, title: "First" });
    const exposed = episode({ id: 2, title: "Exposed after removal" });
    const { calls } = installApi({
      ...settings,
      "GET /api/recent": page([first, exposed]),
      "POST /api/episodes/1/played": null,
      "POST /api/episodes/2/played": null,
    });
    wrap(<RecentView />);

    await screen.findByText("First");
    fireEvent.click(within(screen.getByText("First").closest("li")!).getByRole("button", { name: "Mark played" }));
    fireEvent.click(
      within(screen.getByText("Exposed after removal").closest("li")!).getByRole("button", {
        name: "Mark played",
      }),
    );

    expect(calls.filter((call) => call.key === "POST /api/episodes/1/played")).toHaveLength(1);
    expect(calls.filter((call) => call.key === "POST /api/episodes/2/played")).toHaveLength(0);
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

  it("marks episode titles for full, non-ellipsized display", async () => {
    installApi({ ...settings, "GET /api/recent": page([episode({ title: "A very long episode title" })]) });
    wrap(<RecentView />);

    expect(await screen.findByText("A very long episode title")).toHaveClass("episode-title-full");
  });

  it("updates the Listen row progress from live playback", async () => {
    installApi({
      ...settings,
      "GET /api/recent": page([
        episode({
          id: 8,
          title: "Live progress",
          audio_url: "https://h.example/8.mp3",
          duration_secs: 100,
          position_secs: 0,
        }),
      ]),
      "GET /api/episodes/8": { ...episode({ id: 8 }), notes_html: "", archived_at: null },
      "PUT /api/episodes/8/position": null,
    });
    const user = userEvent.setup();
    wrap(<RecentView />);
    const row = (await screen.findByText("Live progress")).closest("li")!;

    await user.click(within(row).getByRole("button", { name: /Live progress/ }));
    act(() => FakeAudio.last().emitTime(25));

    expect(within(row).getByRole("progressbar")).toHaveAttribute("aria-valuenow", "25");
    expect(row).toHaveTextContent("1m left");
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

  it("renders the Ad-free badge in the same muted color as episode metadata", async () => {
    installApi({
      ...settings,
      "GET /api/recent": page([
        episode({ id: 23, title: "Prepared episode", ad_removal_state: "ad-free" }),
      ]),
    });
    wrap(<RecentView />);

    expect(await screen.findByText("Ad-free")).toHaveStyle({ color: "var(--text-dim)" });
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

  it("one batch status request covers multiple active rows and makes no per-row detail calls", async () => {
    const active1 = episode({
      id: 301,
      title: "Batch A",
      ad_removal_state: "preparing",
      ad_removal_stage: "downloading",
      ad_removal_action: null,
    });
    const active2 = episode({
      id: 302,
      title: "Batch B",
      ad_removal_state: "preparing",
      ad_removal_stage: "transcribing",
      ad_removal_action: null,
    });
    const terminal = episode({
      id: 303,
      title: "Batch Done",
      ad_removal_state: "ad-free",
      ad_removal_stage: "ready",
      ad_removal_action: null,
    });
    const { calls } = installApi({
      ...settings,
      "GET /api/recent": page([active1, active2, terminal]),
      "GET /api/ad-removal/statuses": () =>
        adRemovalStatuses([
          adRemovalStatusItem(active1),
          adRemovalStatusItem(active2),
        ]),
    });
    vi.useFakeTimers();
    wrap(<RecentView />);
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    screen.getByText("Batch A");
    screen.getByText("Batch B");

    // Advance past one poll boundary: exactly one batch request covers both rows.
    await act(async () => {
      await vi.advanceTimersByTimeAsync(AD_STATUS_POLL_INTERVAL_MS + 100);
    });
    const statusCalls = calls.filter((c) => c.key === "GET /api/ad-removal/statuses");
    expect(statusCalls).toHaveLength(1);
    const ids = statusCalls[0].url.searchParams.get("episode_ids")?.split(",").map(Number);
    expect(ids).toEqual(expect.arrayContaining([301, 302]));
    expect(ids).not.toContain(303);

    // No per-row episode-detail calls should ever occur for status polling.
    expect(calls.filter((c) => /^GET \/api\/episodes\/\d+$/.test(c.key))).toHaveLength(0);
  });

  it("batch polling advances an active row to Ad-free automatically", async () => {
    const active = episode({
      id: 71,
      title: "Active Ep",
      ad_removal_state: "preparing",
      ad_removal_stage: "downloading",
      ad_removal_action: null,
    });
    let next = active;
    installApi({
      ...settings,
      "GET /api/recent": page([active]),
      "GET /api/ad-removal/statuses": () =>
        adRemovalStatuses([
          adRemovalStatusItem(next),
        ]),
    });
    vi.useFakeTimers();
    wrap(<RecentView />);
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    const row = screen.getByText("Active Ep").closest("li")!;
    expect(within(row).getByText("Downloading")).toBeInTheDocument();

    next = { ...active, ad_removal_state: "ad-free", ad_removal_stage: "ready", ad_removal_action: null };
    await act(async () => {
      await vi.advanceTimersByTimeAsync(AD_STATUS_POLL_INTERVAL_MS + 100);
    });
    expect(within(row).getByText("Ad-free")).toBeInTheDocument();
  });

  it("batch polling surfaces Failed plus Retry automatically", async () => {
    const active = episode({
      id: 72,
      title: "Will Fail Ep",
      ad_removal_state: "preparing",
      ad_removal_stage: "transcribing",
      ad_removal_action: null,
    });
    let next = active;
    installApi({
      ...settings,
      "GET /api/recent": page([active]),
      "GET /api/ad-removal/statuses": () =>
        adRemovalStatuses([adRemovalStatusItem(next)]),
    });
    vi.useFakeTimers();
    wrap(<RecentView />);
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    const row = screen.getByText("Will Fail Ep").closest("li")!;
    expect(within(row).getByText("Transcribing")).toBeInTheDocument();

    next = { ...active, ad_removal_state: "failed", ad_removal_stage: "failed", ad_removal_action: "retry" };
    await act(async () => {
      await vi.advanceTimersByTimeAsync(AD_STATUS_POLL_INTERVAL_MS + 100);
    });
    expect(within(row).getByText("Failed")).toBeInTheDocument();
    expect(within(row).getByRole("button", { name: "Retry ad-free preparation" })).toBeInTheDocument();
  });

  it("stops batch polling after all visible rows reach terminal status", async () => {
    const active = episode({
      id: 73,
      title: "Goes Ready Ep",
      ad_removal_state: "preparing",
      ad_removal_stage: "downloading",
      ad_removal_action: null,
    });
    let next = active;
    const { calls } = installApi({
      ...settings,
      "GET /api/recent": page([active]),
      "GET /api/ad-removal/statuses": () => adRemovalStatuses([adRemovalStatusItem(next)]),
    });
    vi.useFakeTimers();
    wrap(<RecentView />);
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    const row = screen.getByText("Goes Ready Ep").closest("li")!;
    expect(within(row).getByText("Downloading")).toBeInTheDocument();

    next = { ...active, ad_removal_state: "ad-free", ad_removal_stage: "ready", ad_removal_action: null };
    await act(async () => {
      await vi.advanceTimersByTimeAsync(AD_STATUS_POLL_INTERVAL_MS + 100);
    });
    expect(within(row).getByText("Ad-free")).toBeInTheDocument();
    const callsAfterReady = calls.filter((c) => c.key === "GET /api/ad-removal/statuses").length;
    expect(callsAfterReady).toBe(1);

    await act(async () => {
      await vi.advanceTimersByTimeAsync(AD_STATUS_POLL_INTERVAL_MS * 4);
    });
    expect(calls.filter((c) => c.key === "GET /api/ad-removal/statuses").length).toBe(1);
  });

  it("keeps at most one batch status request in flight when the first response is slow", async () => {
    const active = episode({
      id: 78,
      title: "Slow Batch Ep",
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
      "GET /api/recent": page([active]),
      "GET /api/ad-removal/statuses": () =>
        firstRequest.then(() => adRemovalStatuses([adRemovalStatusItem(active)])),
    });
    vi.useFakeTimers();
    wrap(<RecentView />);
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    screen.getByText("Slow Batch Ep");

    await act(async () => {
      await vi.advanceTimersByTimeAsync(AD_STATUS_POLL_INTERVAL_MS + 100);
    });
    expect(calls.filter((c) => c.key === "GET /api/ad-removal/statuses").length).toBe(1);

    await act(async () => {
      await vi.advanceTimersByTimeAsync(AD_STATUS_POLL_INTERVAL_MS * 4);
    });
    expect(calls.filter((c) => c.key === "GET /api/ad-removal/statuses").length).toBe(1);

    await act(async () => {
      resolveFirst();
      await Promise.resolve();
    });
    expect(calls.filter((c) => c.key === "GET /api/ad-removal/statuses").length).toBe(1);
  });

  it("recovers from a transient batch poll error on a later completion-scheduled cycle without overlap", async () => {
    const active = episode({
      id: 74,
      title: "Poll Error Ep",
      ad_removal_state: "preparing",
      ad_removal_stage: "downloading",
      ad_removal_action: null,
    });
    let attempt = 0;
    const { calls } = installApi({
      ...settings,
      "GET /api/recent": page([active]),
      "GET /api/ad-removal/statuses": () => {
        attempt += 1;
        // First cycle fails; a later cycle succeeds and advances the row.
        if (attempt === 1) return new HttpError(500, { error: "boom-transient" });
        return adRemovalStatuses([
          adRemovalStatusItem({
            id: 74,
            ad_removal_state: "ad-free",
            ad_removal_stage: "ready",
            ad_removal_action: null,
            ad_removal_blocking_reason: null,
          }),
        ]);
      },
    });
    vi.useFakeTimers();
    wrap(<RecentView />);
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    const row = screen.getByText("Poll Error Ep").closest("li")!;
    expect(within(row).getByText("Downloading")).toBeInTheDocument();

    // First cycle fails: visible state is preserved, no error text shown.
    await act(async () => {
      await vi.advanceTimersByTimeAsync(AD_STATUS_POLL_INTERVAL_MS + 100);
    });
    expect(within(row).getByText("Downloading")).toBeInTheDocument();
    expect(within(row).queryByText(/boom-transient/)).not.toBeInTheDocument();
    const callsAfterError = calls.filter((c) => c.key === "GET /api/ad-removal/statuses").length;
    expect(callsAfterError).toBe(1);

    // No overlapping request fires while waiting for the next cycle.
    await act(async () => {
      await vi.advanceTimersByTimeAsync(AD_STATUS_POLL_INTERVAL_MS / 2);
    });
    expect(calls.filter((c) => c.key === "GET /api/ad-removal/statuses").length).toBe(callsAfterError);

    // A later completion-scheduled cycle retries successfully and updates the row.
    await act(async () => {
      await vi.advanceTimersByTimeAsync(AD_STATUS_POLL_INTERVAL_MS);
    });
    expect(calls.filter((c) => c.key === "GET /api/ad-removal/statuses").length).toBeGreaterThan(callsAfterError);
    expect(within(row).getByText("Ad-free")).toBeInTheDocument();
  });

  it("renders a cancelled ad-removal stage as Unfiltered and does not poll", async () => {
    const { calls } = installApi({
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
    await act(async () => {
      await vi.advanceTimersByTimeAsync(AD_STATUS_POLL_INTERVAL_MS * 4);
    });
    expect(calls.filter((c) => c.key === "GET /api/ad-removal/statuses").length).toBe(0);
  });

  it("makes no further batch poll calls after the view unmounts", async () => {
    const active = episode({
      id: 77,
      title: "Unmount Me Ep",
      ad_removal_state: "preparing",
      ad_removal_stage: "downloading",
      ad_removal_action: null,
    });
    const { calls } = installApi({
      ...settings,
      "GET /api/recent": page([active]),
      "GET /api/ad-removal/statuses": () => adRemovalStatuses([adRemovalStatusItem(active)]),
    });
    vi.useFakeTimers();
    const { unmount } = wrap(<RecentView />);
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    screen.getByText("Unmount Me Ep");
    await act(async () => {
      await vi.advanceTimersByTimeAsync(AD_STATUS_POLL_INTERVAL_MS + 100);
    });
    const callsBeforeUnmount = calls.filter((c) => c.key === "GET /api/ad-removal/statuses").length;

    unmount();
    await act(async () => {
      await vi.advanceTimersByTimeAsync(AD_STATUS_POLL_INTERVAL_MS * 4);
    });
    expect(calls.filter((c) => c.key === "GET /api/ad-removal/statuses").length).toBe(callsBeforeUnmount);
  });

  it("a deferred stale batch response cannot apply after a same-flush same-id active-to-active backing-list change", async () => {
    // The backing list starts with an active row at `downloading`. The first
    // batch poll is deferred and, when resolved, returns the STALE downloading
    // stage. While that poll is in flight, a same-ID active-to-active reload
    // delivers a newer stage (`transcribing`). The old response is resolved in
    // the SAME flush as the backing-list change, before any follow-up
    // effect-driven render, and must NOT apply/regress the row.
    const initial = episode({
      id: 420,
      title: "Refresh Race Ep",
      ad_removal_state: "preparing",
      ad_removal_stage: "downloading",
      ad_removal_action: null,
    });
    const refreshed: EpisodeItem = {
      ...initial,
      title: "Refresh Race Ep",
      ad_removal_state: "preparing",
      ad_removal_stage: "transcribing",
      ad_removal_action: null,
    };
    let current = initial;
    let resolvePoll: () => void = () => {};
    const pollResponse = new Promise<void>((resolve) => {
      resolvePoll = resolve;
    });
    const { calls } = installApi({
      ...settings,
      "GET /api/recent": () => page([current]),
      "GET /api/ad-removal/statuses": () =>
        // Always returns the stale downloading status for this id.
        pollResponse.then(() => adRemovalStatuses([adRemovalStatusItem(initial)])),
    });
    vi.useFakeTimers();
    wrap(<RecentView />);
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    const row = screen.getByText("Refresh Race Ep").closest("li")!;
    expect(within(row).getByText("Downloading")).toBeInTheDocument();

    // Start the deferred batch poll (it stays unresolved).
    await act(async () => {
      await vi.advanceTimersByTimeAsync(AD_STATUS_POLL_INTERVAL_MS + 100);
    });
    expect(calls.filter((c) => c.key === "GET /api/ad-removal/statuses").length).toBe(1);

    // Same-ID active-to-active backing-list change delivers a newer stage. The
    // old deferred poll is resolved in the SAME flush (same act, no timer advance
    // / no follow-up effect-driven render) as the backing-list replacement. The
    // old response must be invalidated by the backing-list identity change at
    // apply time, not by a later generation bump.
    current = refreshed;
    await act(async () => {
      window.dispatchEvent(new Event("pods-episodes-changed"));
      // Let the reload fetch + setItems commit the new backing list identity.
      for (let i = 0; i < 8; i++) await Promise.resolve();
      // Now resolve the OLD deferred poll returning the stale downloading stage,
      // still in the same flush before any follow-up effect-driven render.
      resolvePoll();
      for (let i = 0; i < 8; i++) await Promise.resolve();
    });
    // The refreshed stage wins; the stale downloading response never applied.
    expect(within(row).queryByText("Downloading")).not.toBeInTheDocument();
    expect(within(row).getByText("Transcribing")).toBeInTheDocument();
  });

  it("a same-id reload retains fresh non-status fields from the new backing list", async () => {
    const initial = episode({
      id: 410,
      title: "Old Title",
      audio_url: "https://h.example/old.mp3",
      ad_removal_state: "preparing",
      ad_removal_stage: "downloading",
      ad_removal_action: null,
    });
    // After a reload the same id returns a fresh title + audio URL. The fresh
    // backing list also carries the current stage, so the overlay is not needed;
    // the point is that fresh non-status fields replace any stale overlay data.
    const reloaded: EpisodeItem = {
      ...initial,
      title: "Fresh Title",
      audio_url: "https://h.example/fresh.mp3",
      ad_removal_state: "preparing",
      ad_removal_stage: "transcribing",
      ad_removal_action: null,
    };
    let current = initial;
    const { calls } = installApi({
      ...settings,
      "GET /api/recent": () => page([current]),
      "GET /api/ad-removal/statuses": () =>
        adRemovalStatuses([
          adRemovalStatusItem({
            id: 410,
            ad_removal_state: "preparing",
            ad_removal_stage: "transcribing",
            ad_removal_action: null,
            ad_removal_blocking_reason: null,
          }),
        ]),
    });
    vi.useFakeTimers();
    wrap(<RecentView />);
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    expect(screen.getByText("Old Title")).toBeInTheDocument();

    // One batch poll advances the stage to Transcribing.
    await act(async () => {
      await vi.advanceTimersByTimeAsync(AD_STATUS_POLL_INTERVAL_MS + 100);
    });
    const row = screen.getByText("Old Title").closest("li")!;
    expect(within(row).getByText("Transcribing")).toBeInTheDocument();

    // Same-id reload delivers fresh non-status fields (title/audio) and the
    // current stage from the backing list.
    current = reloaded;
    await act(async () => {
      window.dispatchEvent(new Event("pods-episodes-changed"));
      for (let i = 0; i < 8; i++) await Promise.resolve();
    });
    // Fresh title is retained from the backing list; stale old title is gone.
    expect(screen.getByText("Fresh Title")).toBeInTheDocument();
    expect(screen.queryByText("Old Title")).not.toBeInTheDocument();
    const freshRow = screen.getByText("Fresh Title").closest("li")!;
    expect(within(freshRow).getByText("Transcribing")).toBeInTheDocument();
    // No per-row detail fetch for status.
    expect(calls.filter((c) => /^GET \/api\/episodes\/\d+$/.test(c.key))).toHaveLength(0);
  });

  it("a terminal-patch-to-active same-id reload shows the fresh active stage and restarts polling", async () => {
    // A poll marks id 430 terminal (ad-free). Then a same-id reload brings the
    // row back as ACTIVE with a fresh preparing/queued stage. The retained
    // terminal patch must NOT mask the fresh active stage, and polling must
    // resume so the active row keeps refreshing.
    const initial = episode({
      id: 430,
      title: "Terminal To Active Ep",
      ad_removal_state: "preparing",
      ad_removal_stage: "downloading",
      ad_removal_action: null,
    });
    const reloadedActive: EpisodeItem = {
      ...initial,
      title: "Terminal To Active Ep",
      ad_removal_state: "preparing",
      ad_removal_stage: "queued",
      ad_removal_action: null,
    };
    let current = initial;
    let pollCount = 0;
    const { calls } = installApi({
      ...settings,
      "GET /api/recent": () => page([current]),
      "GET /api/ad-removal/statuses": () => {
        pollCount += 1;
        // First poll (before reload) advances the row to terminal ad-free.
        // Later polls (after reload) report the active queued stage.
        const stage = pollCount === 1 ? "ready" : "queued";
        const state = pollCount === 1 ? "ad-free" : "preparing";
        return adRemovalStatuses([
          adRemovalStatusItem({
            id: 430,
            ad_removal_state: state as EpisodeItem["ad_removal_state"],
            ad_removal_stage: stage as EpisodeItem["ad_removal_stage"],
            ad_removal_action: null,
            ad_removal_blocking_reason: null,
          }),
        ]);
      },
    });
    vi.useFakeTimers();
    wrap(<RecentView />);
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    const row = screen.getByText("Terminal To Active Ep").closest("li")!;
    expect(within(row).getByText("Downloading")).toBeInTheDocument();

    // First poll brings the row to terminal Ad-free; polling stops.
    await act(async () => {
      await vi.advanceTimersByTimeAsync(AD_STATUS_POLL_INTERVAL_MS + 100);
    });
    expect(within(row).getByText("Ad-free")).toBeInTheDocument();
    const callsAfterTerminal = calls.filter((c) => c.key === "GET /api/ad-removal/statuses").length;
    await act(async () => {
      await vi.advanceTimersByTimeAsync(AD_STATUS_POLL_INTERVAL_MS * 4);
    });
    expect(calls.filter((c) => c.key === "GET /api/ad-removal/statuses").length).toBe(callsAfterTerminal);

    // Same-id reload brings the row back as ACTIVE with a fresh queued stage.
    current = reloadedActive;
    await act(async () => {
      window.dispatchEvent(new Event("pods-episodes-changed"));
      await vi.advanceTimersByTimeAsync(0);
      for (let i = 0; i < 4; i++) await Promise.resolve();
    });
    // The retained terminal patch must NOT mask the fresh active stage.
    expect(within(row).queryByText("Ad-free")).not.toBeInTheDocument();
    expect(within(row).getByText("Queued")).toBeInTheDocument();

    // Polling restarts for the active row: advancing one boundary fires a poll.
    await act(async () => {
      await vi.advanceTimersByTimeAsync(AD_STATUS_POLL_INTERVAL_MS + 100);
    });
    expect(calls.filter((c) => c.key === "GET /api/ad-removal/statuses").length).toBeGreaterThan(callsAfterTerminal);
  });

  it("covers more than 50 visible active rows with bounded sequential batches", async () => {
    // 55 active rows exceeds the backend's 50-id cap. The view must split the
    // active ids into bounded batches (each <=50), process them sequentially
    // within one completion-scheduled cycle (never overlapping), and cover every
    // active id. The first batch is deferred to prove no second request begins
    // until it resolves; then the second batch begins, every request has <=50
    // ids, and all 55 rows automatically reach the returned terminal state.
    const active = Array.from({ length: 55 }, (_, i) =>
      episode({
        id: 1000 + i,
        title: `Many Ep ${i}`,
        ad_removal_state: "preparing",
        ad_removal_stage: "downloading",
        ad_removal_action: null,
      }),
    );
    let resolveFirst: () => void = () => {};
    const firstResponse = new Promise<void>((resolve) => {
      resolveFirst = resolve;
    });
    let firstBatchResolved = false;
    const { calls } = installApi({
      ...settings,
      "GET /api/recent": page(active),
      "GET /api/ad-removal/statuses": (url: URL) => {
        const ids = (url.searchParams.get("episode_ids") ?? "").split(",").map(Number);
        // Backend would 422 over-50 requests; emulate that guard so an unbounded
        // client would loop on 422 forever.
        if (ids.length > 50) return new HttpError(422, { error: "too many ids" });
        // The first <=50 batch is deferred until resolveFirst() is called.
        if (!firstBatchResolved && ids.length === 50) {
          return firstResponse.then(() =>
            adRemovalStatuses(
              ids.map((id) =>
                adRemovalStatusItem({
                  id,
                  ad_removal_state: "ad-free",
                  ad_removal_stage: "ready",
                  ad_removal_action: null,
                  ad_removal_blocking_reason: null,
                }),
              ),
            ),
          );
        }
        return adRemovalStatuses(
          ids.map((id) =>
            adRemovalStatusItem({
              id,
              ad_removal_state: "ad-free",
              ad_removal_stage: "ready",
              ad_removal_action: null,
              ad_removal_blocking_reason: null,
            }),
          ),
        );
      },
    });
    vi.useFakeTimers();
    wrap(<RecentView />);
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    screen.getByText("Many Ep 0");

    // Start the cycle: the first 50-id batch fires and stays unresolved.
    await act(async () => {
      await vi.advanceTimersByTimeAsync(AD_STATUS_POLL_INTERVAL_MS + 100);
    });
    let statusCalls = calls.filter((c) => c.key === "GET /api/ad-removal/statuses");
    expect(statusCalls).toHaveLength(1);
    const firstIds = (statusCalls[0].url.searchParams.get("episode_ids") ?? "").split(",").map(Number);
    expect(firstIds).toHaveLength(50);

    // No second request begins until the first batch resolves. Advance timers
    // well past the boundary while it is still unresolved: still only 1 call.
    await act(async () => {
      await vi.advanceTimersByTimeAsync(AD_STATUS_POLL_INTERVAL_MS * 4);
    });
    expect(calls.filter((c) => c.key === "GET /api/ad-removal/statuses").length).toBe(1);

    // Resolve the first batch; the second (<=50) batch begins immediately after.
    await act(async () => {
      firstBatchResolved = true;
      resolveFirst();
      for (let i = 0; i < 6; i++) await Promise.resolve();
    });
    statusCalls = calls.filter((c) => c.key === "GET /api/ad-removal/statuses");
    expect(statusCalls.length).toBeGreaterThanOrEqual(2);

    // No request exceeds the 50-id cap, and all 55 ids are covered this cycle.
    for (const c of statusCalls) {
      const ids = (c.url.searchParams.get("episode_ids") ?? "").split(",").map(Number);
      expect(ids.length).toBeLessThanOrEqual(50);
    }
    const covered = new Set<number>();
    for (const c of statusCalls) {
      for (const id of (c.url.searchParams.get("episode_ids") ?? "").split(",").map(Number)) {
        covered.add(id);
      }
    }
    expect(covered.size).toBe(55);
    // No over-limit (51-id) request was ever attempted.
    expect(
      statusCalls.some((c) => (c.url.searchParams.get("episode_ids") ?? "").split(",").length > 50),
    ).toBe(false);

    // Every row automatically reaches the returned terminal Ad-free state.
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
      for (let i = 0; i < 4; i++) await Promise.resolve();
    });
    const rows = screen.getAllByRole("listitem");
    expect(rows).toHaveLength(55);
    for (const r of rows) {
      expect(within(r).getByText("Ad-free")).toBeInTheDocument();
    }
  });
});

describe("FollowsView", () => {
  it("adds a person, exposes the bounded-lookback explanation, and accepts reviewed appearances", async () => {
    let candidates = [{
      id: 9,
      follow_id: 1,
      appearance: {
        source_episode_key: "candidate-9",
        feed_url: "https://feeds.example/interviews",
        feed_title: "Interviews",
        feed_image_url: "",
        guid: "guest-9",
        title: "Elon Musk interview",
        description: "",
        audio_url: "https://audio.example/guest-9.mp3",
        duration_secs: null,
        published_at: 1_750_000_000,
        image_url: "",
        evidence: "name in title",
        confidence: "review" as const,
      },
    }];
    const { calls } = installApi({
      "GET /api/follows": [{ id: 1, name: "Elon Musk", aliases: [], last_checked_at: null, pending_count: candidates.length, accepted_count: 0 }],
      "GET /api/follow-candidates": () => candidates,
      "POST /api/follows": { id: 2, name: "Balaji Srinivasan", aliases: [], last_checked_at: 1, pending_count: 0, accepted_count: 0 },
      "POST /api/follow-candidates/9/accept": () => { candidates = []; return null; },
    });
    const user = userEvent.setup();
    render(<FollowsView />);

    expect(await screen.findByText(/first check looks back 30 days/i)).toBeInTheDocument();
    expect(await screen.findByText("Elon Musk interview")).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Add" }));
    await waitFor(() => expect(screen.queryByText("Elon Musk interview")).not.toBeInTheDocument());

    await user.type(screen.getByRole("textbox", { name: "Person to follow" }), "Balaji Srinivasan");
    await user.click(screen.getByRole("button", { name: "Follow" }));
    await waitFor(() => expect(calls.some((call) => call.key === "POST /api/follows")).toBe(true));
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

  it("one touch only unmarks the selected row when the next row moves underneath", async () => {
    const first = episode({ id: 4, title: "Old One", played_at: 1_750_000_100 });
    const second = episode({ id: 5, title: "Older Two", played_at: 1_750_000_000 });
    const unplayed = new Set<number>();
    const { calls } = installApi({
      ...settings,
      "GET /api/played": () => page([first, second].filter((item) => !unplayed.has(item.id))),
      "DELETE /api/episodes/4/played": () => { unplayed.add(4); return null; },
      "DELETE /api/episodes/5/played": () => { unplayed.add(5); return null; },
    });
    const uninstallReliableTap = installReliableTapActivation(document);
    wrap(<PlayedView />);
    await screen.findByText("Old One");

    const selected = within(screen.getByText("Old One").closest("li")!)
      .getByRole("button", { name: "Mark unplayed" });
    const dispatchPointer = (type: string) => {
      const event = new MouseEvent(type, {
        bubbles: true,
        cancelable: true,
        clientX: 20,
        clientY: 20,
      });
      Object.defineProperties(event, {
        pointerId: { value: 1 },
        pointerType: { value: "touch" },
      });
      selected.dispatchEvent(event);
    };
    act(() => {
      dispatchPointer("pointerdown");
      dispatchPointer("pointerup");
    });
    await waitFor(() => expect(screen.queryByText("Old One")).not.toBeInTheDocument());

    const newlyExposed = within(screen.getByText("Older Two").closest("li")!)
      .getByRole("button", { name: "Mark unplayed" });
    act(() => {
      newlyExposed.dispatchEvent(new MouseEvent("click", {
        bubbles: true,
        cancelable: true,
        clientX: 20,
        clientY: 20,
        detail: 1,
      }));
    });
    await act(async () => { await Promise.resolve(); });
    uninstallReliableTap();

    expect(calls.filter((call) => call.key === "DELETE /api/episodes/4/played")).toHaveLength(1);
    expect(calls.filter((call) => call.key === "DELETE /api/episodes/5/played")).toHaveLength(0);
    expect(screen.getByText("Older Two")).toBeInTheDocument();
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
  it("renders episodes and unsubscribes with an in-app confirmation", async () => {
    const { calls } = installApi({
      ...settings,
      "GET /api/shows/5": {
        show: show(),
        episodes: page([episode({ id: 11, title: "Catalog Ep", played_at: 1_700_000_000 })]),
      },
      "DELETE /api/shows/5": null,
    });
    const user = userEvent.setup();
    wrap(<ShowDetailView showId={5} />);

    await screen.findByText("Catalog Ep");
    expect(screen.getByText(/12 episodes · 3 unplayed/)).toBeInTheDocument();
    expect(screen.getByText("About alpha")).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "Unsubscribe" }));
    expect(screen.getByRole("dialog", { name: "Unsubscribe from Alpha Show" })).toBeInTheDocument();
    expect(calls.some((c) => c.key === "DELETE /api/shows/5")).toBe(false);
    await user.click(screen.getByRole("button", { name: "Confirm unsubscribe" }));
    await waitFor(() => expect(calls.some((c) => c.key === "DELETE /api/shows/5")).toBe(true));
    expect(window.location.hash).toBe("#/shows");
  });

  it("does nothing when unsubscribe is cancelled", async () => {
    const { calls } = installApi({
      ...settings,
      "GET /api/shows/5": { show: show(), episodes: page([]) },
    });
    const user = userEvent.setup();
    wrap(<ShowDetailView showId={5} />);
    await screen.findByRole("button", { name: "Unsubscribe" });
    await user.click(screen.getByRole("button", { name: "Unsubscribe" }));
    await user.click(screen.getByRole("button", { name: "Keep show" }));
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

  it("updates ad-removal stage immediately after Prepare in a non-Listen owner and removes the action button", async () => {
    // ShowDetailView renders EpisodeRow without onAdRemovalStage. A successful
    // Prepare must still surface the backend-returned granular stage right away
    // and remove the old action button so the row cannot be re-submitted.
    const { calls } = installApi({
      ...settings,
      "GET /api/shows/5": {
        show: show(),
        episodes: page([
          episode({
            id: 17,
            title: "Prepare Me Ep",
            ad_removal_state: "unfiltered",
            ad_removal_action: "prepare",
            ad_removal_stage: null,
          }),
        ]),
      },
      "POST /api/episodes/17/ad-removal/prepare": { stage: "queued" },
    });
    const user = userEvent.setup();
    wrap(<ShowDetailView showId={5} />);

    const row = (await screen.findByText("Prepare Me Ep")).closest("li")!;
    expect(within(row).getByText("Unfiltered")).toBeInTheDocument();
    const prepareBtn = within(row).getByRole("button", { name: "Prepare ad-free" });
    expect(prepareBtn).toBeInTheDocument();

    await user.click(prepareBtn);
    // The backend-returned granular stage appears immediately.
    expect(within(row).getByText("Queued")).toBeInTheDocument();
    // The old action button is gone, preventing duplicate submission.
    expect(within(row).queryByRole("button", { name: "Prepare ad-free" })).not.toBeInTheDocument();
    expect(calls.filter((c) => c.key === "POST /api/episodes/17/ad-removal/prepare").length).toBe(1);
  });
});
