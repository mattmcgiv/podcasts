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

    const main = screen.getByRole("main");
    fireEvent.touchStart(main, { touches: [{ clientX: 280, clientY: 240 }] });
    fireEvent.touchEnd(main, { changedTouches: [{ clientX: 90, clientY: 248 }] });
    await screen.findByRole("heading", { name: "Played" });

    fireEvent.touchStart(main, { touches: [{ clientX: 80, clientY: 240 }] });
    fireEvent.touchEnd(main, { changedTouches: [{ clientX: 275, clientY: 246 }] });
    await screen.findByText("Fresh Episode");
  });
});
