import { waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { BrowserSpeakerEngine } from "./speakerEngine";
import { SpeakerDisconnectedError, SpeakerResyncError, SpeakerStaleError, type SpeakerClient, type SpeakerStatus } from "./speakerApi";
import { FakeAudio } from "./test/fakeAudio";

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

function status(overrides: Partial<SpeakerStatus> = {}): SpeakerStatus {
  return {
    available: true,
    connected: true,
    name: "Mac",
    episode_id: 1,
    artifact_hash: "aa".repeat(32),
    position: 0,
    duration: 1800,
    rate: 1,
    paused: true,
    ended: false,
    session_id: "sess-test",
    generation: 1,
    ...overrides,
  };
}

function fakeClient(handlers: Partial<SpeakerClient> = {}) {
  const loads: unknown[] = [];
  const client: SpeakerClient = {
    status: handlers.status ?? (async () => status({ connected: false, generation: 0, session_id: null })),
    load: handlers.load ?? (async (body) => {
      loads.push(body);
      return status({
        position: body.position,
        rate: body.rate,
        paused: !body.playing,
        generation: body.generation + 1,
        episode_id: body.episode_id,
        artifact_hash: body.artifact_hash,
      });
    }),
    play: handlers.play ?? (async () => status({ paused: false, generation: 1 })),
    pause: handlers.pause ?? (async () => status({ paused: true, generation: 1 })),
    seek: handlers.seek ?? (async (_id, seconds) => status({ position: seconds, generation: 1 })),
    rate: handlers.rate ?? (async (_id, value) => status({ rate: value, generation: 1 })),
    disconnect: handlers.disconnect ?? (async () => status({ connected: false, generation: 2, session_id: null })),
  };
  return { client, loads };
}

describe("BrowserSpeakerEngine", () => {
  let engine: BrowserSpeakerEngine | undefined;

  afterEach(() => {
    engine?.dispose();
    engine = undefined;
    vi.useRealTimers();
  });

  it("applies local resume through loadSource on loadedmetadata", () => {
    const { client } = fakeClient();
    engine = new BrowserSpeakerEngine({ client, sessionId: "sess-test" });
    engine.loadSource("https://h.example/ep.m4a", 30, 1, "aa".repeat(32));
    const audio = FakeAudio.last();
    expect(audio.src).toBe("https://h.example/ep.m4a");
    expect(audio.currentTime).toBe(0);
    audio.emitLoadedMetadata(1800);
    expect(audio.currentTime).toBe(30);
  });

  it("captures local playing state before pause when handing off to Mac", async () => {
    const load = vi.fn(async (body) => status({ paused: !body.playing, generation: 1, position: body.position }));
    const { client } = fakeClient({ load });
    engine = new BrowserSpeakerEngine({ client, sessionId: "sess-test" });
    engine.loadSource("https://h.example/ep.m4a", 12, 1, "aa".repeat(32));
    await engine.play();
    expect(FakeAudio.last().paused).toBe(false);
    engine.castConnect();
    await waitFor(() => expect(load).toHaveBeenCalled());
    expect(FakeAudio.last().paused).toBe(true);
    expect(load).toHaveBeenCalledWith(expect.objectContaining({
      episode_id: 1,
      playing: true,
      position: 12,
      artifact_hash: "aa".repeat(32),
    }));
    expect(load.mock.calls[0][0]).not.toHaveProperty("url");
  });

  it("ignores a delayed load for a previous episode after a newer loadSource", async () => {
    const first = deferred<SpeakerStatus>();
    const second = deferred<SpeakerStatus>();
    let loads = 0;
    const { client } = fakeClient({
      load: () => {
        loads += 1;
        return loads === 1 ? first.promise : second.promise;
      },
    });
    engine = new BrowserSpeakerEngine({ client, sessionId: "sess-test" });
    engine.castConnect();
    await Promise.resolve();
    engine.loadSource("https://h.example/one.m4a", 0, 1, "aa".repeat(32));
    engine.loadSource("https://h.example/two.m4a", 5, 2, "bb".repeat(32));
    first.resolve(status({ episode_id: 1, position: 99, generation: 1 }));
    await Promise.resolve();
    await Promise.resolve();
    expect(engine.currentTime).not.toBe(99);
    second.resolve(status({ episode_id: 2, position: 5, generation: 2, paused: false }));
    await Promise.resolve();
    await Promise.resolve();
    expect(engine.currentTime).toBe(5);
  });

  it("stops a late load after close so Mac audio is not left playing", async () => {
    const pending = deferred<SpeakerStatus>();
    const load = vi.fn(() => pending.promise);
    const disconnect = vi.fn(async () => status({ connected: false, generation: 2, session_id: null }));
    const { client } = fakeClient({ load, disconnect });
    engine = new BrowserSpeakerEngine({ client, sessionId: "sess-test" });
    engine.castConnect();
    await Promise.resolve();
    engine.loadSource("https://h.example/ep.m4a", 0, 1, "aa".repeat(32));
    await waitFor(() => expect(load).toHaveBeenCalled());
    engine.removeAttribute("src");
    pending.resolve(status({ episode_id: 1, generation: 1, session_id: "sess-test", connected: true }));
    await waitFor(() => expect(disconnect).toHaveBeenCalledWith({ session_id: "sess-test", generation: 1 }));
    expect(engine.paused).toBe(true);
  });

  it("does not let an older poll rewind a newer seek", async () => {
    const poll = deferred<SpeakerStatus>();
    let statusCalls = 0;
    const { client } = fakeClient({
      status: () => {
        statusCalls += 1;
        if (statusCalls === 1) return Promise.resolve(status({ connected: false, generation: 0, session_id: null }));
        return poll.promise;
      },
      seek: async (_id, seconds) => status({ position: seconds, paused: false, generation: 1 }),
    });
    engine = new BrowserSpeakerEngine({ client, sessionId: "sess-test" });
    await Promise.resolve();
    engine.castConnect();
    await Promise.resolve();
    engine.loadSource("https://h.example/ep.m4a", 0, 1, "aa".repeat(32));
    await Promise.resolve();
    await Promise.resolve();
    vi.useFakeTimers();
    engine.currentTime = 40;
    await Promise.resolve();
    await vi.advanceTimersByTimeAsync(1000);
    poll.resolve(status({ position: 3, generation: 1, paused: false }));
    await Promise.resolve();
    await Promise.resolve();
    expect(engine.currentTime).toBe(40);
  });

  it("does not reconnect on ordinary play after losing the controller", async () => {
    const load = vi.fn(async (body) => status({ generation: body.generation + 1, paused: false }));
    const { client } = fakeClient({
      load,
      play: async () => {
        throw new SpeakerStaleError("Playback session is out of date.");
      },
    });
    engine = new BrowserSpeakerEngine({ client, sessionId: "sess-test" });
    engine.castConnect();
    await Promise.resolve();
    engine.loadSource("https://h.example/ep.m4a", 0, 1, "aa".repeat(32));
    await waitFor(() => expect(load).toHaveBeenCalled());
    load.mockClear();
    await expect(engine.play()).rejects.toThrow(/out of date/);
    await expect(engine.play()).rejects.toThrow(/Tap Mac/);
    expect(load).not.toHaveBeenCalled();
  });

  it("does not start local audio when disconnect is not acknowledged", async () => {
    const { client } = fakeClient({
      disconnect: async () => {
        throw new SpeakerDisconnectedError("Mac speaker disconnected.");
      },
    });
    engine = new BrowserSpeakerEngine({ client, sessionId: "sess-test" });
    const current = engine;
    current.castConnect();
    await Promise.resolve();
    current.loadSource("https://h.example/ep.m4a", 8, 1, "aa".repeat(32));
    await current.play();
    await waitFor(() => expect(current.cast.connected).toBe(true));
    FakeAudio.last().paused = true;
    current.castDisconnect();
    await Promise.resolve();
    await Promise.resolve();
    expect(FakeAudio.last().paused).toBe(true);
    expect(current.cast.error).toMatch(/may still be playing/);
    expect(current.cast.output).toBe("local");
  });

  it("does not resolve play before the remote command finishes", async () => {
    const pending = deferred<SpeakerStatus>();
    const { client } = fakeClient({
      load: async (body) => status({ generation: 1, paused: !body.playing, position: body.position }),
      play: () => pending.promise,
    });
    engine = new BrowserSpeakerEngine({ client, sessionId: "sess-test" });
    engine.castConnect();
    await Promise.resolve();
    engine.loadSource("https://h.example/ep.m4a", 0, 1, "aa".repeat(32));
    await Promise.resolve();
    await Promise.resolve();
    let settled = false;
    const done = engine.play().then(() => {
      settled = true;
    });
    await Promise.resolve();
    expect(settled).toBe(false);
    pending.resolve(status({ paused: false, generation: 1 }));
    await done;
    expect(settled).toBe(true);
  });

  it("refreshes availability on Retry and online without reconnecting playback", async () => {
    const statusFn = vi.fn(async () => status({ connected: false, available: false, generation: 0, session_id: null }));
    const load = vi.fn(async (body) => status({ generation: body.generation + 1 }));
    const { client } = fakeClient({ status: statusFn, load });
    engine = new BrowserSpeakerEngine({ client, sessionId: "sess-test" });
    const current = engine;
    await Promise.resolve();
    statusFn.mockResolvedValue(status({ connected: false, available: true, generation: 0, session_id: null }));
    current.requestCastStatus();
    await waitFor(() => expect(current.cast.available).toBe(true));
    window.dispatchEvent(new Event("online"));
    await Promise.resolve();
    expect(statusFn.mock.calls.length).toBeGreaterThan(2);
    expect(load).not.toHaveBeenCalled();
  });

  it("controls Mac pause seek rate and restores local audio after a confirmed stop", async () => {
    const seek = vi.fn(async (_id, seconds) => status({ position: seconds, paused: false, generation: 1 }));
    const rate = vi.fn(async (_id, value) => status({ rate: value, paused: false, generation: 1 }));
    const pause = vi.fn(async () => status({ paused: true, generation: 1 }));
    const disconnect = vi.fn(async () => status({ connected: false, generation: 2, session_id: null, paused: true, position: 20 }));
    const { client } = fakeClient({ seek, rate, pause, disconnect });
    engine = new BrowserSpeakerEngine({ client, sessionId: "sess-test" });
    engine.src = "https://h.example/ep.m4a";
    expect(engine.src).toBe("https://h.example/ep.m4a");
    engine.castConnect();
    await Promise.resolve();
    engine.loadSource("https://h.example/ep.m4a", 8, 1, "aa".repeat(32));
    await engine.play();
    engine.currentTime = 20;
    engine.playbackRate = 2;
    engine.setPlaybackRate(Number.NaN, "corr");
    engine.pause();
    await waitFor(() => expect(pause).toHaveBeenCalled());
    expect(seek).toHaveBeenCalled();
    expect(rate).toHaveBeenCalled();
    expect(engine.duration).toBe(1800);
    expect(engine.paused).toBe(true);
    engine.castDisconnect();
    await waitFor(() => expect(disconnect).toHaveBeenCalled());
    expect(engine.cast.output).toBe("local");
    expect(FakeAudio.last().src).toBe("https://h.example/ep.m4a");
    expect(engine.currentTime).toBe(20);
  });

  it("rejects Mac load without an artifact hash", async () => {
    const { client } = fakeClient();
    engine = new BrowserSpeakerEngine({ client, sessionId: "sess-test" });
    engine.castConnect();
    await Promise.resolve();
    const current = engine;
    current.loadSource("https://h.example/ep.m4a", 0, 1);
    await waitFor(() => expect(current.cast.error).toMatch(/processed episode/));
  });

  it("emits ended for the loaded episode and reports another session", async () => {
    const { client } = fakeClient({
      load: async (body) => {
        if (body.episode_id === 9) {
          return status({ session_id: "other", connected: true, generation: 4, episode_id: 9 });
        }
        return status({ ended: true, paused: true, generation: 1, episode_id: 1, position: 1800 });
      },
    });
    engine = new BrowserSpeakerEngine({ client, sessionId: "sess-test" });
    const current = engine;
    const ended: string[] = [];
    current.addEventListener("ended", () => ended.push("ended"));
    current.castConnect();
    await Promise.resolve();
    current.loadSource("https://h.example/ep.m4a", 0, 1, "aa".repeat(32));
    await waitFor(() => expect(ended).toEqual(["ended"]));
    current.loadSource("https://h.example/other.m4a", 0, 9, "bb".repeat(32));
    await waitFor(() => expect(current.cast.error).toMatch(/Another session/));
  });

  it("marks disconnected after poll failures and disposes", async () => {
    let statusCalls = 0;
    const disconnect = vi.fn(async () => status({ connected: false, generation: 2, session_id: null }));
    const { client } = fakeClient({
      status: async () => {
        statusCalls += 1;
        if (statusCalls === 1) return status({ connected: false, generation: 0, session_id: null, available: true });
        throw new SpeakerDisconnectedError("Mac speaker disconnected.");
      },
      disconnect,
    });
    engine = new BrowserSpeakerEngine({ client, sessionId: "sess-test" });
    const current = engine;
    current.castConnect();
    await Promise.resolve();
    current.loadSource("https://h.example/ep.m4a", 0, 1, "aa".repeat(32));
    await waitFor(() => expect(current.cast.connected).toBe(true));
    vi.useFakeTimers();
    await vi.advanceTimersByTimeAsync(1000);
    vi.useRealTimers();
    await waitFor(() => expect(current.cast.error).toMatch(/disconnected/));
    current.load();
    current.dispose();
    await waitFor(() => expect(disconnect).toHaveBeenCalled());
    Object.defineProperty(document, "visibilityState", { configurable: true, value: "visible" });
    document.dispatchEvent(new Event("visibilitychange"));
  });

  it("applies queued seek pause and rate to the new load generation", async () => {
    const pending = deferred<SpeakerStatus>();
    const load = vi.fn(() => pending.promise);
    const seeks: Array<{ generation: number; seconds: number }> = [];
    const pauses: number[] = [];
    const rates: number[] = [];
    const { client } = fakeClient({
      load,
      seek: async (id, seconds) => {
        seeks.push({ generation: id.generation, seconds });
        return status({ position: seconds, generation: id.generation, paused: true, rate: 2 });
      },
      pause: async (id) => {
        pauses.push(id.generation);
        return status({ paused: true, generation: id.generation, position: 40, rate: 2 });
      },
      rate: async (id, value) => {
        rates.push(id.generation);
        return status({ rate: value, generation: id.generation, paused: true, position: 40 });
      },
    });
    engine = new BrowserSpeakerEngine({ client, sessionId: "sess-test" });
    const current = engine;
    current.castConnect();
    await Promise.resolve();
    current.loadSource("https://h.example/ep.m4a", 5, 1, "aa".repeat(32));
    await waitFor(() => expect(load).toHaveBeenCalled());
    current.currentTime = 40;
    current.pause();
    current.playbackRate = 2;
    pending.resolve(status({ generation: 1, position: 5, paused: false, rate: 1, session_id: "sess-test" }));
    await waitFor(() => expect(seeks.length + pauses.length + rates.length).toBeGreaterThan(2));
    expect(load).toHaveBeenCalledTimes(1);
    expect(seeks.every((item) => item.generation === 1)).toBe(true);
    expect(pauses.every((generation) => generation === 1)).toBe(true);
    expect(rates.every((generation) => generation === 1)).toBe(true);
    expect(current.cast.error).toBeUndefined();
    expect(current.currentTime).toBe(40);
    expect(current.paused).toBe(true);
    expect(current.playbackRate).toBe(2);
  });

  it("keeps last Mac position when a visibility probe is stale", async () => {
    const pending = deferred<SpeakerStatus>();
    let ready = false;
    const { client } = fakeClient({
      status: async () => {
        if (!ready) return status({ connected: false, generation: 0, session_id: null, available: true });
        return pending.promise;
      },
    });
    engine = new BrowserSpeakerEngine({ client, sessionId: "sess-test" });
    const current = engine;
    current.castConnect();
    await Promise.resolve();
    current.loadSource("https://h.example/ep.m4a", 8, 1, "aa".repeat(32));
    await waitFor(() => expect(current.cast.connected).toBe(true));
    ready = true;
    Object.defineProperty(document, "visibilityState", { configurable: true, value: "visible" });
    document.dispatchEvent(new Event("visibilitychange"));
    current.currentTime = 50;
    pending.resolve(status({ position: 2, generation: 1, connected: true, episode_id: 1, paused: false }));
    await Promise.resolve();
    await Promise.resolve();
    expect(current.currentTime).toBe(50);
  });

  it("does not let a failed old stop overwrite a newer Mac selection", async () => {
    const pending = deferred<SpeakerStatus>();
    const load = vi.fn(async (body) => status({
      generation: body.generation + 1,
      paused: false,
      position: body.position,
      episode_id: body.episode_id,
    }));
    const disconnect = vi.fn(() => pending.promise);
    const { client } = fakeClient({ load, disconnect });
    engine = new BrowserSpeakerEngine({ client, sessionId: "sess-test" });
    const current = engine;
    current.castConnect();
    await Promise.resolve();
    current.loadSource("https://h.example/one.m4a", 8, 1, "aa".repeat(32));
    await waitFor(() => expect(current.cast.connected).toBe(true));
    current.castDisconnect();
    await waitFor(() => expect(disconnect).toHaveBeenCalled());
    current.castConnect();
    pending.reject(new SpeakerDisconnectedError("Mac speaker disconnected."));
    await waitFor(() => expect(load.mock.calls.length).toBeGreaterThan(1));
    expect(current.cast.output).toBe("mac");
    expect(current.cast.error ?? "").not.toMatch(/may still be playing/);
  });

  it("treats a second tap on connected Mac as a no-op", async () => {
    const load = vi.fn(async (body) => status({ generation: 1, paused: false, position: body.position }));
    let remotePosition = 8;
    const { client } = fakeClient({
      load,
      status: async () => {
        if (load.mock.calls.length === 0) return status({ connected: false, generation: 0, session_id: null, available: true });
        return status({ connected: true, generation: 1, session_id: "sess-test", position: remotePosition, paused: false });
      },
    });
    engine = new BrowserSpeakerEngine({ client, sessionId: "sess-test" });
    const current = engine;
    current.castConnect();
    await Promise.resolve();
    current.loadSource("https://h.example/ep.m4a", 8, 1, "aa".repeat(32));
    await waitFor(() => expect(current.cast.connected).toBe(true));
    remotePosition = 90;
    vi.useFakeTimers();
    await vi.advanceTimersByTimeAsync(1000);
    vi.useRealTimers();
    await waitFor(() => expect(current.currentTime).toBe(90));
    load.mockClear();
    current.castConnect();
    await Promise.resolve();
    expect(load).not.toHaveBeenCalled();
    expect(current.currentTime).toBe(90);
    expect(current.paused).toBe(false);
  });

  it("prepares the current episode paused after an unconfirmed stop and keeps the warning", async () => {
    const { client } = fakeClient({
      disconnect: async () => {
        throw new SpeakerDisconnectedError("Mac speaker disconnected.");
      },
    });
    engine = new BrowserSpeakerEngine({ client, sessionId: "sess-test" });
    const current = engine;
    current.castConnect();
    await Promise.resolve();
    current.loadSource("https://h.example/next.m4a", 44, 2, "bb".repeat(32));
    await current.play();
    await waitFor(() => expect(current.cast.connected).toBe(true));
    current.castDisconnect();
    await waitFor(() => expect(current.cast.error).toMatch(/may still be playing/));
    expect(current.cast.output).toBe("local");
    expect(current.paused).toBe(true);
    expect(FakeAudio.last().paused).toBe(true);
    expect(current.src).toBe("https://h.example/next.m4a");
    expect(FakeAudio.last().src).toBe("https://h.example/next.m4a");
  });

  it("recovers after an unconfirmed stop when a later stop is acknowledged", async () => {
    let fail = true;
    const disconnect = vi.fn(async () => {
      if (fail) throw new SpeakerDisconnectedError("Mac speaker disconnected.");
      return status({ connected: false, generation: 3, session_id: null, paused: true, position: 18 });
    });
    const { client } = fakeClient({ disconnect });
    engine = new BrowserSpeakerEngine({ client, sessionId: "sess-test" });
    const current = engine;
    current.castConnect();
    await Promise.resolve();
    current.loadSource("https://h.example/ep.m4a", 18, 1, "aa".repeat(32));
    await current.play();
    await waitFor(() => expect(current.cast.connected).toBe(true));
    current.castDisconnect();
    await waitFor(() => expect(current.cast.error).toMatch(/may still be playing/));
    fail = false;
    current.castConnect();
    await waitFor(() => expect(current.cast.connected).toBe(true));
    current.castDisconnect();
    await waitFor(() => expect(current.cast.error).toBeUndefined());
    expect(current.currentTime).toBe(18);
    expect(current.paused).toBe(true);
  });

  it("keeps the Mac resync error instead of a generic reconnect hint", async () => {
    const { client } = fakeClient({
      load: async () => {
        throw new SpeakerResyncError("This episode was updated on the Mac. Synchronize, then play again.");
      },
    });
    engine = new BrowserSpeakerEngine({ client, sessionId: "sess-test" });
    const current = engine;
    current.castConnect();
    await Promise.resolve();
    current.loadSource("https://h.example/ep.m4a", 0, 1, "aa".repeat(32));
    await waitFor(() => expect(current.cast.error).toMatch(/Synchronize/));
    expect(current.cast.error).not.toMatch(/Tap Mac to play/);
  });

  it("resumes local audio after a confirmed stop while playing", async () => {
    const { client } = fakeClient({
      disconnect: async () => status({ connected: false, generation: 2, session_id: null, paused: true, position: 8 }),
    });
    engine = new BrowserSpeakerEngine({ client, sessionId: "sess-test" });
    const current = engine;
    current.loadSource("https://h.example/ep.m4a", 8, 1, "aa".repeat(32));
    FakeAudio.last().emitLoadedMetadata(1800);
    await current.play();
    expect(current.paused).toBe(false);
    expect(FakeAudio.last().currentTime).toBe(8);
    current.castConnect();
    await waitFor(() => expect(current.cast.connected).toBe(true));
    current.castDisconnect();
    await waitFor(() => expect(current.cast.output).toBe("local"));
    await Promise.resolve();
    expect(current.paused).toBe(false);
    expect(FakeAudio.last().paused).toBe(false);
    expect(FakeAudio.last().currentTime).toBe(8);
  });

  it("does not disconnect or pause phone audio after a confirmed stop", async () => {
    const disconnect = vi.fn(async () => {
      if (disconnect.mock.calls.length > 1) {
        throw new SpeakerStaleError("Playback session is out of date.");
      }
      return status({ connected: false, generation: 2, session_id: null, paused: true, position: 8 });
    });
    const { client } = fakeClient({ disconnect });
    engine = new BrowserSpeakerEngine({ client, sessionId: "sess-test" });
    const current = engine;
    current.loadSource("https://h.example/ep.m4a", 8, 1, "aa".repeat(32));
    FakeAudio.last().emitLoadedMetadata(1800);
    await current.play();
    current.castConnect();
    await waitFor(() => expect(current.cast.connected).toBe(true));
    current.castDisconnect();
    await waitFor(() => expect(disconnect).toHaveBeenCalledTimes(1));
    await waitFor(() => expect(current.cast.output).toBe("local"));
    expect(current.cast.error).toBeUndefined();
    expect(FakeAudio.last().paused).toBe(false);
    current.castDisconnect();
    await Promise.resolve();
    await Promise.resolve();
    expect(disconnect).toHaveBeenCalledTimes(1);
    expect(current.cast.error).toBeUndefined();
    expect(current.cast.output).toBe("local");
    expect(FakeAudio.last().paused).toBe(false);
    current.dispose();
    engine = undefined;
    await Promise.resolve();
    await Promise.resolve();
    expect(disconnect).toHaveBeenCalledTimes(1);
    expect(FakeAudio.last().paused).toBe(true);
  });

  it("stays paused when automatic local play is rejected after a confirmed stop", async () => {
    const rejections: unknown[] = [];
    const onReject = (event: PromiseRejectionEvent) => {
      event.preventDefault();
      rejections.push(event.reason);
    };
    window.addEventListener("unhandledrejection", onReject);
    const { client } = fakeClient({
      disconnect: async () => status({ connected: false, generation: 2, session_id: null, paused: true, position: 8 }),
    });
    engine = new BrowserSpeakerEngine({ client, sessionId: "sess-test" });
    const current = engine;
    current.loadSource("https://h.example/ep.m4a", 8, 1, "aa".repeat(32));
    FakeAudio.last().emitLoadedMetadata(1800);
    await current.play();
    current.castConnect();
    await waitFor(() => expect(current.cast.connected).toBe(true));
    FakeAudio.failNextPlay = true;
    current.castDisconnect();
    await waitFor(() => expect(current.cast.output).toBe("local"));
    await Promise.resolve();
    await Promise.resolve();
    expect(current.paused).toBe(true);
    expect(FakeAudio.last().paused).toBe(true);
    expect(FakeAudio.last().currentTime).toBe(8);
    expect(rejections).toEqual([]);
    FakeAudio.failNextPlay = true;
    await expect(current.play()).rejects.toThrow(/play failed/);
    expect(current.paused).toBe(true);
    expect(rejections).toEqual([]);
    window.removeEventListener("unhandledrejection", onReject);
  });

  it("stays paused when pendingRestore autoplay is rejected", async () => {
    const rejections: unknown[] = [];
    const onReject = (event: PromiseRejectionEvent) => {
      event.preventDefault();
      rejections.push(event.reason);
    };
    window.addEventListener("unhandledrejection", onReject);
    const { client } = fakeClient({
      disconnect: async () => status({ connected: false, generation: 3, session_id: null, paused: true, position: 12 }),
    });
    engine = new BrowserSpeakerEngine({ client, sessionId: "sess-test" });
    const current = engine;
    current.loadSource("https://h.example/one.m4a", 0, 1, "aa".repeat(32));
    await current.play();
    expect(FakeAudio.last().paused).toBe(false);
    current.castConnect();
    await waitFor(() => expect(current.cast.connected).toBe(true));
    current.loadSource("https://h.example/two.m4a", 12, 2, "bb".repeat(32));
    await waitFor(() => expect(current.paused).toBe(false));
    expect(FakeAudio.last().src).toBe("https://h.example/one.m4a");
    FakeAudio.failNextPlay = true;
    current.castDisconnect();
    await waitFor(() => expect(current.cast.output).toBe("local"));
    expect(FakeAudio.last().src).toBe("https://h.example/two.m4a");
    FakeAudio.last().emitLoadedMetadata(1800);
    await Promise.resolve();
    await Promise.resolve();
    expect(current.paused).toBe(true);
    expect(FakeAudio.last().paused).toBe(true);
    expect(FakeAudio.last().currentTime).toBe(12);
    expect(rejections).toEqual([]);
    window.removeEventListener("unhandledrejection", onReject);
  });

  it("ignores a delayed autoplay rejection after Mac is selected again", async () => {
    const rejections: unknown[] = [];
    const onReject = (event: PromiseRejectionEvent) => {
      event.preventDefault();
      rejections.push(event.reason);
    };
    window.addEventListener("unhandledrejection", onReject);
    const pending = deferred<void>();
    const { client } = fakeClient({
      load: async (body) => status({
        generation: body.generation + 1,
        paused: !body.playing,
        position: body.position,
        episode_id: body.episode_id,
        artifact_hash: body.artifact_hash,
        rate: body.rate,
      }),
      play: async (id) => status({ paused: false, generation: id.generation, position: 8 }),
      disconnect: async (id) => status({
        connected: false,
        generation: id.generation + 1,
        session_id: null,
        paused: true,
        position: 8,
      }),
    });
    engine = new BrowserSpeakerEngine({ client, sessionId: "sess-test" });
    const current = engine;
    current.loadSource("https://h.example/ep.m4a", 8, 1, "aa".repeat(32));
    FakeAudio.last().emitLoadedMetadata(1800);
    await current.play();
    current.castConnect();
    await waitFor(() => expect(current.cast.connected).toBe(true));
    FakeAudio.pendingPlay = pending.promise;
    current.castDisconnect();
    await waitFor(() => expect(current.cast.output).toBe("local"));
    current.castConnect();
    await waitFor(() => expect(current.cast.connected).toBe(true));
    await current.play();
    expect(current.paused).toBe(false);
    pending.reject(new Error("play failed"));
    await Promise.resolve();
    await Promise.resolve();
    expect(current.cast.output).toBe("mac");
    expect(current.paused).toBe(false);
    expect(rejections).toEqual([]);
    window.removeEventListener("unhandledrejection", onReject);
  });

  it("ignores a delayed autoplay rejection after a newer local episode", async () => {
    const rejections: unknown[] = [];
    const onReject = (event: PromiseRejectionEvent) => {
      event.preventDefault();
      rejections.push(event.reason);
    };
    window.addEventListener("unhandledrejection", onReject);
    const pending = deferred<void>();
    const { client } = fakeClient({
      disconnect: async () => status({ connected: false, generation: 2, session_id: null, paused: true, position: 8 }),
    });
    engine = new BrowserSpeakerEngine({ client, sessionId: "sess-test" });
    const current = engine;
    current.loadSource("https://h.example/one.m4a", 8, 1, "aa".repeat(32));
    FakeAudio.last().emitLoadedMetadata(1800);
    await current.play();
    current.castConnect();
    await waitFor(() => expect(current.cast.connected).toBe(true));
    FakeAudio.pendingPlay = pending.promise;
    current.castDisconnect();
    await waitFor(() => expect(current.cast.output).toBe("local"));
    current.loadSource("https://h.example/two.m4a", 0, 2, "bb".repeat(32));
    FakeAudio.last().emitLoadedMetadata(900);
    await current.play();
    expect(current.paused).toBe(false);
    pending.reject(new Error("play failed"));
    await Promise.resolve();
    await Promise.resolve();
    expect(current.src).toBe("https://h.example/two.m4a");
    expect(current.paused).toBe(false);
    expect(FakeAudio.last().paused).toBe(false);
    expect(rejections).toEqual([]);
    window.removeEventListener("unhandledrejection", onReject);
  });

  it("does not reload local audio when dispose disconnect fails", async () => {
    const { client } = fakeClient({
      disconnect: async () => {
        throw new SpeakerDisconnectedError("Mac speaker disconnected.");
      },
    });
    engine = new BrowserSpeakerEngine({ client, sessionId: "sess-test" });
    const current = engine;
    current.castConnect();
    await Promise.resolve();
    current.loadSource("https://h.example/ep.m4a", 8, 1, "aa".repeat(32));
    await current.play();
    await waitFor(() => expect(current.cast.connected).toBe(true));
    current.dispose();
    engine = undefined;
    await Promise.resolve();
    await Promise.resolve();
    expect(FakeAudio.last().paused).toBe(true);
    expect(FakeAudio.last().src).toBe("");
  });

  it("stops local audio on dispose and does not emit unhandled rejections", async () => {
    const rejections: unknown[] = [];
    const onReject = (event: PromiseRejectionEvent) => {
      event.preventDefault();
      rejections.push(event.reason);
    };
    window.addEventListener("unhandledrejection", onReject);
    const { client } = fakeClient({
      seek: async () => {
        throw new SpeakerDisconnectedError("Mac speaker timed out.");
      },
    });
    engine = new BrowserSpeakerEngine({ client, sessionId: "sess-test" });
    const current = engine;
    current.loadSource("https://h.example/ep.m4a", 0, 1, "aa".repeat(32));
    await current.play();
    expect(FakeAudio.last().paused).toBe(false);
    current.castConnect();
    await waitFor(() => expect(current.cast.output).toBe("mac"));
    current.currentTime = 9;
    await Promise.resolve();
    await Promise.resolve();
    expect(rejections).toEqual([]);
    current.dispose();
    expect(FakeAudio.last().paused).toBe(true);
    expect(FakeAudio.last().src).toBe("");
    window.removeEventListener("unhandledrejection", onReject);
  });
});
