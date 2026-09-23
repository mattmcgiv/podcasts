import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { emptyState } from "../offline/store";
import * as client from "../offline/client";
import * as feedback from "../feedback";
import * as voice from "../voice";
import { FeedbackView } from "./FeedbackView";

vi.mock("../offline/client", () => ({ state: vi.fn() }));
vi.mock("../feedback", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../feedback")>();
  return { ...actual, submitFeedback: vi.fn() };
});
vi.mock("../voice", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../voice")>();
  return {
    ...actual,
    listVoiceDrafts: vi.fn(async () => []),
    saveVoiceDraft: vi.fn(async () => ({ id: "voice-1", mime: "audio/webm", createdAt: 1, bytes: new Uint8Array(), phase: "saved" as const })),
    deleteVoiceDraft: vi.fn(async () => {}),
    markVoicePlaced: vi.fn(async () => {}),
    flushVoiceDrafts: vi.fn(async () => {}),
    startCapture: vi.fn(),
  };
});

beforeEach(() => {
  window.location.hash = "";
  vi.mocked(client.state).mockResolvedValue(emptyState());
  vi.mocked(feedback.submitFeedback).mockResolvedValue("report-1");
  vi.mocked(voice.listVoiceDrafts).mockResolvedValue([]);
  vi.mocked(voice.saveVoiceDraft).mockResolvedValue({ id: "voice-1", mime: "audio/webm", createdAt: 1, bytes: new Uint8Array(), phase: "saved" });
  vi.mocked(voice.deleteVoiceDraft).mockResolvedValue();
  vi.mocked(voice.markVoicePlaced).mockResolvedValue();
  vi.mocked(voice.flushVoiceDrafts).mockResolvedValue();
  vi.mocked(voice.startCapture).mockReset();
});

afterEach(() => vi.clearAllMocks());

it("switches the report type and sends a trimmed report", async () => {
  const user = userEvent.setup();
  render(<FeedbackView />);
  expect(screen.getByRole("button", { name: "Send" })).toBeDisabled();

  await user.click(screen.getByRole("button", { name: "Bug report" }));
  expect(screen.getByPlaceholderText("What went wrong?")).toBeInTheDocument();
  await user.type(screen.getByLabelText(/Describe it/), "crash on launch");
  await user.click(screen.getByRole("button", { name: "Send" }));

  expect(feedback.submitFeedback).toHaveBeenCalledWith("bug", "crash on launch");
  expect(await screen.findByText("Saved. It syncs to the Mac when connected.")).toBeInTheDocument();
  expect(screen.getByLabelText(/Describe it/)).toHaveValue("");
});

it("shows a send failure without clearing the draft", async () => {
  vi.mocked(feedback.submitFeedback).mockRejectedValue(new Error("storage full"));
  const user = userEvent.setup();
  render(<FeedbackView />);

  await user.type(screen.getByLabelText(/Describe it/), "dark mode");
  await user.click(screen.getByRole("button", { name: "Send" }));

  expect(await screen.findByText("storage full")).toBeInTheDocument();
  expect(screen.getByLabelText(/Describe it/)).toHaveValue("dark mode");
});

it("counts down only when the draft nears the limit", async () => {
  const user = userEvent.setup();
  render(<FeedbackView />);
  const field = screen.getByLabelText(/Describe it/);

  await user.type(field, "short");
  expect(screen.queryByText(/characters left/)).not.toBeInTheDocument();

  fireEvent.change(field, { target: { value: "x".repeat(3950) } });
  expect(screen.getByText("50 characters left")).toBeInTheDocument();
});

it("lists pending reports and Mac dispatch states", async () => {
  const local = emptyState();
  local.outbox = [
    {
      id: "op-1", sequence: 1, entity: "feedback", field: "pending-1",
      value: { kind: "feature", body: "Dark mode", created_at: 30 }, base_revision: 0,
    },
    {
      id: "op-2", sequence: 2, entity: "feedback", field: "pending-2",
      value: { kind: "bug", body: "Stuck sync", created_at: 20 }, base_revision: 0, error: "report too long",
    },
  ];
  local.snapshot = {
    version: 1, cursor: 1, replace: true, shows: [], episodes: [], settings: {}, versions: {},
    feedback: [
      { id: "sent-1", kind: "bug", status: "running", created_at: 1_700_000_000 },
      { id: "sent-2", kind: "feature", status: "done", created_at: 0 },
    ],
  };
  vi.mocked(client.state).mockResolvedValue(local);
  render(<FeedbackView />);

  expect(await screen.findByText("Waiting to sync")).toBeInTheDocument();
  expect(screen.getByText("Dark mode")).toBeInTheDocument();
  expect(screen.getByText(/the Mac rejected it/)).toBeInTheDocument();
  expect(screen.getByText("report too long")).toBeInTheDocument();
  expect(screen.getByText("On the Mac")).toBeInTheDocument();
  expect(screen.getByText("Bug report — The Mac is working on it")).toBeInTheDocument();
  expect(screen.getByText("Feature request — Fixed on the Mac")).toBeInTheDocument();
});

