import { describe, expect, it } from "vitest";
import { isArticle } from "./articles";

describe("isArticle", () => {
  it("detects snapshot rows by article_url and legacy rows by prefix", () => {
    expect(isArticle({ article_url: "https://example.com/story", audio_url: "/_media/abc.m4a" })).toBe(true);
    expect(isArticle({ audio_url: "article:https://example.com/story" })).toBe(true);
    expect(isArticle({ article_url: null, audio_url: "https://h.example/ep.mp3" })).toBe(false);
    expect(isArticle({ article_url: "", audio_url: "https://h.example/ep.mp3" })).toBe(false);
    expect(isArticle({ audio_url: "https://h.example/ep.mp3" })).toBe(false);
  });
});
