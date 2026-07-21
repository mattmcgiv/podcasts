import { render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { PodsLifecycleBoundary } from "./PodsLifecycleBoundary";

function BrokenView(): never {
  throw new Error("render failed");
}

afterEach(() => {
  delete window.webkit;
});

describe("PodsLifecycleBoundary", () => {
  it("keeps a visible recovery message on screen and reports fatal UI failures", () => {
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    const postMessage = vi.fn();
    Object.defineProperty(window, "webkit", {
      configurable: true,
      value: { messageHandlers: { podsLifecycle: { postMessage } } },
    });

    render(
      <PodsLifecycleBoundary>
        <BrokenView />
      </PodsLifecycleBoundary>,
    );

    expect(screen.getByRole("alert")).toBeVisible();
    expect(screen.getByText("Pods couldn’t start")).toBeVisible();
    expect(screen.getByText(/close and reopen the app/i)).toBeVisible();
    expect(postMessage).toHaveBeenCalledWith({ event: "ui-failed" });
  });
});
