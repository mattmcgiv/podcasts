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

  it("rejects blank and unparsable input", () => {
    expect(classifyYoutube("")).toBeNull();
    expect(classifyYoutube("   ")).toBeNull();
    expect(classifyYoutube("not a url")).toBeNull();
    expect(classifyYoutube("@veritasium/x")).toBeNull();
  });

  it("accepts bare channel ids and vanity paths", () => {
    expect(classifyYoutube("UCabcdefghijklmnopqrstuv")).toBe("channel");
    expect(classifyYoutube("https://www.youtube.com/c/veritasium")).toBe("channel");
    expect(classifyYoutube("https://www.youtube.com/user/veritasium")).toBe("channel");
    expect(classifyYoutube("https://music.youtube.com/watch?v=abcdefghijk")).toBe("video");
  });

  it("rejects malformed video and channel ids", () => {
    expect(classifyYoutube("https://youtu.be/xx")).toBeNull();
    expect(classifyYoutube("https://www.youtube.com/watch?v=xx")).toBeNull();
    expect(classifyYoutube("https://www.youtube.com/channel/short")).toBeNull();
    expect(classifyYoutube("https://www.youtube.com/c/")).toBeNull();
  });
});

describe("isVideoMedia", () => {
  it("follows the publication media kind and the mp4 url", () => {
    expect(isVideoMedia({ audio_url: "/_media/abc.mp4", manifest: { media: "video" } })).toBe(true);
    expect(isVideoMedia({ audio_url: "/_media/abc.m4a" })).toBe(false);
  });
});
