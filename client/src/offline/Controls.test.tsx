import { beforeEach, afterEach, describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { IDBFactory } from "fake-indexeddb";
import { OfflineSettings, changeDescription, exportSyncBackup, exportDiagnostics } from "./Controls";
import { emptyState, type Snapshot } from "./store";
import * as client from "./client";
import * as downloads from "./downloads";
import * as store from "./store";
import { Api } from "../api";
import * as passkey from "../passkey";
import * as diagnostics from "./diagnostics";
import type { EpisodeDetail } from "../types";

vi.mock("./client", () => ({ state: vi.fn(), defaultDeviceName: () => "Browser", resolveConflict: vi.fn(), synchronize: vi.fn(), network: vi.fn(), syncError: vi.fn(), offlineEnabled: () => false }));
vi.mock("./downloads", () => ({ downloadError: vi.fn(), prefetch: vi.fn(), savePreferences: vi.fn() }));
vi.mock("./store", async original => ({ ...await original<typeof import("./store")>(), allDownloads: vi.fn() }));
vi.mock("../passkey", () => ({ assertPasskey: vi.fn() }));

beforeEach(() => {
  vi.mocked(client.state).mockResolvedValue(emptyState());
  vi.mocked(store.allDownloads).mockResolvedValue([]);
  vi.mocked(client.synchronize).mockResolvedValue();
  vi.mocked(client.network).mockResolvedValue({ status: "ok" });
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
  s.preferences.automatic = false;
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

it("defaults to all unplayed episodes and retains custom limits when switching modes", async () => {
  const local = emptyState();
  vi.mocked(client.state).mockResolvedValue(local);
  render(<OfflineSettings />);
  expect(await screen.findByRole("checkbox", { name: "Download all unplayed episodes" })).toBeChecked();
  expect(screen.queryByLabelText("Storage limit (GiB)")).not.toBeInTheDocument();
  fireEvent.click(screen.getByRole("checkbox", { name: "Download all unplayed episodes" }));
  await waitFor(() => expect(downloads.savePreferences).toHaveBeenCalledWith({ ...local.preferences, automatic: false }));
  local.preferences.automatic = false;
  vi.mocked(client.state).mockResolvedValue(structuredClone(local));
  window.dispatchEvent(new Event("pods-offline-changed"));
  expect(await screen.findByLabelText("Storage limit (GiB)")).toHaveValue(2);
  fireEvent.click(screen.getByRole("checkbox", { name: "Download all unplayed episodes" }));
  await waitFor(() => expect(downloads.savePreferences).toHaveBeenCalledWith({ ...local.preferences, automatic: true }));
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

it("recovers a failed local status read without clearing data", async () => {
  vi.mocked(client.state).mockRejectedValueOnce(new Error("storage unavailable"));
  render(<OfflineSettings />);
  expect(await screen.findByRole("alert")).toHaveTextContent("Local library status could not be read");
  fireEvent.click(screen.getByRole("button",{name:"Retry local status"}));
  expect(await screen.findByRole("button",{name:"Sync now"})).toBeEnabled();
});

it("shows independent failures and persistent processing status with retry", async () => {
  const local=emptyState();
  local.snapshot={...processingSnapshot(1,0,1),pipeline:{observedAt:100,recent:[{id:"old",episodeId:2,title:"Recovered",published:true}],workerError:"Worker failed",items:[{
    id:"intake-1",episodeId:0,title:"Submitted video",podcastTitle:"Listen",stage:"blocked",state:"needs_attention",statusLabel:"Needs attention",message:"The source could not be resolved; link retained.",attempts:12,nextRetryAt:200,updatedAt:100,canRetry:true,stalled:true,
  }]}};
  vi.mocked(client.state).mockResolvedValue(local);
  vi.mocked(client.syncError).mockReturnValue("Mac unavailable");
  vi.mocked(downloads.downloadError).mockReturnValue("Storage full");
  render(<OfflineSettings />);
  const retry=await screen.findByRole("button",{name:"Retry Submitted video"});
  expect(screen.getByText("Sync: Mac unavailable")).toBeInTheDocument();
  expect(screen.getByText("Download: Storage full")).toBeInTheDocument();
  expect(screen.getByText(/Recovered · Published/)).toBeInTheDocument();
  expect(screen.getByText(/Worker stopped reporting progress/)).toBeInTheDocument();
  fireEvent.click(retry);
  await waitFor(()=>expect(client.network).toHaveBeenCalledWith("/pipeline/retry",{method:"POST",body:JSON.stringify({id:"intake-1"})}));
  await waitFor(()=>expect(client.synchronize).toHaveBeenCalled());
  await waitFor(()=>expect(retry).toBeEnabled());
  vi.mocked(client.network).mockRejectedValueOnce(new Error("Mac unavailable"));
  fireEvent.click(retry);
  await waitFor(()=>expect(screen.getByRole("status")).toHaveTextContent("Mac unavailable"));
});

it("exports operational diagnostics online and falls back to the saved status offline", async () => {
  const create=vi.fn((_blob:Blob)=>"blob:diagnostics");
  Object.defineProperty(URL,"createObjectURL",{configurable:true,value:create});
  Object.defineProperty(URL,"revokeObjectURL",{configurable:true,value:vi.fn()});
  vi.spyOn(HTMLAnchorElement.prototype,"click").mockImplementation(()=>{});
  vi.spyOn(diagnostics,"readDiagnostics").mockReturnValue([{at:1,kind:"playback-error",detail:"private URL"}]);
  vi.spyOn(diagnostics,"readMediaDiagnostics").mockResolvedValue([{at:2,kind:"media-error",detail:"private URL"}]);
  vi.mocked(store.allDownloads).mockResolvedValue([{hash:"hash",episode:1,bytes:100,received:50,complete:false,touched:0}]);
  const local=emptyState(); local.outbox=[{id:"secret",sequence:1,entity:"feedback",field:"private",value:"private content",base_revision:0}];
  vi.mocked(client.state).mockResolvedValue(local);
  await exportDiagnostics();
  let body=await create.mock.calls[0][0].text();
  expect(body).toContain("pods-diagnostics-v1"); expect(body).not.toContain("private content");
  vi.mocked(client.network).mockRejectedValueOnce(new Error("offline"));
  await exportDiagnostics(); body=await create.mock.calls[1][0].text(); expect(body).toContain('"unavailable": true');
  render(<OfflineSettings />); fireEvent.click(await screen.findByRole("button",{name:"Export diagnostics"}));
  await waitFor(()=>expect(create).toHaveBeenCalledTimes(3));
});

it("renders queued and retrying processing items with empty and stale activity", async () => {
  const local=emptyState();
  local.snapshot={...processingSnapshot(1,1,0),pipeline:{observedAt:100,recent:[],items:[{
    id:"job",episodeId:1,title:"Working",podcastTitle:"Show",stage:"retry",state:"retry_scheduled",statusLabel:"Retry scheduled",message:"Network failed",attempts:1,nextRetryAt:200,updatedAt:100,canRetry:true,
  },{id:"queued",episodeId:0,title:"Queued",podcastTitle:"Listen",stage:"queued",state:"queued",statusLabel:"Queued for processing",message:null,attempts:0,nextRetryAt:null,updatedAt:100,canRetry:false}]}};
  vi.mocked(client.state).mockResolvedValue(local); const view=render(<OfflineSettings />);
  expect(await screen.findByText("Working",{selector:"strong"})).toBeInTheDocument(); expect(screen.getByText(/Queued for processing/)).toBeInTheDocument();
  view.unmount(); local.snapshot.pipeline!.items=[]; render(<OfflineSettings />);
  expect(await screen.findByText("Nothing waiting for processing.")).toBeInTheDocument();
});
