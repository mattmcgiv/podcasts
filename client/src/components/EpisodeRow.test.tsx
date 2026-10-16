import { act, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { downloadEpisode, downloadErrorFor } from "../offline/downloads";
import { setDownloadProgress } from "../offline/progress";
import { episode } from "../test/mockApi";
import { EpisodeRow } from "./EpisodeRow";

vi.mock("../offline/downloads", () => ({
  downloadEpisode: vi.fn(() => Promise.resolve()),
  downloadErrorFor: vi.fn(() => null),
}));

afterEach(() => {
  delete window.PODS_LOCAL_CLIENT;
  vi.mocked(downloadErrorFor).mockReturnValue(null);
  vi.mocked(downloadEpisode).mockClear();
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
    expect(screen.getByText("Download paused · 25%")).toBeInTheDocument();
    expect(screen.getByRole("progressbar", { name: "Download progress" })).toHaveAttribute("aria-valuenow", "25");
    expect(screen.queryByText("Ad-free")).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: /Incoming/ })).toBeDisabled();
  });

  it("offers a download for a newly synchronized episode and reports pre-transfer failures", async () => {
    window.PODS_LOCAL_CLIENT = true;
    vi.mocked(downloadErrorFor).mockReturnValue("Download limit reached. Increase the storage limit.");
    render(<EpisodeRow item={episode({ id: 9, downloaded: false, played_at: null, ad_removal_state: "ad-free" })}
      onPlay={() => {}} actionLabel="Mark played" onAction={() => {}} />);
    expect(screen.getByText("Not downloaded")).toBeInTheDocument();
    expect(screen.getByText(/Download limit reached/)).toBeInTheDocument();
    await act(async () => fireEvent.click(screen.getByRole("button", { name: "Download" })));
    expect(downloadEpisode).toHaveBeenCalledWith(9);
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
    expect(screen.getByText("Download paused · 0%")).toBeInTheDocument();
    act(() => setDownloadProgress({ episode: 1, received: 4, total: 8 }));
    expect(screen.getByText("Downloading 50%")).toBeInTheDocument();
    expect(screen.getByRole("progressbar", { name: "Download progress" })).toHaveAttribute("aria-valuenow", "50");
    act(() => setDownloadProgress({ episode: 2, received: 8, total: 8 }));
    expect(screen.getByText("Download paused · 0%")).toBeInTheDocument();
  });

  it("shows why a partial download stopped and retries it from the row", async () => {
    window.PODS_LOCAL_CLIENT = true;
    vi.mocked(downloadErrorFor).mockReturnValue("Download stalled. Check the connection, then retry.");
    render(
      <EpisodeRow
        item={episode({
          id: 5,
          title: "Stuck",
          downloaded: false,
          download_received: 1_000_000,
          download_total: 10_000_000,
          ad_removal_state: "ad-free",
          ad_removal_stage: "ready",
          ad_removal_action: "retry",
        })}
        onPlay={() => {}}
        actionLabel="Mark played"
        onAction={() => {}}
      />,
    );
    expect(screen.getByText("Download paused · 10%")).toBeInTheDocument();
    expect(screen.getByText("Download stalled. Check the connection, then retry.")).toBeInTheDocument();
    expect(screen.getByRole("progressbar", { name: "Download progress" })).toHaveAttribute("aria-valuetext", "Download paused · 10%");
    expect(screen.queryByRole("button", { name: "Retry ad-free preparation" })).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Retry download" }));
    expect(downloadEpisode).toHaveBeenCalledWith(5);
    await act(async () => {});
    // A live transfer for this episode clears the paused state.
    act(() => setDownloadProgress({ episode: 5, received: 5_000_000, total: 10_000_000 }));
    expect(screen.getByText("Downloading 50%")).toBeInTheDocument();
    expect(screen.queryByText(/stalled/)).not.toBeInTheDocument();
    // A later offline-state change re-reads the recorded failure.
    act(() => setDownloadProgress(null));
    vi.mocked(downloadErrorFor).mockReturnValue(null);
    act(() => { window.dispatchEvent(new Event("pods-offline-changed")); });
    expect(screen.getByText("Download paused · 10%")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Retry download" })).toBeInTheDocument();
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

describe("EpisodeRow article badge", () => {
  function renderArticle(overrides = {}) {
    return render(
      <EpisodeRow
        item={episode({
          title: "A Long Read",
          podcast_title: "Articles",
          article_url: "https://example.com/story",
          audio_url: "/_media/abc123.m4a",
          ad_removal_state: "ad-free",
          ad_removal_stage: "ready",
          ad_removal_action: null,
          ...overrides,
        })}
        onPlay={() => {}}
        actionLabel="Mark played"
        onAction={() => {}}
      />,
    );
  }

  it("badges article episodes and uses the article placeholder without an image", () => {
    const { container } = renderArticle({ image_url: "", podcast_image: "" });
    expect(screen.getByText("Article")).toHaveClass("article-badge");
    expect(container.querySelector(".art-fallback.art-article")).toBeTruthy();
  });

  it("still badges articles that carry a lead image", () => {
    const { container } = renderArticle({ image_url: "https://example.com/lead.jpg" });
    expect(screen.getByText("Article")).toHaveClass("article-badge");
    expect(container.querySelector(".art-fallback")).toBeNull();
  });

  it("shows no badge on podcast episodes", () => {
    render(
      <EpisodeRow
        item={episode({ title: "Regular Show" })}
        onPlay={() => {}}
        actionLabel="Mark played"
        onAction={() => {}}
      />,
    );
    expect(screen.queryByText("Article")).not.toBeInTheDocument();
  });
});
