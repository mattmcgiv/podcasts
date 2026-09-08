import type { AudioEngine, AudioMetadata, CastInfo } from "./audioEngine";
import {
  createSpeakerClient,
  SpeakerDisconnectedError,
  SpeakerResyncError,
  SpeakerStaleError,
  type SpeakerClient,
  type SpeakerIdentity,
  type SpeakerStatus,
} from "./speakerApi";

const POLL_MS = 1_000;
const MAX_POLL_FAILURES = 3;
const UNCONFIRMED_STOP =
  "Mac did not confirm stop. It may still be playing. Tap iPhone, then Play to use this phone.";
const RECONNECT_HINT = "Tap Mac to play through the Mac speaker again.";

export interface BrowserSpeakerOptions {
  client?: SpeakerClient;
  sessionId?: string;
}

type LocalAudio = HTMLAudioElement;

interface RestoreLocal {
  position: number;
  playing: boolean;
  rate: number;
}

export class BrowserSpeakerEngine extends EventTarget implements AudioEngine {
  preload = "metadata";
  private readonly local: LocalAudio;
  private readonly client: SpeakerClient;
  private readonly sessionId: string;
  private _src = "";
  private _episodeId: number | undefined;
  private _artifactHash: string | undefined;
  private _currentTime = 0;
  private _duration = NaN;
  private _playbackRate = 1;
  private _paused = true;
  private _cast: CastInfo = { available: false, connected: false, output: "local" };
  private generation = 0;
  private op = 0;
  private mutateSeq = 0;
  private pollTimer: number | undefined;
  private pollBusy = false;
  private pollFailures = 0;
  private inFlight: Promise<void> | null = null;
  private pendingLocalPosition: number | null = null;
  private pendingRestore: RestoreLocal | null = null;
  private endedKey: string | null = null;
  private emittedPaused: boolean | null = null;
  private reportedDuration = false;
  private lostControl = false;
  private ownsSession = false;
  private macMayBePlaying = false;
  private authFailed = false;
  private destroyed = false;
  private readonly onOnline: () => void;
  private readonly onVisible: () => void;

  constructor(options: BrowserSpeakerOptions = {}) {
    super();
    this.client = options.client ?? createSpeakerClient();
    this.sessionId = options.sessionId ?? (typeof crypto !== "undefined" && crypto.randomUUID
      ? crypto.randomUUID()
      : `sess-${Date.now()}`);
    this.local = new Audio() as LocalAudio;
    this.local.preload = "metadata";
    this.bindLocal();
    this.onOnline = () => {
      if (!this.authFailed && !this.destroyed) void this.refreshAvailability(this.op);
    };
    this.onVisible = () => {
      if (this.destroyed || this.authFailed) return;
      if (document.visibilityState === "visible") void this.refreshAvailability(this.op);
    };
    if (typeof window !== "undefined") {
      window.addEventListener("online", this.onOnline);
      document.addEventListener("visibilitychange", this.onVisible);
    }
    void this.refreshAvailability(this.op);
  }

  get src(): string {
    return this._src;
  }

  set src(value: string) {
    this.loadSource(value, 0, this._episodeId, this._artifactHash);
  }

  private runBackground(op: number, work: () => Promise<void>): void {
    void this.enqueue(op, work).catch(() => {});
  }

  loadSource(src: string, position: number, episodeId?: number, artifactHash?: string): void {
    const initialPosition = Number.isFinite(position) ? Math.max(0, position) : 0;
    const op = ++this.op;
    this._src = src;
    this._episodeId = episodeId;
    this._artifactHash = artifactHash;
    this.endedKey = null;
    this.reportedDuration = false;
    this.emittedPaused = null;
    this.pendingRestore = null;
    if (this._cast.output === "mac") {
      if (this.lostControl) {
        this.setCast({
          ...this._cast,
          output: "mac",
          connected: false,
          error: RECONNECT_HINT,
        });
        return;
      }
      const playing = this.pendingPlayIntent();
      this._currentTime = initialPosition;
      this.stopLocal(false);
      this.runBackground(op, () => this.loadMac(op, episodeId, artifactHash, initialPosition, playing));
      return;
    }
    this._currentTime = 0;
    this._duration = NaN;
    this._paused = true;
    this.pendingLocalPosition = initialPosition;
    this.local.src = src;
  }

