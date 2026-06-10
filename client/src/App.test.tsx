import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it } from "vitest";
import { App } from "./App";
import { episode, HttpError, installApi, loggedIn, page } from "./test/mockApi";

const shellRoutes = {
  "GET /api/settings": { speed: 1, autoplay: true },
  "GET /api/recent": page([episode({ id: 1, title: "Fresh Episode" })]),
  "GET /api/played": page([]),
  "GET /api/shows": [],
};

describe("App", () => {
  it("shows login when no token, then unlocks into Recent", async () => {
    installApi({ ...shellRoutes, "POST /api/login": null });
    const user = userEvent.setup();
    render(<App />);

    expect(screen.getByPlaceholderText("Access token")).toBeInTheDocument();
    await user.type(screen.getByPlaceholderText("Access token"), "tok");
    await user.click(screen.getByRole("button", { name: "Unlock" }));

    await screen.findByText("Fresh Episode");
    expect(screen.getByRole("button", { name: "Played" })).toBeInTheDocument();
  });

  it("rejects a bad token with an error message", async () => {
    installApi({ "POST /api/login": new HttpError(401) });
    const user = userEvent.setup();
    render(<App />);
    await user.type(screen.getByPlaceholderText("Access token"), "bad");
    await user.click(screen.getByRole("button", { name: "Unlock" }));
    await screen.findByText("That token didn't work");
  });

  it("switches tabs through the tab bar", async () => {
    loggedIn();
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

  it("falls back to login when the API returns 401", async () => {
    loggedIn();
    installApi({ ...shellRoutes, "GET /api/recent": new HttpError(401) });
    render(<App />);
    await waitFor(() =>
      expect(screen.getByPlaceholderText("Access token")).toBeInTheDocument(),
    );
  });
});
