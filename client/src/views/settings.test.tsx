import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { EPISODES_CHANGED_EVENT } from "../events";
import { episode, HttpError, installApi } from "../test/mockApi";
import { SettingsSheet } from "./SettingsSheet";

const adRemovalSettings = {
  enabled: false,
  enrollment_cutoff: null,
  cloud_classifier_configured: true,
  model_repository: "deepseek/api",
  model_revision: "deepseek-v4-pro",
  model_total_bytes: 0,
  model_downloaded_bytes: 0,
  model_download_state: "ready",
  classifier_available: true,
  classifier_unavailable_reason: null,
  episode_storage_bytes: 1_250_000_000,
  episode_storage_limit_bytes: 10_000_000_000,
  device_available_bytes: 42_000_000_000,
  minimum_free_bytes: 10_000_000_000,
  corrections: [{ podcast_id: 7, podcast_title: "Example Show", count: 3 }],
  deepseek_usage: {
    total_cost_usd: 0.18,
    average_cost_per_episode_usd: 0.09,
    average_cost_per_podcast_minute_usd: 0.002,
    ad_detection_cost_usd: 0.12,
    show_notes_cost_usd: 0.06,
  },
};


describe("SettingsSheet", () => {
  it("shows the most recent native automatic refresh", async () => {
    installApi({
      "GET /api/refresh-status": {
        last_attempt_at: 1_784_071_800,
        last_success_at: 1_784_071_800,
        last_source: "foreground",
        last_refreshed: 3,
        last_errors: 1,
      },
    });
    render(<SettingsSheet onClose={() => {}} />);

    expect(await screen.findByText(/Last feed refresh:/)).toHaveTextContent("Automatic");
    expect(screen.getByText(/1 feed failed/)).toBeInTheDocument();
  });

  it("persists the selected appearance preference", async () => {
    installApi({});
    const user = userEvent.setup();
    render(<SettingsSheet onClose={() => {}} />);

    await user.click(screen.getByRole("button", { name: "Light appearance" }));
    expect(document.documentElement.dataset.theme).toBe("light");
    expect(window.localStorage.getItem("pods-theme-preference")).toBe("light");
  });

  it("adds a feed by URL", async () => {
    const { calls } = installApi({
      "POST /api/shows": {
        id: 1, feed_url: "https://x.example/f", title: "Added Show", description: "",
        image_url: "", site_url: "", episode_count: 3, unplayed_count: 2,
      },
    });
    const user = userEvent.setup();
    render(<SettingsSheet onClose={() => {}} />);

    await user.type(screen.getByLabelText("Feed URL"), "https://x.example/f");
    await user.click(screen.getByRole("button", { name: "Add" }));
    await screen.findByText("Subscribed to Added Show");
    const subscribeCall = calls.find((call) => call.key === "POST /api/shows");
    expect(JSON.parse(String(subscribeCall?.init.body))).toEqual({ feed_url: "https://x.example/f" });
  });

  it("imports an OPML file and reports counts", async () => {
    installApi({ "POST /api/opml": { imported: 2, skipped: 1, failed: 0 } });
    const user = userEvent.setup();
    render(<SettingsSheet onClose={() => {}} />);

    const file = new File(["<opml/>"], "subs.opml", { type: "text/xml" });
    await user.upload(screen.getByTestId("opml-file"), file);
    await screen.findByText("Imported 2, skipped 1, failed 0");
  });

  it("exports OPML through a blob download", async () => {
    installApi({ "GET /api/opml": "<opml><body/></opml>" });
    const createUrl = vi.fn(() => "blob:fake");
    const revokeUrl = vi.fn();
    vi.stubGlobal("URL", Object.assign(URL, { createObjectURL: createUrl, revokeObjectURL: revokeUrl }));
    const clickSpy = vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(() => {});

    const user = userEvent.setup();
    render(<SettingsSheet onClose={() => {}} />);
    await user.click(screen.getByRole("button", { name: "Export OPML" }));
    await screen.findByText("Exported pods.opml");
    expect(createUrl).toHaveBeenCalled();
    expect(clickSpy).toHaveBeenCalled();
  });

  it("refreshes all feeds and reports errors", async () => {
    installApi({ "POST /api/refresh": { refreshed: 4, errors: 1 } });
    const user = userEvent.setup();
    render(<SettingsSheet onClose={() => {}} />);
    await user.click(screen.getByRole("button", { name: "Refresh all feeds" }));
    await screen.findByText("Refreshed 4 feeds, 1 failed");
  });

  it("emits episodes-changed after manual refresh even when refreshed is 0", async () => {
    installApi({ "POST /api/refresh": { refreshed: 0, errors: 0 } });
    const changed = vi.fn();
    window.addEventListener(EPISODES_CHANGED_EVENT, changed);
    const user = userEvent.setup();
    render(<SettingsSheet onClose={() => {}} />);
    await user.click(screen.getByRole("button", { name: "Refresh all feeds" }));
    await screen.findByText("Refreshed 0 feeds");
    expect(changed).toHaveBeenCalled();
    window.removeEventListener(EPISODES_CHANGED_EVENT, changed);
  });

  it("surfaces API errors as status text", async () => {
    installApi({ "POST /api/refresh": new HttpError(500, { error: "refresh blew up" }) });
    const user = userEvent.setup();
    render(<SettingsSheet onClose={() => {}} />);
    await user.click(screen.getByRole("button", { name: "Refresh all feeds" }));
    await screen.findByText("refresh blew up");
  });

  it("shows DeepSeek usage placeholders when there is no spend", async () => {
    installApi({
      "GET /api/ad-removal/settings": {
        ...adRemovalSettings,
        deepseek_usage: {
          total_cost_usd: 0,
          average_cost_per_episode_usd: null,
          average_cost_per_podcast_minute_usd: null,
          ad_detection_cost_usd: 0,
          show_notes_cost_usd: 0,
        },
      },
    });
    render(<SettingsSheet onClose={() => {}} />);

    expect(await screen.findByText("DeepSeek usage")).toBeInTheDocument();
    expect(screen.getByText(/Total cost: \$0\.00/)).toBeInTheDocument();
    expect(screen.getByText(/Average per episode: —/)).toBeInTheDocument();
    expect(screen.getByText(/Average per podcast minute: —/)).toBeInTheDocument();
    expect(screen.getByText(/Ad detection: \$0\.00/)).toBeInTheDocument();
    expect(screen.getByText(/Show notes: \$0\.00/)).toBeInTheDocument();
  });

  it("does not render a close button", async () => {
    installApi({});
    render(<SettingsSheet onClose={() => {}} />);
    expect(screen.queryByRole("button", { name: "Close settings" })).not.toBeInTheDocument();
  });

  it("enables DeepSeek Pro ad removal when an API key is configured", async () => {
    const { calls } = installApi({
      "GET /api/ad-removal/settings": adRemovalSettings,
      "POST /api/ad-removal/enable": {
        ...adRemovalSettings,
        enabled: true,
        enrollment_cutoff: 1_784_100_000,
        model_download_state: "ready",
      },
    });
    const user = userEvent.setup();
    render(<SettingsSheet onClose={() => {}} />);

    expect(await screen.findByText("Ad removal")).toBeInTheDocument();
    const enable = screen.getByRole("button", { name: "Enable ad removal" });
    expect(enable).toBeEnabled();
    await user.click(enable);

    await screen.findByText(/Cloud classifier: DeepSeek V4 Pro ready/);
    const call = calls.find((item) => item.key === "POST /api/ad-removal/enable");
    expect(JSON.parse(String(call?.init.body))).toEqual({ confirmed_bytes: 0 });
    expect(
      screen.getByText(/Transcript text is sent to DeepSeek V4 Pro/),
    ).toBeInTheDocument();
    expect(screen.getByLabelText("DeepSeek API key")).toHaveAttribute("placeholder", "DeepSeek API key saved");
  });

  it("saves a DeepSeek API key and then allows enable", async () => {
    const unavailable = {
      ...adRemovalSettings,
      cloud_classifier_configured: false,
      classifier_available: false,
      classifier_unavailable_reason: "api_key_required" as const,
    };
    const { calls } = installApi({
      "GET /api/ad-removal/settings": unavailable,
      "PUT /api/ad-removal/deepseek-key": adRemovalSettings,
    });
    const user = userEvent.setup();
    render(<SettingsSheet onClose={() => {}} />);

    const enable = await screen.findByRole("button", { name: "Enable ad removal" });
    expect(enable).toBeDisabled();
    expect(screen.getByText(/API key required/)).toBeInTheDocument();
    await user.type(screen.getByLabelText("DeepSeek API key"), "sk-test");
    await user.click(screen.getByRole("button", { name: "Save DeepSeek API key" }));
    await screen.findByText("DeepSeek API key saved in iPhone Keychain");
    expect(screen.getByRole("button", { name: "Enable ad removal" })).toBeEnabled();
    const save = calls.find((item) => item.key === "PUT /api/ad-removal/deepseek-key");
    expect(JSON.parse(String(save?.init.body))).toEqual({ api_key: "sk-test" });
  });

  it("keeps disable available and explains a pause when already enabled", async () => {
    installApi({
      "GET /api/ad-removal/settings": {
        ...adRemovalSettings,
        enabled: true,
        cloud_classifier_configured: false,
        classifier_available: false,
        classifier_unavailable_reason: "api_key_required",
      },
    });
    render(<SettingsSheet onClose={() => {}} />);

    expect(await screen.findByRole("button", { name: "Disable ad removal" })).toBeEnabled();
    expect(screen.queryByRole("button", { name: "Enable ad removal" })).not.toBeInTheDocument();
    expect(
      screen.getByText(/classification is paused until a DeepSeek API key is saved/),
    ).toBeInTheDocument();
    expect(screen.getByText(/API key required/)).toBeInTheDocument();
  });

  it("shows storage and correction controls and runs destructive actions explicitly", async () => {
    const resetSettings = { ...adRemovalSettings, corrections: [] };
    const { calls } = installApi({
      "GET /api/ad-removal/settings": { ...adRemovalSettings, enabled: true },
      "POST /api/ad-removal/corrections/7/reset": resetSettings,
      "GET /api/ad-removal/diagnostics/export": new Blob(["diagnostics"], { type: "application/zip" }),
      "POST /api/ad-removal/diagnostics/clear": null,
      "POST /api/ad-removal/cleanup": resetSettings,
    });
    const createUrl = vi.fn(() => "blob:diagnostics");
    const revokeUrl = vi.fn();
    vi.stubGlobal("URL", Object.assign(URL, { createObjectURL: createUrl, revokeObjectURL: revokeUrl }));
    vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(() => {});
    vi.spyOn(window, "confirm").mockReturnValue(true);
    const user = userEvent.setup();
    render(<SettingsSheet onClose={() => {}} />);

    expect(await screen.findByText(/Prepared episode storage: 1.25 GB of 10.00 GB/)).toBeInTheDocument();
    expect(screen.getByText("DeepSeek usage")).toBeInTheDocument();
    expect(screen.getByText(/Total cost: \$0\.18/)).toBeInTheDocument();
    expect(screen.getByText(/Average per episode: \$0\.09/)).toBeInTheDocument();
    expect(screen.getByText(/Average per podcast minute: \$0\.0020/)).toBeInTheDocument();
    expect(screen.getByText(/Ad detection: \$0\.12/)).toBeInTheDocument();
    expect(screen.getByText(/Show notes: \$0\.06/)).toBeInTheDocument();
    expect(screen.getByText("Example Show: 3")).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Reset learned corrections for Example Show" }));
    await screen.findByText("Reset learned corrections for Example Show");

    await user.click(screen.getByRole("button", { name: "Export ad-removal diagnostics" }));
    await screen.findByText("Exported ad-removal diagnostics");
    expect(createUrl).toHaveBeenCalled();

    await user.click(screen.getByRole("button", { name: "Clear ad-removal diagnostics" }));
    await screen.findByText("Cleared ad-removal diagnostics");

    await user.click(screen.getByRole("button", { name: "Delete all ad-removal data" }));
    await screen.findByText("Deleted all ad-removal data");
    const cleanup = calls.find((item) => item.key === "POST /api/ad-removal/cleanup");
    expect(JSON.parse(String(cleanup?.init.body))).toEqual({ confirm: "DELETE_AD_REMOVAL_DATA" });
  });
});

describe("episode factory sanity", () => {
  it("produces consistent defaults", () => {
    expect(episode().id).toBe(1);
    expect(episode({ id: 9 }).id).toBe(9);
  });
});