  get currentTime(): number {
    return this._cast.output === "mac" ? this._currentTime : this.local.currentTime;
  }

  set currentTime(value: number) {
    const seconds = Number.isFinite(value) ? Math.max(0, value) : 0;
    this._currentTime = seconds;
    if (this._cast.output === "mac") {
      const op = this.op;
      const seq = ++this.mutateSeq;
      this.runBackground(op, () => this.command(op, seq, (id) => this.client.seek(id, seconds)));
      return;
    }
    this.pendingLocalPosition = null;
    this.local.currentTime = seconds;
  }

  get duration(): number {
    if (this._cast.output === "mac") return this._duration;
    return this.local.duration;
  }

  get playbackRate(): number {
    return this._cast.output === "mac" ? this._playbackRate : this.local.playbackRate;
  }

  set playbackRate(value: number) {
    const rate = Number.isFinite(value) && value > 0 ? value : 1;
    this._playbackRate = rate;
    if (this._cast.output === "mac") {
      const op = this.op;
      const seq = ++this.mutateSeq;
      this.runBackground(op, () => this.command(op, seq, (id) => this.client.rate(id, rate)));
      return;
    }
    this.local.playbackRate = rate;
  }

  setPlaybackRate(rate: number, _correlationId: string): void {
    this.playbackRate = rate;
  }

  get paused(): boolean {
    return this._cast.output === "mac" ? this._paused : this.local.paused;
  }

  get cast(): CastInfo {
    return this._cast;
  }

  play(): Promise<void> {
    if (this._cast.output !== "mac") return this.local.play();
    if (this.lostControl && !this._cast.connected) {
      this.setCast({ ...this._cast, output: "mac", connected: false, error: RECONNECT_HINT });
      return Promise.reject(new Error(RECONNECT_HINT));
    }
    const op = this.op;
    const seq = ++this.mutateSeq;
    return this.enqueue(op, async () => {
      if (this.stale(op)) return;
      if (!this._cast.connected) {
        await this.loadMac(op, this._episodeId, this._artifactHash, this._currentTime, true);
        return;
      }
      await this.command(op, seq, (id) => this.client.play(id));
    });
  }

  pause(): void {
    this._paused = true;
    if (this._cast.output === "mac") {
      const op = this.op;
      const seq = ++this.mutateSeq;
      this.runBackground(op, () => this.command(op, seq, (id) => this.client.pause(id)));
      return;
    }
    this.local.pause();
  }

  load(): void {
    if (this._cast.output === "mac") return;
    if (this._src) this.local.src = this._src;
  }

  removeAttribute(name: string): void {
    if (name !== "src") return;
    const op = ++this.op;
    this._src = "";
    this._currentTime = 0;
    this._duration = NaN;
    this._paused = true;
    this._episodeId = undefined;
    this._artifactHash = undefined;
    this.pendingLocalPosition = null;
    this.stopLocal(true);
    this.runBackground(op, () => this.stopRemote(op, false));
  }

  setMetadata(_metadata: AudioMetadata): void {}

