import { beforeEach, afterEach, expect, it, vi } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";
import { emptyState } from "../offline/store";
import type { ProcessingNotification } from "../types";
import * as client from "../offline/client";
import {
  COMPACT_NOTIFICATION_LIMIT,
  NotificationsView,
  ProcessingNotifications,
  failureAreaLabel,
  failureOutcomeLabel,
} from "./NotificationsView";

vi.mock("../offline/client", () => ({ state: vi.fn(), clearNotifications: vi.fn() }));

function notice(overrides: Partial<ProcessingNotification> = {}): ProcessingNotification {
  return {
    id: 4,
    episode_id: 1,
    category: "ad_classification",
    failed_stage: "classifying",
    message: "Ad classification failed.",
    outcome: "retry",
    created_at: 1_700_000_000,
    episode_title: "Alpha Hour",
    podcast_title: "Example",
    ...overrides,
  };
}

beforeEach(() => {
  window.location.hash = "";
  vi.mocked(client.state).mockResolvedValue(emptyState());
});
afterEach(() => vi.clearAllMocks());

it("renders nothing when notifications are omitted or empty", async () => {
  const missing = render(<ProcessingNotifications />);
  expect(missing.container).toBeEmptyDOMElement();
  fireEvent(window, new Event("pods-offline-changed"));
  await vi.waitFor(() => expect(client.state).toHaveBeenCalled());
  expect(missing.container).toBeEmptyDOMElement();
  missing.unmount();

  const local = emptyState();
  local.snapshot = { version: 1, cursor: 1, replace: true, shows: [], episodes: [], settings: {}, versions: {}, notifications: [] };
  vi.mocked(client.state).mockResolvedValue(local);
  const empty = render(<ProcessingNotifications />);
  fireEvent(window, new Event("pods-offline-changed"));
  await vi.waitFor(() => expect(empty.container).toBeEmptyDOMElement());
});

it("shows only the newest bar and opens the notifications route", async () => {
  const local = emptyState();
  local.snapshot = {
    version: 1, cursor: 1, replace: true, shows: [], episodes: [], settings: {}, versions: {},
    notifications: [
      notice({ id: 5, episode_title: "Newest", category: "show_notes", message: "Show-note generation failed." }),
      notice({ id: 4, episode_title: "Second", category: "ad_classification" }),
      notice({ id: 3, episode_title: "Third", category: "speech_to_text", message: "Speech-to-text failed." }),
      notice({ id: 2, episode_title: "Hidden", category: "audio_download", message: "Audio download failed." }),
    ],
  };
  vi.mocked(client.state).mockResolvedValue(local);
  render(<ProcessingNotifications />);
  fireEvent(window, new Event("pods-offline-changed"));
  expect(await screen.findByText("Newest")).toBeInTheDocument();
  expect(screen.queryByText("Second")).not.toBeInTheDocument();
  expect(screen.queryByText("Third")).not.toBeInTheDocument();
  expect(screen.queryByText("Hidden")).not.toBeInTheDocument();
  const titles = [...document.querySelectorAll(".notification-bar-title")].map((node) => node.textContent);
  expect(titles).toEqual(["Newest"]);
  expect(titles).toHaveLength(COMPACT_NOTIFICATION_LIMIT);
  fireEvent.click(screen.getByRole("button", { name: "Open 4 processing failure notifications" }));
  expect(window.location.hash).toBe("#/notifications");
});

it("lists every notification newest first and returns to Listen", async () => {
  const local = emptyState();
  local.snapshot = {
    version: 1, cursor: 1, replace: true, shows: [], episodes: [], settings: {}, versions: {},
    notifications: [
      notice({ id: 2, episode_title: "Older", podcast_title: "Show A", category: "audio_download", failed_stage: "downloading", message: "Audio download failed.", outcome: "blocked" }),
      notice({ id: 1, episode_title: "Oldest", podcast_title: "Show B", category: "speech_to_text", failed_stage: "transcribing", message: "Speech-to-text failed.", outcome: "retry" }),
      notice({ id: 3, episode_title: "Newest", podcast_title: "Show C", category: "show_notes", failed_stage: "show_notes", message: "Show-note generation failed.", outcome: "retry" }),
    ],
  };
  vi.mocked(client.state).mockResolvedValue(local);
  window.location.hash = "#/notifications";
  render(<NotificationsView />);
  fireEvent(window, new Event("pods-offline-changed"));
  expect(await screen.findByRole("heading", { name: "Notifications" })).toBeInTheDocument();
  const rows = screen.getAllByRole("listitem");
  expect(rows).toHaveLength(3);
  expect(rows[0]).toHaveTextContent("Newest");
  expect(rows[0]).toHaveTextContent("Show C");
  expect(rows[0]).toHaveTextContent(failureAreaLabel("show_notes"));
  expect(rows[0]).toHaveTextContent(failureOutcomeLabel("retry"));
  expect(rows[0]).toHaveTextContent("Show-note generation failed.");
  expect(rows[1]).toHaveTextContent("Older");
  expect(rows[1]).toHaveTextContent(failureAreaLabel("audio_download"));
  expect(rows[1]).toHaveTextContent(failureOutcomeLabel("blocked"));
  expect(rows[2]).toHaveTextContent("Oldest");
  expect(rows[2]).toHaveTextContent(failureAreaLabel("speech_to_text"));
  expect(screen.getByRole("button", { name: "Back to Listen" })).toHaveClass("icon-btn");
  fireEvent.click(screen.getByRole("button", { name: "Back to Listen" }));
  expect(window.location.hash).toBe("#/recent");
});


it("clears the displayed list and hides the Listen notice after the saved state changes", async () => {
  const local = emptyState();
  local.snapshot = { version: 1, cursor: 1, replace: true, shows: [], episodes: [], settings: {}, versions: {},
    notifications: [notice({ id: 5 }), notice({ id: 4 })] };
  vi.mocked(client.state).mockResolvedValue(local);
  vi.mocked(client.clearNotifications).mockImplementation(async through => {
    local.notificationsClearedThrough = through;
    window.dispatchEvent(new Event("pods-offline-changed"));
  });
  const view = render(<><NotificationsView /><ProcessingNotifications /></>);
  fireEvent.click(await screen.findByRole("button", { name: "Clear all" }));
  await screen.findByText("No processing failures.");
  expect(client.clearNotifications).toHaveBeenCalledWith(5);
  expect(screen.queryByRole("button", { name: /Open .* processing failure/ })).not.toBeInTheDocument();
  expect(screen.queryByRole("button", { name: "Clear all" })).not.toBeInTheDocument();
  view.unmount();
  render(<><NotificationsView /><ProcessingNotifications /></>);
  await vi.waitFor(() => expect(screen.queryByRole("listitem")).not.toBeInTheDocument());
});

it("keeps entries visible and offers retry if saving the dismissal fails", async () => {
  const local = emptyState();
  local.snapshot = { version: 1, cursor: 1, replace: true, shows: [], episodes: [], settings: {}, versions: {}, notifications: [notice()] };
  vi.mocked(client.state).mockResolvedValue(local);
  vi.mocked(client.clearNotifications).mockRejectedValueOnce(new Error("Storage unavailable"));
  render(<NotificationsView />);
  fireEvent.click(await screen.findByRole("button", { name: "Clear all" }));
  expect(await screen.findByRole("alert")).toHaveTextContent("Could not clear notifications. Try again.");
  expect(screen.getByRole("listitem")).toHaveTextContent("Alpha Hour");
  expect(screen.getByRole("button", { name: "Clear all" })).toBeEnabled();
});
