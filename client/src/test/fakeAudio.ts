/** Stand-in for HTMLAudioElement: jsdom provides the class but no playback. */
export class FakeAudio extends EventTarget {
  static instances: FakeAudio[] = [];

  src = "";
  currentTime = 0;
  duration = NaN;
  playbackRate = 1;
  paused = true;
  preload = "";

  constructor() {
    super();
    FakeAudio.instances.push(this);
  }

  static reset(): void {
    FakeAudio.instances = [];
  }

  static last(): FakeAudio {
    const a = FakeAudio.instances.at(-1);
    if (!a) throw new Error("no Audio instance created");
    return a;
  }

  play(): Promise<void> {
    this.paused = false;
    this.dispatchEvent(new Event("play"));
    return Promise.resolve();
  }

  pause(): void {
    this.paused = true;
    this.dispatchEvent(new Event("pause"));
  }

  load(): void {}

  removeAttribute(name: string): void {
    if (name === "src") this.src = "";
  }

  emitLoadedMetadata(duration: number): void {
    this.duration = duration;
    this.dispatchEvent(new Event("loadedmetadata"));
  }

  emitTime(t: number): void {
    this.currentTime = t;
    this.dispatchEvent(new Event("timeupdate"));
  }

  emitEnded(): void {
    this.dispatchEvent(new Event("ended"));
  }
}