  castConnect(): void {
    if (this._cast.output === "mac" && this._cast.connected && !this.lostControl) {
      return;
    }
    const fromPhone = this._cast.output !== "mac";
    const playing = fromPhone ? !this.local.paused : !this._paused;
    const position = fromPhone ? this.handoffPosition() : this._currentTime;
    const rate = fromPhone && Number.isFinite(this.local.playbackRate) && this.local.playbackRate > 0
      ? this.local.playbackRate
      : this._playbackRate;
    const op = ++this.op;
    this.lostControl = false;
    this.macMayBePlaying = false;
    this._playbackRate = rate;
    this._currentTime = position;
    this.stopLocal(false);
    this.setCast({ ...this._cast, output: "mac", error: undefined });
    this.runBackground(op, async () => {
      if (this.stale(op)) return;
      const status = await this.probe();
      if (this.stale(op)) return;
      if (!status?.available) {
        this.setCast({
          available: false,
          connected: false,
          output: "mac",
          error: status?.error || "Mac is not reachable on this Wi-Fi.",
        });
        return;
      }
      if (status.generation > 0) this.generation = status.generation;
      if (this._episodeId != null) {
        await this.loadMac(op, this._episodeId, this._artifactHash, position, playing);
        return;
      }
      this.setCast({
        available: true,
        connected: false,
        name: status.name ?? "Mac",
        output: "mac",
        error: undefined,
      });
    });
  }

  castDisconnect(): void {
    const op = ++this.op;
    this.stopPoll();
    if (this._cast.output === "mac" && this._cast.connected) {
      this.setCast({ ...this._cast, connected: false });
    }
    this.runBackground(op, () => this.stopRemote(op, true));
  }

  requestCastStatus(): void {
    this.authFailed = false;
    void this.refreshAvailability(this.op);
  }

  undoAdSkip(): void {
    const local = this.local as LocalAudio & { undoAdSkip?: () => void };
    local.undoAdSkip?.();
  }

  dispose(): void {
    this.destroyed = true;
    const op = ++this.op;
    this.stopLocal(true);
    this.stopPoll();
    if (typeof window !== "undefined") {
      window.removeEventListener("online", this.onOnline);
      document.removeEventListener("visibilitychange", this.onVisible);
    }
    this.runBackground(op, () => this.stopRemote(op, false));
  }

  private pendingPlayIntent(): boolean {
    return !this._paused;
  }

  private bindLocal(): void {
    const forward = (type: string) => {
      this.local.addEventListener(type, () => {
        if (this.destroyed || this._cast.output !== "local") return;
        if (type === "play") this._paused = false;
        if (type === "pause" || type === "ended") this._paused = true;
        if (type === "timeupdate" && Number.isFinite(this.local.currentTime)) {
          this._currentTime = this.local.currentTime;
        }
        if (type === "loadedmetadata") {
          if (Number.isFinite(this.local.duration) && this.local.duration > 0) {
            this._duration = this.local.duration;
          }
          if (this.pendingLocalPosition != null) {
            const resume = this.pendingLocalPosition;
            this.pendingLocalPosition = null;
            this.local.currentTime = resume;
            this._currentTime = resume;
          }
          if (this.pendingRestore) {
            const restore = this.pendingRestore;
            this.pendingRestore = null;
            this.local.playbackRate = restore.rate;
            this.local.currentTime = restore.position;
            this._currentTime = restore.position;
            this._playbackRate = restore.rate;
            if (restore.playing) this.tryLocalPlay();
          }
        }
        this.dispatchEvent(new Event(type));
      });
    };
    for (const type of ["play", "pause", "timeupdate", "loadedmetadata", "ended", "error"]) {
      forward(type);
    }
    this.local.addEventListener("adSkip", (event) => {
      if (this._cast.output !== "local") return;
      this.dispatchEvent(new CustomEvent("adSkip", { detail: (event as CustomEvent).detail }));
    });
    this.local.addEventListener("adSkipUndone", () => {
      if (this._cast.output !== "local") return;
      this.dispatchEvent(new CustomEvent("adSkipUndone"));
    });
  }

  private identity(): SpeakerIdentity | null {
    if (!this.ownsSession || this.generation <= 0) return null;
    return { session_id: this.sessionId, generation: this.generation };
  }

