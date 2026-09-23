import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { emptyState } from "../offline/store";
import * as client from "../offline/client";
import * as feedback from "../feedback";
import { FeedbackView } from "./FeedbackView";

vi.mock("../offline/client", () => ({ state: vi.fn() }));
vi.mock("../feedback", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../feedback")>();
  return { ...actual, submitFeedback: vi.fn() };
});

beforeEach(() => {
  window.location.hash = "";
  vi.mocked(client.state).mockResolvedValue(emptyState());
  vi.mocked(feedback.submitFeedback).mockResolvedValue("report-1");
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
