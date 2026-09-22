import { beforeEach, afterEach, expect, it, vi } from "vitest";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { OfflineSettings } from "./Controls";
import { emptyState, type Snapshot } from "./store";
import * as client from "./client";
import * as downloads from "./downloads";
import * as store from "./store";
import { Api } from "../api";
import * as passkey from "../passkey";

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