  private handoffPosition(): number {
    if (this.pendingLocalPosition != null && this.pendingLocalPosition > 0) return this.pendingLocalPosition;
    if (Number.isFinite(this.local.currentTime) && this.local.currentTime > 0) return this.local.currentTime;
    return this._currentTime > 0 ? this._currentTime : 0;
  }

  private stopLocal(clearSrc: boolean): void {
    this.local.pause();
    if (clearSrc) {
      this.local.removeAttribute("src");
      this.local.load();
    }
  }

  private stale(op: number): boolean {
    return this.destroyed || op !== this.op;
  }

  private setCast(next: CastInfo): void {
    if (this.destroyed) return;
    this._cast = {
      available: !!next.available,
      connected: !!next.connected,
      name: next.name,
      error: next.error,
      output: next.output ?? this._cast.output ?? "local",
    };
    this.dispatchEvent(new CustomEvent("cast", { detail: this._cast }));
  }

  private async probe(): Promise<SpeakerStatus | null> {
    try {
      return await this.client.status();
    } catch (error) {
      if (error instanceof SpeakerDisconnectedError && error.message.includes("Sign in")) {
        this.authFailed = true;
      }
      return null;
    }
  }

  private async refreshAvailability(op: number): Promise<void> {
    const seq = this.mutateSeq;
    const episodeId = this._episodeId;
    const status = await this.probe();
    if (this.destroyed || op !== this.op) return;
    if (!status) {
      if (this._cast.output !== "mac") {
        this.setCast({ ...this._cast, available: false, connected: false });
        return;
      }
      this.setCast({
        ...this._cast,
        available: false,
        connected: false,
        error: "Mac is not reachable on this Wi-Fi.",
      });
      return;
    }
    this.authFailed = false;
    if (this._cast.output !== "mac") {
      this.setCast({
        available: !!status.available,
        connected: false,
        name: status.name ?? "Mac",
        output: "local",
        error: this._cast.error,
      });
      return;
    }
    if (status.episode_id != null && episodeId != null && status.episode_id !== episodeId) {
      this.setCast({
        ...this._cast,
        available: !!status.available,
        name: status.name ?? this._cast.name,
      });
      return;
    }
    if (seq !== this.mutateSeq) {
      this.setCast({
        ...this._cast,
        available: !!status.available,
        name: status.name ?? this._cast.name,
      });
      return;
    }
    this.applyRemote(op, seq, status, false);
  }

  private async loadMac(
    op: number,
    episodeId: number | undefined,
    artifactHash: string | undefined,
    position: number,
    playing: boolean,
  ): Promise<void> {
    if (this.stale(op)) return;
    if (episodeId == null || !artifactHash) {
      this.setCast({
        ...this._cast,
        output: "mac",
        connected: false,
        error: "Play a processed episode before using the Mac speaker.",
      });
      return;
    }
    this.stopLocal(false);
    const seq = ++this.mutateSeq;
    try {
      const status = await this.client.load({
        episode_id: episodeId,
        artifact_hash: artifactHash,
        session_id: this.sessionId,
        generation: this.generation,
        position,
        rate: this._playbackRate,
        playing,
      });
      if (this.stale(op)) {
        if (status.session_id === this.sessionId && status.connected) {
          try {
            await this.client.disconnect({ session_id: this.sessionId, generation: status.generation });
          } catch { /* Late load must not keep Mac audio after close. */ }
        }
        return;
      }
      this.applyRemote(op, seq, status, true);
    } catch (error) {
      if (this.stale(op)) return;
      throw error;
    }
  }

  private async command(
    op: number,
    seq: number,
    send: (identity: SpeakerIdentity) => Promise<SpeakerStatus>,
  ): Promise<void> {
    if (this.stale(op)) return;
    const identity = this.identity();
    if (!identity) return;
    try {
      const status = await send(identity);
      if (this.stale(op)) return;
      this.applyRemote(op, seq, status, true);
    } catch (error) {
      if (this.stale(op)) return;
      throw error;
    }
  }

