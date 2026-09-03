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

    rerender(<Artwork src="" size={32} />);
    expect(document.querySelector(".art-fallback")).toBeTruthy();
  });
});
