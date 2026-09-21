export type YoutubeKind = "channel" | "video";

const VIDEO_ID = /^[A-Za-z0-9_-]{11}$/;
const CHANNEL_ID = /^UC[A-Za-z0-9_-]{22}$/;
const HANDLE = /^[A-Za-z0-9._-]{1,60}$/;

export function classifyYoutube(raw: string): YoutubeKind | null {
  const trimmed = raw.trim();
  if (!trimmed) return null;
  if (trimmed.startsWith("@") && HANDLE.test(trimmed.slice(1)) && !trimmed.includes("/")) return "channel";
  if (CHANNEL_ID.test(trimmed)) return "channel";
  let url: URL;
  try {
    url = new URL(trimmed);
  } catch {
    return null;
  }
  const host = url.hostname.replace(/^(www|m)\./, "");
  if (host === "youtu.be") {
    const id = url.pathname.split("/").filter(Boolean)[0] ?? "";
    return VIDEO_ID.test(id) ? "video" : null;
  }
  if (host !== "youtube.com" && host !== "music.youtube.com") return null;
  const segments = url.pathname.split("/").filter(Boolean);
  if (segments[0] === "feeds" && segments[1] === "videos.xml" && CHANNEL_ID.test(url.searchParams.get("channel_id") ?? "")) {
    return "channel";
  }
  if ((segments.length === 0 || segments[0] === "watch") && VIDEO_ID.test(url.searchParams.get("v") ?? "")) return "video";
  if (["shorts", "embed", "live", "v"].includes(segments[0] ?? "") && VIDEO_ID.test(segments[1] ?? "")) return "video";
  if (segments[0]?.startsWith("@") && HANDLE.test(segments[0].slice(1))) return "channel";
  if (segments[0] === "channel" && CHANNEL_ID.test(segments[1] ?? "")) return "channel";
  if ((segments[0] === "c" || segments[0] === "user") && HANDLE.test(segments[1] ?? "")) return "channel";
  return null;
}

export function isVideoMedia(item: { audio_url: string; manifest?: { media?: string } | null }): boolean {
  return item.manifest?.media === "video" || item.audio_url.endsWith(".mp4");
}