  private applyRemote(op: number, seq: number, status: SpeakerStatus, expectControl: boolean): void {
    if (this.stale(op) || this.destroyed) return;
    if (this._cast.output !== "mac" && !expectControl) {
      this.setCast({
        available: !!status.available,
        connected: false,
        name: status.name ?? "Mac",
        output: "local",
        error: this._cast.error,
      });
      return;
    }
    if (status.session_id && status.session_id !== this.sessionId && status.connected) {
      this.lostControl = true;
      this.ownsSession = false;
      this.stopPoll();
      this.setCast({
        available: status.available,
        connected: false,
        name: status.name ?? "Mac",
        output: this._cast.output,
        error: "Another session took the Mac speaker.",
      });
      return;
    }
    if (expectControl && status.episode_id != null && this._episodeId != null && status.episode_id !== this._episodeId) {
      return;
    }
    if (status.generation > 0 && this.generation > 0 && status.generation < this.generation) return;
    if (status.generation > 0) this.generation = status.generation;
    if (status.duration > 0) this._duration = status.duration;
    this.pollFailures = 0;
    const connected = !!status.connected && this._cast.output === "mac";
    if (connected) {
      this.lostControl = false;
      this.ownsSession = true;
    }
    if (!expectControl) {
      this.setCast({
        available: !!status.available,
        connected: this._cast.connected,
        name: status.name ?? this._cast.name ?? "Mac",
        output: this._cast.output,
        error: this._cast.error,
      });
      return;
    }
    this.setCast({
      available: !!status.available,
      connected,
      name: status.name ?? "Mac",
      output: this._cast.output,
      error: this._cast.output === "mac" ? status.error ?? undefined : undefined,
    });
    if (connected) this.startPoll();
    if (seq !== this.mutateSeq && !status.ended) return;
    if (this._cast.output !== "mac") return;
    if (Number.isFinite(status.position)) {
      this._currentTime = Math.max(0, status.position);
    }
    if (status.rate > 0) this._playbackRate = status.rate;
    this._paused = status.paused || status.ended;
    if (status.ended && this._episodeId != null) {
      const key = `${this._episodeId}:${status.generation}`;
      if (this.endedKey !== key && (status.episode_id == null || status.episode_id === this._episodeId)) {
        this.endedKey = key;
        this.dispatchEvent(new Event("ended"));
      }
      return;
    }
    if (Number.isFinite(status.position)) this.dispatchEvent(new Event("timeupdate"));
    if (status.duration > 0 && !this.reportedDuration) {
      this.reportedDuration = true;
      this.dispatchEvent(new Event("loadedmetadata"));
    }
    if (this.emittedPaused !== this._paused) {
      this.emittedPaused = this._paused;
      this.dispatchEvent(new Event(this._paused ? "pause" : "play"));
    }
  }

  private startPoll(): void {
    if (this.pollTimer != null || this._cast.output !== "mac") return;
    this.pollTimer = window.setInterval(() => {
      void this.pollOnce();
    }, POLL_MS);
  }

  private stopPoll(): void {
    if (this.pollTimer != null) {
      window.clearInterval(this.pollTimer);
      this.pollTimer = undefined;
    }
    this.pollBusy = false;
  }

  private async pollOnce(): Promise<void> {
    if (this.pollBusy || this._cast.output !== "mac" || this.destroyed) {
      if (this._cast.output !== "mac") this.stopPoll();
      return;
    }
    this.pollBusy = true;
    const op = this.op;
    const seq = this.mutateSeq;
    try {
      const status = await this.client.status();
      if (this.stale(op) || seq !== this.mutateSeq) return;
      this.applyRemote(op, seq, status, true);
    } catch (error) {
      if (this.stale(op)) return;
      this.pollFailures += 1;
      if (this.pollFailures >= MAX_POLL_FAILURES || error instanceof SpeakerDisconnectedError) {
        this.stopPoll();
        this.lostControl = true;
        this.setCast({
          available: false,
          connected: false,
          output: "mac",
          error: "Mac speaker disconnected.",
        });
      }
    } finally {
      this.pollBusy = false;
    }
  }

