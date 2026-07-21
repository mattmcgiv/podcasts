import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { EPISODES_CHANGED_EVENT } from "../events";
import { episode, HttpError, installApi } from "../test/mockApi";
import { SettingsSheet } from "./SettingsSheet";

const adRemovalSettings = {
  enabled: false,
  enrollment_cutoff: null,
  cloud_classifier_configured: false,
  model_repository: "mlx-community/Qwen3.5-4B-MLX-4bit",
  model_revision: "32f3e8ecf65426fc3306969496342d504bfa13f3",
  model_total_bytes: 3_061_129_077,
  model_downloaded_bytes: 0,
  model_download_state: "not_downloaded",
  episode_storage_bytes: 1_250_000_000,
  episode_storage_limit_bytes: 10_000_000_000,
  device_available_bytes: 42_000_000_000,
  corrections: [{ podcast_id: 7, podcast_title: "Example Show", count: 3 }],
};


describe("SettingsSheet", () => {
  it("saves the DeepSeek API key without rendering it back", async () => {
    const { calls } = installApi({
      "GET /api/ad-removal/settings": adRemovalSettings,
      "PUT /api/ad-removal/deepseek-key": { ...adRemovalSettings, cloud_classifier_configured: true },
    });
    const user = userEvent.setup();
    render(<SettingsSheet onClose={() => {}} />);

    const input = await screen.findByLabelText("DeepSeek API key");
    await user.type(input, "ds-test-secret");
    await user.click(screen.getByRole("button", { name: "Save DeepSeek API key" }));

    await screen.findByText("DeepSeek API key saved in iPhone Keychain");
    expect(screen.queryByDisplayValue("ds-test-secret")).not.toBeInTheDocument();
    const call = calls.find((item) => item.key === "PUT /api/ad-removal/deepseek-key");
    expect(JSON.parse(String(call?.init.body))).toEqual({ api_key: "ds-test-secret" });
  });

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

  it("closes via the header button", async () => {
    installApi({});
    const onClose = vi.fn();
    const user = userEvent.setup();
    render(<SettingsSheet onClose={onClose} />);
    await user.click(screen.getByRole("button", { name: "Close settings" }));
    expect(onClose).toHaveBeenCalled();
  });

  it("enables cloud ad removal after the API key is configured", async () => {
    const { calls } = installApi({
      "GET /api/ad-removal/settings": { ...adRemovalSettings, cloud_classifier_configured: true },
      "POST /api/ad-removal/enable": {
        ...adRemovalSettings,
        enabled: true,
        enrollment_cutoff: 1_784_100_000,
        cloud_classifier_configured: true,
        model_download_state: "ready",
      },
    });
    const user = userEvent.setup();
    render(<SettingsSheet onClose={() => {}} />);

    expect(await screen.findByText("Ad removal")).toBeInTheDocument();
    const enable = screen.getByRole("button", { name: "Enable ad removal" });
    await user.click(enable);

    await screen.findByText(/Cloud classifier: Configured/);
    const call = calls.find((item) => item.key === "POST /api/ad-removal/enable");
    expect(JSON.parse(String(call?.init.body))).toEqual({ confirmed_bytes: 3_061_129_077 });
    expect(
      screen.getByText(/Transcript text is sent to DeepSeek.*generated show notes/),
    ).toBeInTheDocument();
  });

  it("keeps enable disabled until a DeepSeek API key is configured", async () => {
    installApi({ "GET /api/ad-removal/settings": adRemovalSettings });
    render(<SettingsSheet onClose={() => {}} />);
    expect(await screen.findByRole("button", { name: "Enable ad removal" })).toBeDisabled();
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
