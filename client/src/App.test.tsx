import { act, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { App } from "./App";
import { AUTO_REFRESH_INTERVAL_MS, AUTO_REFRESH_RETRY_MS } from "./autoRefresh";
import { EPISODES_CHANGED_EVENT } from "./events";
import { episode, HttpError, installApi, page } from "./test/mockApi";

const shellRoutes = {
  "GET /api/settings": { speed: 1, autoplay: true },
  "GET /api/recent": page([episode({ id: 1, title: "Fresh Episode" })]),
  "GET /api/played": page([]),
  "GET /api/shows": [],
};

describe("App", () => {
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

    await user.click(screen.getByRole("button", { name: "Search" }));
    await screen.findByRole("heading", { name: "Search" });
  });
});

describe("App open/visible auto-refresh", () => {
  let hiddenDescriptor: PropertyDescriptor | undefined;
  let changed: EventListener;

  beforeEach(() => {
    // shouldAdvanceTime: RTL findBy/waitFor poll via timers; pure fake timers hang.
    vi.useFakeTimers({ shouldAdvanceTime: true });
    hiddenDescriptor = Object.getOwnPropertyDescriptor(Document.prototype, "hidden")
      ?? Object.getOwnPropertyDescriptor(document, "hidden");
    Object.defineProperty(document, "hidden", { configurable: true, get: () => false });
    changed = vi.fn() as EventListener;
    window.addEventListener(EPISODES_CHANGED_EVENT, changed);
  });

  afterEach(() => {
    window.removeEventListener(EPISODES_CHANGED_EVENT, changed);
    if (hiddenDescriptor) {
      Object.defineProperty(document, "hidden", hiddenDescriptor);
    } else {
      delete (document as { hidden?: boolean }).hidden;
    }
  });

  it("POSTs /api/refresh after 30 minutes open/visible and signals episodes-changed", async () => {
    const { calls } = installApi({
      ...shellRoutes,
      "POST /api/refresh": { refreshed: 1, errors: 0 },
    });

    render(<App />);
    await screen.findByText("Fresh Episode");
    expect(calls.some((c) => c.key === "POST /api/refresh")).toBe(false);

    await act(async () => {
      await vi.advanceTimersByTimeAsync(AUTO_REFRESH_INTERVAL_MS);
    });

    expect(calls.filter((c) => c.key === "POST /api/refresh")).toHaveLength(1);
    expect(changed as ReturnType<typeof vi.fn>).toHaveBeenCalled();
  });

  it("does not refresh while the document is hidden", async () => {
    let hidden = false;
    Object.defineProperty(document, "hidden", { configurable: true, get: () => hidden });
    const { calls } = installApi({
      ...shellRoutes,
      "POST /api/refresh": { refreshed: 1, errors: 0 },
    });

    render(<App />);
    await screen.findByText("Fresh Episode");

    hidden = true;
    document.dispatchEvent(new Event("visibilitychange"));

    await act(async () => {
      await vi.advanceTimersByTimeAsync(AUTO_REFRESH_INTERVAL_MS * 2);
    });

    expect(calls.some((c) => c.key === "POST /api/refresh")).toBe(false);
  });

  it("resumes the remaining interval after becoming visible again", async () => {
    let hidden = false;
    Object.defineProperty(document, "hidden", { configurable: true, get: () => hidden });
    const { calls } = installApi({
      ...shellRoutes,
      "POST /api/refresh": { refreshed: 1, errors: 0 },
    });

    render(<App />);
    await screen.findByText("Fresh Episode");

    await act(async () => {
      await vi.advanceTimersByTimeAsync(AUTO_REFRESH_INTERVAL_MS / 2);
    });
    hidden = true;
    document.dispatchEvent(new Event("visibilitychange"));

    await act(async () => {
      await vi.advanceTimersByTimeAsync(AUTO_REFRESH_INTERVAL_MS);
    });
    expect(calls.some((c) => c.key === "POST /api/refresh")).toBe(false);

    hidden = false;
    document.dispatchEvent(new Event("visibilitychange"));
    expect(calls.some((c) => c.key === "POST /api/refresh")).toBe(false);

    // Remaining half of the open/visible interval after resume.
    await act(async () => {
      await vi.advanceTimersByTimeAsync(AUTO_REFRESH_INTERVAL_MS / 2);
    });
    expect(calls.filter((c) => c.key === "POST /api/refresh")).toHaveLength(1);
  });

  it("does not signal episodes-changed when refresh reports zero feeds", async () => {
    installApi({
      ...shellRoutes,
      "POST /api/refresh": { refreshed: 0, errors: 0 },
    });

    render(<App />);
    await screen.findByText("Fresh Episode");

    await act(async () => {
      await vi.advanceTimersByTimeAsync(AUTO_REFRESH_INTERVAL_MS);
    });

    expect(changed as ReturnType<typeof vi.fn>).not.toHaveBeenCalled();
  });

  it("does not start a second auto-refresh while one is in flight across hide/show", async () => {
    let hidden = false;
    let resolveRefresh!: (v: { refreshed: number; errors: number }) => void;
    const pending = new Promise<{ refreshed: number; errors: number }>((r) => {
      resolveRefresh = r;
    });
    Object.defineProperty(document, "hidden", { configurable: true, get: () => hidden });
    const { calls } = installApi({
      ...shellRoutes,
      "POST /api/refresh": () => pending,
    });

    render(<App />);
    await screen.findByText("Fresh Episode");

    await act(async () => {
      await vi.advanceTimersByTimeAsync(AUTO_REFRESH_INTERVAL_MS);
    });
    expect(calls.filter((c) => c.key === "POST /api/refresh")).toHaveLength(1);

    hidden = true;
    document.dispatchEvent(new Event("visibilitychange"));
    hidden = false;
    document.dispatchEvent(new Event("visibilitychange"));
    expect(calls.filter((c) => c.key === "POST /api/refresh")).toHaveLength(1);

    resolveRefresh({ refreshed: 1, errors: 0 });
    await act(async () => {
      await Promise.resolve();
    });
    expect(calls.filter((c) => c.key === "POST /api/refresh")).toHaveLength(1);
    expect(changed as ReturnType<typeof vi.fn>).toHaveBeenCalled();
  });

  it("coalesces an in-flight auto-refresh with a concurrent refreshFeeds call", async () => {
    let resolveRefresh!: (v: { refreshed: number; errors: number }) => void;
    const pending = new Promise<{ refreshed: number; errors: number }>((r) => {
      resolveRefresh = r;
    });
    const { calls } = installApi({
      ...shellRoutes,
      "POST /api/refresh": () => pending,
    });

    render(<App />);
    await screen.findByText("Fresh Episode");

    await act(async () => {
      await vi.advanceTimersByTimeAsync(AUTO_REFRESH_INTERVAL_MS);
    });
    expect(calls.filter((c) => c.key === "POST /api/refresh")).toHaveLength(1);

    const { refreshFeeds } = await import("./refreshFeeds");
    const second = refreshFeeds();
    expect(calls.filter((c) => c.key === "POST /api/refresh")).toHaveLength(1);

    resolveRefresh({ refreshed: 1, errors: 0 });
    await act(async () => {
      await second;
    });
    expect(calls.filter((c) => c.key === "POST /api/refresh")).toHaveLength(1);
  });

  it("survives a failed auto-refresh without crashing and can succeed on the next tick", async () => {
    let attempt = 0;
    const { calls } = installApi({
      ...shellRoutes,
      "POST /api/refresh": () => {
        attempt += 1;
        if (attempt === 1) return new HttpError(500, { error: "boom" });
        return { refreshed: 1, errors: 0 };
      },
    });
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});

    render(<App />);
    await screen.findByText("Fresh Episode");

    await act(async () => {
      await vi.advanceTimersByTimeAsync(AUTO_REFRESH_INTERVAL_MS);
    });
    expect(calls.filter((c) => c.key === "POST /api/refresh")).toHaveLength(1);
    expect(changed as ReturnType<typeof vi.fn>).not.toHaveBeenCalled();
    expect(warn).toHaveBeenCalled();

    await act(async () => {
      await vi.advanceTimersByTimeAsync(AUTO_REFRESH_RETRY_MS);
    });
    expect(calls.filter((c) => c.key === "POST /api/refresh")).toHaveLength(2);
    expect(changed as ReturnType<typeof vi.fn>).toHaveBeenCalled();

    warn.mockRestore();
  });

  it("stops auto-refresh after unmount", async () => {
    const { calls } = installApi({
      ...shellRoutes,
      "POST /api/refresh": { refreshed: 1, errors: 0 },
    });

    const view = render(<App />);
    await screen.findByText("Fresh Episode");
    view.unmount();

    await act(async () => {
      await vi.advanceTimersByTimeAsync(AUTO_REFRESH_INTERVAL_MS * 2);
    });
    document.dispatchEvent(new Event("visibilitychange"));

    expect(calls.some((c) => c.key === "POST /api/refresh")).toBe(false);
  });

  it("recovers after a hung refresh times out so a later auto-refresh can run", async () => {
    const { REFRESH_TIMEOUT_MS } = await import("./refreshFeeds");
    let attempt = 0;
    const { calls } = installApi({
      ...shellRoutes,
      "POST /api/refresh": () => {
        attempt += 1;
        if (attempt === 1) {
          // Never settle until aborted by refreshFeeds timeout.
          return new Promise(() => {});
        }
        return { refreshed: 1, errors: 0 };
      },
    });
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});

    render(<App />);
    await screen.findByText("Fresh Episode");

    await act(async () => {
      await vi.advanceTimersByTimeAsync(AUTO_REFRESH_INTERVAL_MS);
    });
    expect(calls.filter((c) => c.key === "POST /api/refresh")).toHaveLength(1);

    await act(async () => {
      await vi.advanceTimersByTimeAsync(REFRESH_TIMEOUT_MS);
    });
    // Failed tick re-arms with the short retry interval.
    await act(async () => {
      await vi.advanceTimersByTimeAsync(AUTO_REFRESH_RETRY_MS);
    });
    expect(calls.filter((c) => c.key === "POST /api/refresh")).toHaveLength(2);
    expect(changed as ReturnType<typeof vi.fn>).toHaveBeenCalled();
    expect(warn).toHaveBeenCalled();

    warn.mockRestore();
  });

  it("signals episodes-changed even if the document becomes hidden mid-refresh", async () => {
    let hidden = false;
    let resolveRefresh!: (v: { refreshed: number; errors: number }) => void;
    const pending = new Promise<{ refreshed: number; errors: number }>((r) => {
      resolveRefresh = r;
    });
    Object.defineProperty(document, "hidden", { configurable: true, get: () => hidden });
    installApi({
      ...shellRoutes,
      "POST /api/refresh": () => pending,
    });

    render(<App />);
    await screen.findByText("Fresh Episode");

    await act(async () => {
      await vi.advanceTimersByTimeAsync(AUTO_REFRESH_INTERVAL_MS);
    });

    hidden = true;
    document.dispatchEvent(new Event("visibilitychange"));
    resolveRefresh({ refreshed: 2, errors: 0 });
    await act(async () => {
      await Promise.resolve();
    });
    expect(changed as ReturnType<typeof vi.fn>).toHaveBeenCalled();
  });
});