  private prepareLocalPaused(position: number, rate: number): void {
    this._paused = true;
    this._currentTime = position;
    this._playbackRate = rate;
    if (!this._src) return;
    this.pendingRestore = { position, playing: false, rate };
    if (this.local.src === this._src) {
      this.local.playbackRate = rate;
      this.local.currentTime = position;
      this.pendingRestore = null;
      this.local.pause();
      return;
    }
    this.local.src = this._src;
  }

  private async stopRemote(op: number, restoreLocal: boolean): Promise<void> {
    this.stopPoll();
    if (this._cast.connected) {
      this.setCast({ ...this._cast, connected: false });
    }
    let position = this._currentTime;
    const rate = this._playbackRate;
    const playing = restoreLocal && !this._paused && !this.macMayBePlaying;
    const identity = this.identity();
    if (identity) {
      try {
        const status = await this.client.disconnect(identity);
        this.ownsSession = false;
        this.macMayBePlaying = false;
        if (status.generation > 0) this.generation = status.generation;
        if (this.destroyed) return;
        if (this.stale(op)) return;
        if (Number.isFinite(status.position) && status.position >= 0) {
          position = status.position;
          this._currentTime = status.position;
        }
      } catch {
        if (this.destroyed) return;
        if (this.stale(op)) return;
        this.macMayBePlaying = true;
        this.lostControl = true;
        this.prepareLocalPaused(position, rate);
        this.setCast({
          available: this._cast.available,
          connected: false,
          name: this._cast.name,
          output: "local",
          error: UNCONFIRMED_STOP,
        });
        return;
      }
    }
    if (this.destroyed || this.stale(op)) return;
    this.setCast({
      available: this._cast.available,
      connected: false,
      name: this._cast.name,
      output: restoreLocal ? "local" : this._cast.output,
      error: undefined,
    });
    if (!restoreLocal) {
      this._paused = true;
      return;
    }
    this._currentTime = position;
    this._playbackRate = rate;
    if (!this._src) return;
    this.pendingRestore = { position, playing, rate };
    if (this.local.src === this._src) {
      this.local.playbackRate = rate;
      this.local.currentTime = position;
      this.pendingRestore = null;
      if (playing) this.tryLocalPlay();
      else this.local.pause();
      return;
    }
    this.local.src = this._src;
  }

  private tryLocalPlay(): void {
    if (this.destroyed || this._cast.output !== "local") return;
    const op = this.op;
    const src = this._src;
    void this.local.play().catch(() => {
      if (this.destroyed || this.stale(op) || this._cast.output !== "local" || this._src !== src) {
        return;
      }
      this._paused = true;
      this.local.pause();
      this.dispatchEvent(new Event("pause"));
    });
  }

  private handleRemoteError(error: unknown): void {
    const message = error instanceof Error ? error.message : "Mac speaker failed.";
    const disconnected = error instanceof SpeakerDisconnectedError;
    const stale = error instanceof SpeakerStaleError;
    const resync = error instanceof SpeakerResyncError;
    if (stale || disconnected || resync) this.lostControl = true;
    this.stopPoll();
    this.setCast({
      available: !disconnected && this._cast.available,
      connected: false,
      output: this._cast.output,
      error: stale ? RECONNECT_HINT : message,
    });
  }

  private enqueue(op: number, work: () => Promise<void>): Promise<void> {
    const next = (this.inFlight ?? Promise.resolve()).then(async () => {
      if (this.stale(op) && !this.destroyed) return;
      await work();
    });
    this.inFlight = next.then(() => undefined, () => undefined);
    return next.then(
      () => undefined,
      (error: unknown) => {
        if (!this.stale(op)) this.handleRemoteError(error);
        throw error;
      },
    );
  }
}
