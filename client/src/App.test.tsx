import { fireEvent, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import { App } from "./App";
import { episode, installApi, page } from "./test/mockApi";

const shellRoutes = {
  "GET /api/settings": { speed: 1, autoplay: true },
  "GET /api/recent": page([episode({ id: 1, title: "Fresh Episode" })]),
  "GET /api/played": page([]),
  "GET /api/shows": [],
};

afterEach(() => {
  delete window.webkit;
});

describe("App", () => {
  it("notifies the native container after the UI commits", () => {
    installApi(shellRoutes);
    const postMessage = vi.fn();
    Object.defineProperty(window, "webkit", {
      configurable: true,
      value: { messageHandlers: { podsLifecycle: { postMessage } } },
    });

    render(<App />);

    expect(postMessage).toHaveBeenCalledWith({ event: "ui-ready" });
  });

  it("opens directly into Listen without login", async () => {
    installApi(shellRoutes);
    render(<App />);

    await screen.findByText("Fresh Episode");
    expect(screen.getByRole("button", { name: "Listen" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Played" })).toBeInTheDocument();
    expect(screen.queryByPlaceholderText("Access token")).not.toBeInTheDocument();
  });

  it("switches tabs through the tab bar", async () => {
    installApi(shellRoutes);
    const user = userEvent.setup();
    render(<App />);
    await screen.findByText("Fresh Episode");

    await user.click(screen.getByRole("button", { name: "Played" }));
    await screen.findByRole("heading", { name: "Played" });

    await user.click(screen.getByRole("button", { name: "Shows" }));
    await screen.findByRole("heading", { name: "Shows" });

    await user.click(screen.getByRole("button", { name: "Settings" }));
    await screen.findByRole("dialog", { name: "Settings" });
  });

  it("switches primary tabs with horizontal swipes", async () => {
    installApi(shellRoutes);
    render(<App />);
    await screen.findByText("Fresh Episode");

    const episodeRow = screen.getByText("Fresh Episode").closest("button")!;
    fireEvent.touchStart(episodeRow, { touches: [{ clientX: 280, clientY: 240 }] });
    fireEvent.touchEnd(episodeRow, { changedTouches: [{ clientX: 90, clientY: 248 }] });
    await screen.findByRole("heading", { name: "Played" });

    const playedView = screen.getByRole("main");
    fireEvent.touchStart(playedView, { touches: [{ clientX: 80, clientY: 240 }] });
    fireEvent.touchEnd(playedView, { changedTouches: [{ clientX: 275, clientY: 246 }] });
    await screen.findByText("Fresh Episode");
  });

  it("ignores swipes that start on text inputs or use more than one finger", async () => {
    installApi({
      ...shellRoutes,
      "GET /api/refresh-status": {
        last_attempt_at: null,
        last_success_at: null,
        last_source: null,
        last_refreshed: 0,
        last_errors: 0,
      },
    });
    const user = userEvent.setup();
    render(<App />);
    await screen.findByText("Fresh Episode");
    await user.click(screen.getByRole("button", { name: "Settings" }));
    const feedUrl = await screen.findByRole("textbox", { name: "Feed URL" });

    fireEvent.touchStart(feedUrl, { touches: [{ clientX: 280, clientY: 240 }] });
    fireEvent.touchEnd(feedUrl, { changedTouches: [{ clientX: 90, clientY: 248 }] });
    expect(screen.getByRole("dialog", { name: "Settings" })).toBeInTheDocument();

    const main = screen.getByRole("main");
    fireEvent.touchStart(main, {
      touches: [
        { clientX: 280, clientY: 240 },
        { clientX: 200, clientY: 240 },
      ],
    });
    fireEvent.touchEnd(main, { changedTouches: [{ clientX: 90, clientY: 248 }] });
    expect(screen.getByRole("dialog", { name: "Settings" })).toBeInTheDocument();
  });

  it("keeps Listen selected on notifications and ignores horizontal swipes", async () => {
    installApi(shellRoutes);
    window.location.hash = "#/notifications";
    render(<App />);
    await screen.findByRole("heading", { name: "Notifications" });
    expect(screen.getByRole("button", { name: "Listen" })).toHaveAttribute("aria-current", "page");
    const main = screen.getByRole("main");
    fireEvent.touchStart(main, { touches: [{ clientX: 280, clientY: 240 }] });
    fireEvent.touchEnd(main, { changedTouches: [{ clientX: 90, clientY: 248 }] });
    expect(screen.getByRole("heading", { name: "Notifications" })).toBeInTheDocument();
    expect(window.location.hash).toBe("#/notifications");
    expect(screen.queryByRole("heading", { name: "Played" })).not.toBeInTheDocument();
  });

  it("animates a completed tab swipe", async () => {
    installApi(shellRoutes);
    render(<App />);
    await screen.findByText("Fresh Episode");

    const main = screen.getByRole("main");
    fireEvent.touchStart(main, { touches: [{ clientX: 280, clientY: 240 }] });
    fireEvent.touchEnd(main, { changedTouches: [{ clientX: 90, clientY: 248 }] });
    expect(document.querySelector(".tab-swipe-forward")).toBeTruthy();
    await screen.findByRole("heading", { name: "Played" });
  });
});
