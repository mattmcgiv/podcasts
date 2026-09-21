import { describe, expect, it } from "vitest";
import { classifyYoutube, isVideoMedia } from "./youtube";

describe("classifyYoutube", () => {
  it("accepts channel urls, handles, and single videos", () => {
    expect(classifyYoutube("https://www.youtube.com/channel/UCabcdefghijklmnopqrstuv")).toBe("channel");
    expect(classifyYoutube("https://www.youtube.com/feeds/videos.xml?channel_id=UCabcdefghijklmnopqrstuv")).toBe("channel");
    expect(classifyYoutube("@veritasium")).toBe("channel");
    expect(classifyYoutube("https://www.youtube.com/@veritasium/videos")).toBe("channel");
    expect(classifyYoutube("https://youtu.be/abcdefghijk")).toBe("video");
    expect(classifyYoutube("https://m.youtube.com/watch?v=abcdefghijk")).toBe("video");
    expect(classifyYoutube("https://www.youtube.com/shorts/abcdefghijk")).toBe("video");
    expect(classifyYoutube("https://example.com/feed.xml")).toBeNull();
    expect(classifyYoutube("https://www.youtube.com/playlist?list=PL123")).toBeNull();
  });
});

describe("isVideoMedia", () => {
  it("follows the publication media kind and the mp4 url", () => {
    expect(isVideoMedia({ audio_url: "/_media/abc.mp4", manifest: { media: "video" } })).toBe(true);
    expect(isVideoMedia({ audio_url: "/_media/abc.m4a" })).toBe(false);
  });
});