it("hides the history sections when there is nothing to show", async () => {
  render(<FeedbackView />);
  await screen.findByText("New report");
  expect(screen.queryByText("Waiting to sync")).not.toBeInTheDocument();
  expect(screen.queryByText("On the Mac")).not.toBeInTheDocument();
});

it("returns to Settings", async () => {
  const user = userEvent.setup();
  render(<FeedbackView />);
  await user.click(screen.getByRole("button", { name: "Settings" }));
  expect(window.location.hash).toBe("#/settings");
});

function blobResult(elapsedMs = 1500) {
  return { blob: new Blob([new Uint8Array(40)]), mime: "audio/webm", elapsedMs };
}

it("shows a denial without starting a recording", async () => {
  vi.mocked(voice.startCapture).mockRejectedValue(new Error("The microphone is blocked. Allow it for this site, then try again."));
  const user = userEvent.setup();
  render(<FeedbackView />);
  await user.click(screen.getByRole("button", { name: "Dictate a report" }));
  expect(await screen.findByText(/microphone is blocked/)).toBeInTheDocument();
  expect(screen.queryByRole("button", { name: "Stop" })).not.toBeInTheDocument();
});

it("shows the recording clock and can cancel without saving", async () => {
  const live = { elapsedMs: () => 4000, stop: vi.fn(async () => blobResult()), cancel: vi.fn() };
  vi.mocked(voice.startCapture).mockResolvedValue(live);
  const user = userEvent.setup();
  render(<FeedbackView />);
  await user.click(screen.getByRole("button", { name: "Dictate a report" }));
  expect(await screen.findByRole("group", { name: "Recording 0:04" })).toBeInTheDocument();
  expect(screen.queryByRole("button", { name: "Send" })).not.toBeInTheDocument();
  await user.click(screen.getByRole("button", { name: "Cancel" }));
  expect(live.cancel).toHaveBeenCalled();
  expect(voice.saveVoiceDraft).not.toHaveBeenCalled();
  expect(screen.getByRole("button", { name: "Dictate a report" })).toBeInTheDocument();
});

it("saves a stopped recording on this phone before the Mac is involved", async () => {
  const live = { elapsedMs: () => 2000, stop: vi.fn(async () => blobResult(2000)), cancel: vi.fn() };
  vi.mocked(voice.startCapture).mockResolvedValue(live);
  const user = userEvent.setup();
  render(<FeedbackView />);
  await user.click(screen.getByRole("button", { name: "Dictate a report" }));
  await user.click(await screen.findByRole("button", { name: "Stop" }));
  expect(await screen.findByText("Saved on this phone. It transcribes when the Mac is connected.")).toBeInTheDocument();
  expect(voice.saveVoiceDraft).toHaveBeenCalledWith(expect.any(Blob), "audio/webm");
});

it("rejects a recording that is too short to keep", async () => {
  vi.mocked(voice.startCapture).mockResolvedValue({
    elapsedMs: () => 200,
    stop: vi.fn(async () => "short" as const),
    cancel: vi.fn(),
  });
  const user = userEvent.setup();
  render(<FeedbackView />);
  await user.click(screen.getByRole("button", { name: "Dictate a report" }));
  await user.click(await screen.findByRole("button", { name: "Stop" }));
  expect(await screen.findByText(/too short/)).toBeInTheDocument();
  expect(voice.saveVoiceDraft).not.toHaveBeenCalled();
});

it("stops at two minutes and keeps the recording", async () => {
  vi.mocked(voice.startCapture).mockResolvedValue({
    elapsedMs: () => voice.VOICE_MAX_MS,
    stop: vi.fn(async () => blobResult(voice.VOICE_MAX_MS)),
    cancel: vi.fn(),
  });
  render(<FeedbackView />);
  const user = userEvent.setup();
  await user.click(screen.getByRole("button", { name: "Dictate a report" }));
  expect(await screen.findByText(/Stopped at 2 minutes/)).toBeInTheDocument();
  expect(voice.saveVoiceDraft).toHaveBeenCalled();
});

it("drops a ready transcript into the composer for one tap to send", async () => {
  vi.mocked(voice.listVoiceDrafts).mockResolvedValue([{
    id: "v1", mime: "audio/webm", createdAt: 10, bytes: new Uint8Array(), phase: "ready", transcript: "Add a sleep timer",
  }]);
  const user = userEvent.setup();
  render(<FeedbackView />);
  expect(await screen.findByDisplayValue("Add a sleep timer")).toBeInTheDocument();
  expect(voice.markVoicePlaced).toHaveBeenCalledWith("v1");
  await user.click(screen.getByRole("button", { name: "Send" }));
  expect(feedback.submitFeedback).toHaveBeenCalledWith("feature", "Add a sleep timer");
  expect(voice.deleteVoiceDraft).toHaveBeenCalledWith("v1");
});

