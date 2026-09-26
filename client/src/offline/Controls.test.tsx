import { beforeEach, afterEach, describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { IDBFactory } from "fake-indexeddb";
import { OfflineSettings, changeDescription, exportSyncBackup } from "./Controls";
import { emptyState, type Snapshot } from "./store";
import * as client from "./client";
import * as downloads from "./downloads";
import * as store from "./store";
import { Api } from "../api";
import * as passkey from "../passkey";
import type { EpisodeDetail } from "../types";

vi.mock("./client", () => ({ state: vi.fn(), defaultDeviceName: () => "Browser", resolveConflict: vi.fn(), synchronize: vi.fn(), syncError: vi.fn(), offlineEnabled: () => false }));
vi.mock("./downloads", () => ({ downloadError: vi.fn(), prefetch: vi.fn(), savePreferences: vi.fn() }));
vi.mock("./store", async original => ({ ...await original<typeof import("./store")>(), allDownloads: vi.fn() }));
vi.mock("../passkey", () => ({ assertPasskey: vi.fn() }));

beforeEach(() => {
  vi.mocked(client.state).mockResolvedValue(emptyState());
  vi.mocked(store.allDownloads).mockResolvedValue([]);
  vi.mocked(client.synchronize).mockResolvedValue();
  vi.mocked(client.resolveConflict).mockResolvedValue();
  vi.mocked(downloads.savePreferences).mockResolvedValue();
  vi.mocked(downloads.prefetch).mockResolvedValue();
  vi.mocked(downloads.downloadError).mockReturnValue(null);
  vi.mocked(client.syncError).mockReturnValue(null);
});
afterEach(() => vi.clearAllMocks());

function processingSnapshot(pending: number, failed: number, blocked: number, storageBlocked = false) {
  return { version: 1, cursor: 1, replace: true, shows: [], episodes: [], settings: {}, versions: {},
    processing: { pending, failed, blocked, storage: { used: 0, limit: 1, free: 0, blocked: storageBlocked } } };
}

describe("changeDescription", () => {
  it("renders positions, plays, last-listened, and raw values", () => {
    const local = emptyState();
    local.snapshot = { version: 1, cursor: 0, replace: true, shows: [], settings: {}, versions: {},
      episodes: [{ id: 7, title: "Seven" } as unknown as EpisodeDetail] };
    expect(changeDescription(local, "1", "position", { seconds: 65 })).toBe("1:05");
    expect(changeDescription(local, "1", "position", null)).toBe("0:00");
    expect(changeDescription(local, "1", "played", true)).toBe("Played");
    expect(changeDescription(local, "1", "played", null)).toBe("Unplayed");
    expect(changeDescription(local, "settings", "last_listened", 7)).toBe("Seven");
    expect(changeDescription(local, "settings", "last_listened", 9)).toBe("Last-listened episode");
    expect(changeDescription(local, "settings", "speed", 1.5)).toBe("1.5");
  });
});

describe("exportSyncBackup", () => {
  it("downloads the library as JSON and releases the object URL", async () => {
    vi.useFakeTimers();
    try {
      const create = vi.fn((_blob: Blob) => "blob:backup");
      const revoke = vi.fn();
      Object.defineProperty(URL, "createObjectURL", { configurable: true, value: create });
      Object.defineProperty(URL, "revokeObjectURL", { configurable: true, value: revoke });
      const click = vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(() => {});
      const local = emptyState();
      vi.mocked(client.state).mockResolvedValue(local);
      await exportSyncBackup();
      expect(create).toHaveBeenCalledTimes(1);
      const blob = create.mock.calls[0][0] as Blob;
      expect(await blob.text()).toContain("pods-state-backup-v1");
      expect(click).toHaveBeenCalled();
      expect(revoke).not.toHaveBeenCalled();
      await vi.advanceTimersByTimeAsync(1000);
      expect(revoke).toHaveBeenCalledWith("blob:backup");
    } finally {
      vi.useRealTimers();
    }
  });
});

it("reports blocked automatic processing without a review instruction", async () => {
  const local = emptyState();
  local.lastSync = 10000;
  local.snapshot = processingSnapshot(1, 1, 1);
  vi.mocked(client.state).mockResolvedValue(local);
  const settings = render(<OfflineSettings />);
  expect(await screen.findByText(/1 episode pending on Mac, 1 failed and retrying, 1 episode could not be processed automatically/)).toBeInTheDocument();
  expect(settings.container.textContent).not.toMatch(/review|awaiting review|need ad-removal review/i);
});

it("treats a cached snapshot with no blocked field as zero and ignores review", async () => {
  const local = emptyState();
  local.lastSync = 10000;
  local.snapshot = {
    version: 1, cursor: 1, replace: true, shows: [], episodes: [], settings: {}, versions: {},
    processing: { pending: 4, failed: 1, review: 7, storage: { used: 0, limit: 1, free: 0, blocked: false } } as Snapshot["processing"],
  };
  expect(local.snapshot.processing && "blocked" in local.snapshot.processing).toBe(false);
  vi.mocked(client.state).mockResolvedValue(local);
  const settings = render(<OfflineSettings />);
  const summary = await screen.findByText(/4 episodes pending on Mac, 1 failed and retrying, 0 episodes could not be processed automatically/);
  expect(summary.textContent).not.toMatch(/undefined|review|\b7\b/);
  expect(settings.container.textContent).not.toMatch(/undefined|review/i);
});

it("shows Syncing while a tap waits on the Mac", async () => {
  vi.mocked(client.state).mockResolvedValue({ ...emptyState(), lastSync: 1 });
  let finish: () => void = () => {};
  vi.mocked(client.synchronize).mockReturnValue(new Promise(resolve => { finish = () => resolve(); }));
  render(<OfflineSettings />);
  fireEvent.click(await screen.findByRole("button", { name: "Sync now" }));
  expect(await screen.findByRole("button", { name: "Syncing…" })).toBeDisabled();
  expect(screen.getByRole("button", { name: "Syncing…" })).toHaveAttribute("aria-busy", "true");
  expect(screen.getByRole("status")).toHaveTextContent("Syncing…");
  finish();
  await waitFor(() => expect(screen.getByRole("button", { name: "Sync now" })).toBeEnabled());
  expect(screen.getByRole("status")).toHaveTextContent("Done.");
});

it("synchronizes, changes limits, signs in, and resolves both conflict choices", async () => {
  const s = emptyState(); s.lastSync = 10000;
  s.outbox = [{ id: "a", sequence: 1, entity: "1", field: "played", value: true, base_revision: 0, conflict: 1 }];
  vi.mocked(client.state).mockResolvedValue(s);
  vi.mocked(store.allDownloads).mockResolvedValue([{ hash: "hash", episode: 1, bytes: 100, complete: true, touched: 0 }]);
  vi.spyOn(Api, "loginOptions").mockResolvedValue({ state_id: "login", publicKey: {} });
  vi.mocked(passkey.assertPasskey).mockResolvedValue({ id: "credential" } as never);
  vi.spyOn(Api, "login").mockResolvedValue({ enrolled: true, session: true });
  const settings = render(<OfflineSettings />);
  await screen.findByText(/1 downloaded episodes/);
  expect(settings.container.textContent).not.toMatch(/pin|unpin|remove download/i);
  fireEvent.click(screen.getByRole("button", { name: "Sync now" }));
  await waitFor(() => expect(downloads.prefetch).toHaveBeenCalled());
  await waitFor(() => expect(screen.getByRole("button", { name: "Sign in to Mac" })).toBeEnabled());
  fireEvent.click(screen.getByRole("button", { name: "Sign in to Mac" }));
  await waitFor(() => expect(Api.login).toHaveBeenCalledWith("login", { id: "credential" }));
  await waitFor(() => expect(screen.getByRole("button", { name: "Keep this device’s change" })).toBeEnabled());
  fireEvent.click(screen.getByRole("button", { name: "Keep this device’s change" }));
  await waitFor(() => expect(client.resolveConflict).toHaveBeenCalledWith("a", true));
  await waitFor(() => expect(screen.getByRole("button", { name: "Use the shared change" })).toBeEnabled());
  fireEvent.click(screen.getByRole("button", { name: "Use the shared change" }));
  await waitFor(() => expect(client.resolveConflict).toHaveBeenCalledWith("a", false));
  fireEvent.change(screen.getByLabelText("Automatic episodes"), { target: { value: "5" } });
  await waitFor(() => expect(downloads.savePreferences).toHaveBeenCalledWith({ ...s.preferences, count: 5 }));
  fireEvent.change(screen.getByLabelText("Storage limit (GiB)"), { target: { value: "3" } });
  await waitFor(() => expect(downloads.savePreferences).toHaveBeenCalledWith({ ...s.preferences, limit: 3 * 1024 ** 3 }));
  vi.mocked(client.synchronize).mockRejectedValue(new Error("Offline"));
  await waitFor(() => expect(screen.getByRole("button", { name: "Sync now" })).toBeEnabled());
  fireEvent.click(screen.getByRole("button", { name: "Sync now" }));
  await waitFor(() => expect(screen.getByRole("status")).toHaveTextContent("Offline"));
});

it("renames the device and falls back to the default name when cleared", async () => {
  vi.stubGlobal("indexedDB", new IDBFactory());
  const local = emptyState();
  local.device_name = "Old";
  vi.mocked(client.state).mockResolvedValue(local);
  render(<OfflineSettings />);
  const input = await screen.findByLabelText("Device name");
  fireEvent.blur(input, { target: { value: "  Travel Phone  " } });
  await waitFor(() => expect(screen.getByRole("status")).toHaveTextContent("Done."));
  fireEvent.blur(input, { target: { value: "   " } });
  await waitFor(() => expect(screen.getByRole("status")).toHaveTextContent("Done."));
  vi.unstubAllGlobals();
});

it("exports a state backup from the settings button", async () => {
  const create = vi.fn(() => "blob:ui-backup");
  const revoke = vi.fn();
  Object.defineProperty(URL, "createObjectURL", { configurable: true, value: create });
  Object.defineProperty(URL, "revokeObjectURL", { configurable: true, value: revoke });
  vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(() => {});
  render(<OfflineSettings />);
  fireEvent.click(await screen.findByRole("button", { name: "Export state backup" }));
  await waitFor(() => expect(screen.getByRole("status")).toHaveTextContent("Done."));
  expect(create).toHaveBeenCalledTimes(1);
});

it("names both sides of position, setting, played, and subscription conflicts", async () => {
  const local = emptyState();
  local.device_name = "Travel Phone";
  local.snapshot = { version: 1, cursor: 1, replace: true, shows: [], settings: { speed: 1.5 }, versions: {},
    episodes: [{ id: 1, title: "Ep One", position_secs: 30, played_at: 5 } as unknown as EpisodeDetail],
    writers: { "1:position": { device: "Mac", updated_at: 1 } } };
  local.outbox = [
    { id: "c1", sequence: 1, entity: "1", field: "position", value: { seconds: 65 }, base_revision: 0, conflict: 1 },
    { id: "c2", sequence: 2, entity: "settings", field: "speed", value: 2, base_revision: 0, conflict: 1 },
    { id: "c3", sequence: 3, entity: "1", field: "played", value: true, base_revision: 0, conflict: 1 },
    { id: "c4", sequence: 4, entity: "1", field: "subscription", value: "x", base_revision: 0, conflict: 1 },
  ];
  vi.mocked(client.state).mockResolvedValue(local);
  render(<OfflineSettings />);
  expect(await screen.findAllByText("Ep One: this device and the shared library both changed this.")).toHaveLength(3);
  expect(screen.getByText("Travel Phone: 1:05")).toBeInTheDocument();
  expect(screen.getByText("Mac: 0:30")).toBeInTheDocument();
  expect(screen.getByText("speed: this device and the shared library both changed this.")).toBeInTheDocument();
  expect(screen.getByText("Shared library: 1.5")).toBeInTheDocument();
  expect(screen.getByText("Travel Phone: Played")).toBeInTheDocument();
  expect(screen.getByText("Shared library: Played")).toBeInTheDocument();
  expect(screen.getByText("Shared library: Subscription")).toBeInTheDocument();
});

it("retries or discards changes the Mac rejected", async () => {
  const local = emptyState();
  local.outbox = [{ id: "e1", sequence: 1, entity: "1", field: "played", value: true, base_revision: 0, error: "409 Conflict." }];
  vi.mocked(client.state).mockResolvedValue(local);
  render(<OfflineSettings />);
  expect(await screen.findByRole("alert")).toHaveTextContent("409 Conflict. The change is still saved on this device.");
  fireEvent.click(screen.getByRole("button", { name: "Try again" }));
  await waitFor(() => expect(client.resolveConflict).toHaveBeenCalledWith("e1", true));
  await waitFor(() => expect(screen.getByRole("button", { name: "Discard this change" })).toBeEnabled());
  fireEvent.click(screen.getByRole("button", { name: "Discard this change" }));
  await waitFor(() => expect(client.resolveConflict).toHaveBeenCalledWith("e1", false));
});
