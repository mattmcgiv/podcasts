import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it } from "vitest";
import { App } from "./App";
import { episode, installApi, page } from "./test/mockApi";

const shellRoutes = {
  "GET /api/settings": { speed: 1, autoplay: true },
  "GET /api/recent": page([episode({ id: 1, title: "Fresh Episode" })]),
  "GET /api/played": page([]),
  "GET /api/shows": [],
};

describe("App", () => {
  it("opens directly into Listen without login", async () => {
    installApi(shellRoutes);
    render(<App />);

    await screen.findByText("Fresh Episode");
    expect(screen.getByRole("button", { name: "Listen" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Played" })).toBeInTheDocument();
    expect(screen.queryByPlaceholderText("Access token")).not.toBeInTheDocument();
  });

  it("switches tabs through the tab bar", async () => {
    installApi(shellRoutes);
    const user = userEvent.setup();
    render(<App />);
    await screen.findByText("Fresh Episode");

    await user.click(screen.getByRole("button", { name: "Played" }));
    await screen.findByRole("heading", { name: "Played" });

    await user.click(screen.getByRole("button", { name: "Shows" }));
    await screen.findByRole("heading", { name: "Shows" });

    await user.click(screen.getByRole("button", { name: "Search" }));
    await screen.findByRole("heading", { name: "Search" });
  });
});
