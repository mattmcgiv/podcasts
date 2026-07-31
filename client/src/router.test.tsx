import { render, screen, waitFor } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { navigate, parseHash, useRoute } from "./router";

describe("parseHash", () => {
  it("maps hashes to routes", () => {
    expect(parseHash("")).toEqual({ tab: "recent" });
    expect(parseHash("#/")).toEqual({ tab: "recent" });
    expect(parseHash("#/recent")).toEqual({ tab: "recent" });
    expect(parseHash("#/played")).toEqual({ tab: "played" });
    expect(parseHash("#/search")).toEqual({ tab: "shows" });
    expect(parseHash("#/settings")).toEqual({ tab: "settings" });
    expect(parseHash("#/follows")).toEqual({ tab: "recent" });
    expect(parseHash("#/shows")).toEqual({ tab: "shows" });
    expect(parseHash("#/shows/12")).toEqual({ tab: "shows", showId: 12 });
    expect(parseHash("#/shows/banana")).toEqual({ tab: "shows" });
    expect(parseHash("#/nonsense")).toEqual({ tab: "recent" });
  });
});

function RouteProbe() {
  const route = useRoute();
  return (
    <span data-testid="route">
      {route.tab}
      {route.showId != null ? `:${route.showId}` : ""}
    </span>
  );
}

describe("useRoute", () => {
  it("tracks hash changes", async () => {
    render(<RouteProbe />);
    expect(screen.getByTestId("route")).toHaveTextContent("recent");
    navigate("#/shows/3");
    await waitFor(() => expect(screen.getByTestId("route")).toHaveTextContent("shows:3"));
    navigate("#/played");
    await waitFor(() => expect(screen.getByTestId("route")).toHaveTextContent("played"));
  });
});
