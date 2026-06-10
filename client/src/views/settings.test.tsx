import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { getToken, UNAUTHORIZED_EVENT } from "../api";
import { episode, HttpError, installApi, loggedIn } from "../test/mockApi";
import { SettingsSheet } from "./SettingsSheet";

describe("SettingsSheet", () => {
  it("adds a feed by URL", async () => {
    loggedIn();
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
    expect(JSON.parse(String(calls[0].init.body))).toEqual({ feed_url: "https://x.example/f" });
  });

  it("imports an OPML file and reports counts", async () => {
    loggedIn();
    installApi({ "POST /api/opml": { imported: 2, skipped: 1, failed: 0 } });
    const user = userEvent.setup();
    render(<SettingsSheet onClose={() => {}} />);

    const file = new File(["<opml/>"], "subs.opml", { type: "text/xml" });
    await user.upload(screen.getByTestId("opml-file"), file);
    await screen.findByText("Imported 2, skipped 1, failed 0");
  });

  it("exports OPML through a blob download", async () => {
    loggedIn();
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
    loggedIn();
    installApi({ "POST /api/refresh": { refreshed: 4, errors: 1 } });
    const user = userEvent.setup();
    render(<SettingsSheet onClose={() => {}} />);
    await user.click(screen.getByRole("button", { name: "Refresh all feeds" }));
    await screen.findByText("Refreshed 4 feeds, 1 failed");
  });

  it("surfaces API errors as status text", async () => {
    loggedIn();
    installApi({ "POST /api/refresh": new HttpError(500, { error: "refresh blew up" }) });
    const user = userEvent.setup();
    render(<SettingsSheet onClose={() => {}} />);
    await user.click(screen.getByRole("button", { name: "Refresh all feeds" }));
    await screen.findByText("refresh blew up");
  });

  it("logs out: clears token and broadcasts", async () => {
    loggedIn();
    installApi({});
    const listener = vi.fn();
    window.addEventListener(UNAUTHORIZED_EVENT, listener);
    const user = userEvent.setup();
    render(<SettingsSheet onClose={() => {}} />);
    await user.click(screen.getByRole("button", { name: "Log out" }));
    expect(getToken()).toBeNull();
    expect(listener).toHaveBeenCalled();
    window.removeEventListener(UNAUTHORIZED_EVENT, listener);
  });

  it("closes via the header button", async () => {
    loggedIn();
    installApi({});
    const onClose = vi.fn();
    const user = userEvent.setup();
    render(<SettingsSheet onClose={onClose} />);
    await user.click(screen.getByRole("button", { name: "Close settings" }));
    expect(onClose).toHaveBeenCalled();
  });
});

describe("episode factory sanity", () => {
  it("produces consistent defaults", () => {
    expect(episode().id).toBe(1);
    expect(episode({ id: 9 }).id).toBe(9);
  });
});
