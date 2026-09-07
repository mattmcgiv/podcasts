import { afterEach, describe, expect, it, vi } from "vitest";
import { createSpeakerClient, SpeakerDisconnectedError, SpeakerResyncError, SpeakerStaleError } from "./speakerApi";
import { HttpError, installApi } from "./test/mockApi";

afterEach(() => {
  delete window.PODS_API_BASE;
});

const okStatus = {
  available: true,
  connected: true,
  name: "Mac",
  episode_id: 1,
  artifact_hash: "ab".repeat(32),
  position: 4,
  duration: 15,
  rate: 1.5,
  paused: false,
  ended: false,
  session_id: "sess-a",
  generation: 2,
};

describe("speakerApi", () => {
  it("sends generation and artifact hash and never a media URL", async () => {
    window.PODS_API_BASE = "https://sync.pods.mcgiv.dev:8443";
    const { calls } = installApi({
      "POST /api/speaker/load": okStatus,
    });
    const client = createSpeakerClient();
    await client.load({
      episode_id: 1,
      artifact_hash: "ab".repeat(32),
      session_id: "sess-a",
      generation: 1,
      position: 12,
      rate: 1.5,
      playing: true,
    });
    const body = JSON.parse(String(calls[0].init.body));
    expect(calls[0].init.credentials).toBe("include");
    expect(calls[0].url.origin).toBe("https://sync.pods.mcgiv.dev:8443");
    expect(body).toEqual({
      episode_id: 1,
      artifact_hash: "ab".repeat(32),
      session_id: "sess-a",
      generation: 1,
      position: 12,
      rate: 1.5,
      playing: true,
    });
    expect(body.url).toBeUndefined();
    expect(body.src).toBeUndefined();
    expect(body.path).toBeUndefined();
  });

  it("maps 409 to SpeakerStaleError and network failure to disconnect", async () => {
    installApi({
      "POST /api/speaker/play": new HttpError(409, { error: "Playback session is out of date." }),
    });
    const client = createSpeakerClient();
    await expect(client.play({ session_id: "sess-a", generation: 1 })).rejects.toBeInstanceOf(SpeakerStaleError);
    installApi({
      "POST /api/speaker/load": new HttpError(409, { error: "This episode was updated on the Mac. Synchronize, then play again." }),
    });
    await expect(createSpeakerClient().load({
      episode_id: 1,
      artifact_hash: "ab".repeat(32),
      session_id: "sess-a",
      generation: 0,
      position: 0,
      rate: 1,
    })).rejects.toBeInstanceOf(SpeakerResyncError);
    vi.spyOn(globalThis, "fetch").mockRejectedValueOnce(new TypeError("Load failed"));
    await expect(client.status()).rejects.toBeInstanceOf(SpeakerDisconnectedError);
  });

  it("covers pause seek rate disconnect and remaining HTTP errors", async () => {
    const identity = { session_id: "sess-a", generation: 1 };
    const { calls } = installApi({
      "GET /api/speaker/status": okStatus,
      "POST /api/speaker/pause": okStatus,
      "POST /api/speaker/seek": okStatus,
      "POST /api/speaker/rate": okStatus,
      "POST /api/speaker/disconnect": okStatus,
      "POST /api/speaker/load": new HttpError(422, { error: "episode_id is required; remote media URLs are not accepted" }),
    });
    const client = createSpeakerClient();
    await client.status();
    await client.pause(identity);
    await client.seek(identity, 9);
    await client.rate(identity, 2);
    await client.disconnect(identity);
    expect(calls.map((c) => c.key)).toEqual([
      "GET /api/speaker/status",
      "POST /api/speaker/pause",
      "POST /api/speaker/seek",
      "POST /api/speaker/rate",
      "POST /api/speaker/disconnect",
    ]);
    await expect(client.load({
      episode_id: 1,
      artifact_hash: "ab".repeat(32),
      session_id: "sess-a",
      generation: 0,
      position: 0,
      rate: 1,
    })).rejects.toThrow(/remote media URLs/);

    installApi({ "GET /api/speaker/status": new HttpError(401, { error: "sign in required" }) });
    const auth = vi.fn();
    window.addEventListener("pods-auth-required", auth);
    await expect(createSpeakerClient().status()).rejects.toBeInstanceOf(SpeakerDisconnectedError);
    expect(auth).toHaveBeenCalled();

    installApi({ "GET /api/speaker/status": new HttpError(404, { error: "not found" }) });
    await expect(createSpeakerClient().status()).rejects.toThrow("not found");
    installApi({ "GET /api/speaker/status": new HttpError(500, { error: "backend failed" }) });
    await expect(createSpeakerClient().status()).rejects.toBeInstanceOf(SpeakerDisconnectedError);

    vi.spyOn(globalThis, "fetch").mockRejectedValueOnce(Object.assign(new Error("timeout"), { name: "TimeoutError" }));
    await expect(createSpeakerClient().status()).rejects.toThrow("Mac speaker timed out.");
  });
});
