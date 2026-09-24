import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { Artwork } from "./Artwork";

describe("Artwork", () => {
  it("renders the image and falls back when it fails to load", () => {
    const { rerender } = render(<Artwork src="https://art.example/cover.jpg" size={48} alt="Cover" />);
    const image = screen.getByRole("img", { name: "Cover" });
    expect(image).toHaveAttribute("src", "https://art.example/cover.jpg");

    fireEvent.error(image);
    expect(screen.queryByRole("img", { name: "Cover" })).not.toBeInTheDocument();
    expect(document.querySelector(".art-fallback")).toBeTruthy();

    rerender(<Artwork src="https://art.example/repaired.jpg" size={48} alt="Cover" />);
    expect(screen.getByRole("img", { name: "Cover" })).toHaveAttribute("src", "https://art.example/repaired.jpg");
    expect(document.querySelector(".art-fallback")).toBeNull();

    rerender(<Artwork src="" size={32} />);
    expect(document.querySelector(".art-fallback")).toBeTruthy();
  });

  it("marks the article fallback without changing image rendering", () => {
    const { rerender } = render(<Artwork src="" size={48} article />);
    expect(document.querySelector(".art-fallback.art-article")).toBeTruthy();

    rerender(<Artwork src="https://art.example/lead.jpg" size={48} article alt="Lead" />);
    expect(screen.getByRole("img", { name: "Lead" })).toHaveAttribute("src", "https://art.example/lead.jpg");
    expect(document.querySelector(".art-fallback")).toBeNull();
  });
});