it("lets a placed transcript replace whatever is in the composer", async () => {
  vi.mocked(voice.listVoiceDrafts).mockResolvedValue([{
    id: "v2", mime: "audio/webm", createdAt: 10, bytes: new Uint8Array(), phase: "ready", transcript: "Fix the pause button", placed: true,
  }]);
  const user = userEvent.setup();
  render(<FeedbackView />);
  await user.type(await screen.findByLabelText(/Describe it/), "typed first");
  await user.click(screen.getByRole("button", { name: "Use transcript" }));
  expect(screen.getByLabelText(/Describe it/)).toHaveValue("Fix the pause button");
});

it("stays usable when the library, the voice list, or a transcription check fails", async () => {
  vi.mocked(client.state).mockRejectedValue(new Error("library closed"));
  vi.mocked(voice.listVoiceDrafts).mockRejectedValue(new Error("voice closed"));
  vi.mocked(voice.flushVoiceDrafts).mockRejectedValue(new Error("offline"));
  vi.useFakeTimers();
  render(<FeedbackView />);
  await act(async () => { await vi.advanceTimersByTimeAsync(3_000); });
  expect(screen.getByText("New report")).toBeInTheDocument();
  expect(vi.mocked(voice.flushVoiceDrafts).mock.calls.length).toBeGreaterThanOrEqual(2);
  vi.useRealTimers();
});

it("keeps a transcript in the composer when marking it placed fails", async () => {
  vi.mocked(voice.listVoiceDrafts).mockResolvedValue([{
    id: "v4", mime: "audio/webm", createdAt: 10, bytes: new Uint8Array(), phase: "ready", transcript: "Remember this",
  }]);
  vi.mocked(voice.markVoicePlaced).mockRejectedValue(new Error("storage"));
  render(<FeedbackView />);
  expect(await screen.findByDisplayValue("Remember this")).toBeInTheDocument();
  await waitFor(() => expect(voice.markVoicePlaced).toHaveBeenCalledWith("v4"));
});

it("sends the report when the voice list or its cleanup fails", async () => {
  vi.mocked(voice.listVoiceDrafts)
    .mockResolvedValueOnce([])
    .mockRejectedValueOnce(new Error("voice closed"));
  const user = userEvent.setup();
  render(<FeedbackView />);
  await user.type(await screen.findByLabelText(/Describe it/), "still send this");
  await user.click(screen.getByRole("button", { name: "Send" }));
  expect(await screen.findByText("Saved. It syncs to the Mac when connected.")).toBeInTheDocument();

  vi.mocked(voice.listVoiceDrafts).mockResolvedValue([{
    id: "v5", mime: "audio/webm", createdAt: 10, bytes: new Uint8Array(), phase: "ready",
    transcript: "still send this", placed: true,
  }]);
  vi.mocked(voice.deleteVoiceDraft).mockRejectedValue(new Error("storage"));
  await user.type(screen.getByLabelText(/Describe it/), "still send this");
  await user.click(screen.getByRole("button", { name: "Send" }));
  expect(await screen.findByText("Saved. It syncs to the Mac when connected.")).toBeInTheDocument();
});

it("says when a recording cannot be discarded", async () => {
  vi.mocked(voice.listVoiceDrafts).mockResolvedValue([{
    id: "v6", mime: "audio/webm", createdAt: 10, bytes: new Uint8Array(), phase: "failed", error: "The Mac could not transcribe it.",
  }]);
  vi.mocked(voice.deleteVoiceDraft).mockRejectedValue(new Error("storage"));
  const user = userEvent.setup();
  render(<FeedbackView />);
  await user.click(await screen.findByRole("button", { name: "Discard" }));
  expect(await screen.findByText("Could not discard that recording.")).toBeInTheDocument();
});

it("shows a failed transcription and can discard it", async () => {
  vi.mocked(voice.listVoiceDrafts).mockResolvedValue([{
    id: "v3", mime: "audio/webm", createdAt: 10, bytes: new Uint8Array(), phase: "failed", error: "Could not hear any speech. Try again.",
  }]);
  const user = userEvent.setup();
  render(<FeedbackView />);
  expect(await screen.findByText("Could not hear any speech. Try again.")).toBeInTheDocument();
  await user.click(screen.getByRole("button", { name: "Discard" }));
  expect(voice.deleteVoiceDraft).toHaveBeenCalledWith("v3");
});
