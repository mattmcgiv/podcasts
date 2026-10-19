import { render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { ErrorBoundary } from "./ErrorBoundary";

function BrokenView(): never {
  throw new Error("render failed");
}

describe("ErrorBoundary", () => {
  it("keeps a visible recovery message on screen when rendering fails", () => {
    vi.spyOn(console, "error").mockImplementation(() => undefined);

    render(
      <ErrorBoundary>
        <BrokenView />
      </ErrorBoundary>,
    );

    expect(screen.getByRole("alert")).toBeVisible();
    expect(screen.getByText("Pods couldn’t start")).toBeVisible();
    expect(screen.getByText(/close and reopen the app/i)).toBeVisible();
  });
});