import { act, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";
import { setDownloadProgress } from "../offline/progress";
import { episode } from "../test/mockApi";
import { EpisodeRow } from "./EpisodeRow";

afterEach(() => {
  delete window.PODS_LOCAL_CLIENT;
});

function renderRow(local: boolean) {
  window.PODS_LOCAL_CLIENT = local;
  render(
    <EpisodeRow
      item={episode({
        title: "Model Blocked",
        ad_removal_state: "preparing",
        ad_removal_stage: "transcribing",
        ad_removal_blocking_reason: "model_required",
        ad_removal_action: null,
      })}
      onPlay={() => {}}
      actionLabel="Mark played"
      onAction={() => {}}
    />,
  );
}

describe("EpisodeRow download controls", () => {
  it("does not render download status, pin, or remove-download controls", () => {
    window.PODS_LOCAL_CLIENT = true;
    const { container, rerender } = render(
      <EpisodeRow
        item={episode({
          title: "Ready",
          downloaded: true,
          ad_removal_state: "ad-free",
          ad_removal_stage: "ready",
          ad_removal_action: null,
        })}
        onPlay={() => {}}
        actionLabel="Mark played"
        onAction={() => {}}
      />,
    );
    expect(container.querySelector(".offline-controls")).toBeNull();
    expect(screen.queryByText("Downloaded")).not.toBeInTheDocument();
    expect(screen.queryByText("Not downloaded")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Download" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Pin" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Unpin" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Remove download" })).not.toBeInTheDocument();
    rerender(
      <EpisodeRow
        item={episode({
          title: "Played episode",
          downloaded: false,
          played_at: 1,
          ad_removal_state: "ad-free",
          ad_removal_stage: "ready",
          ad_removal_action: null,
        })}
        onPlay={() => {}}
        actionLabel="Unmark played"
        onAction={() => {}}
      />,
    );
    expect(container.querySelector(".offline-controls")).toBeNull();
    expect(screen.queryByText("Not downloaded")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Download" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Pin" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Remove download" })).not.toBeInTheDocument();
  });
});

describe("EpisodeRow client download progress", () => {
  it("shows a download bar and keeps Play disabled until the file is local", () => {
    window.PODS_LOCAL_CLIENT = true;
    render(
      <EpisodeRow
        item={episode({
          title: "Incoming",
          downloaded: false,
          download_received: 1_000_000,
          download_total: 4_000_000,
          ad_removal_state: "ad-free",
          ad_removal_stage: "ready",
          ad_removal_action: null,
        })}
        onPlay={() => {}}
        actionLabel="Mark played"
        onAction={() => {}}
      />,
    );
    expect(screen.getByText("Downloading 25%")).toBeInTheDocument();
    expect(screen.getByRole("progressbar", { name: "Download progress" })).toHaveAttribute("aria-valuenow", "25");
    expect(screen.queryByText("Ad-free")).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: /Incoming/ })).toBeDisabled();
  });

  it("updates the bar from live download progress events", () => {
    window.PODS_LOCAL_CLIENT = true;
    render(
      <EpisodeRow
        item={episode({
          id: 1,
          title: "Incoming",
          downloaded: false,
          download_received: 0,
          download_total: 8,
          ad_removal_state: "ad-free",
          ad_removal_stage: "ready",
          ad_removal_action: null,
        })}
        onPlay={() => {}}
        actionLabel="Mark played"
        onAction={() => {}}
      />,
    );
    expect(screen.getByText("Downloading 0%")).toBeInTheDocument();
    act(() => setDownloadProgress({ episode: 1, received: 4, total: 8 }));
    expect(screen.getByText("Downloading 50%")).toBeInTheDocument();
    expect(screen.getByRole("progressbar", { name: "Download progress" })).toHaveAttribute("aria-valuenow", "50");
    act(() => setDownloadProgress({ episode: 2, received: 8, total: 8 }));
    expect(screen.getByText("Downloading 0%")).toBeInTheDocument();
  });
});

describe("EpisodeRow ad-removal status copy", () => {
  it("waits for a DeepSeek API key on the non-local path", () => {
    renderRow(false);
    expect(screen.getByText("Waiting for DeepSeek API key")).toBeInTheDocument();
  });

  it("does not wait for a DeepSeek API key on the local-browser path", () => {
    renderRow(true);
    expect(screen.queryByText(/Waiting for DeepSeek API key/i)).not.toBeInTheDocument();
    expect(screen.queryByText(/API key/i)).not.toBeInTheDocument();
    expect(screen.getByText("Paused · Mac unavailable")).toBeInTheDocument();
  });
});
