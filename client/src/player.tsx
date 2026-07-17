import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { Api } from "./api";
import {
  createAudioEngine,
  type AudioEngine,
  type AudioMetadata,
  type AdSkipNotice,
  type CastInfo,
} from "./audioEngine";
import { POSITION_SYNC_INTERVAL_MS, SKIP_BACK_SECS, SKIP_FORWARD_SECS } from "./config";
import { emitEpisodesChanged } from "./events";
import type { EpisodeItem, PlayContext } from "./types";

export type PlayerEpisode = EpisodeItem & { notes_html?: string };

export interface PlayerApi {
  current: PlayerEpisode | null;
  playing: boolean;
  initializing: boolean;
  expanded: boolean;
  position: number;
  duration: number;
  speed: number;
  autoplay: boolean;
  cast: CastInfo;
  pendingAdSkip: AdSkipNotice | null;
  playEpisode: (item: EpisodeItem, context: PlayContext) => void;
  toggle: () => void;
  seekTo: (secs: number) => void;
  skipForward: () => void;
  skipBack: () => void;
  setSpeed: (speed: number, correlationId?: string) => void;
  setAutoplay: (on: boolean) => void;
  setExpanded: (on: boolean) => void;
  setCastOutput: (target: "local" | "mac") => void;
  undoAdSkip: () => void;
  markPlayedAndClose: () => Promise<void>;
  close: () => void;
}

const PlayerContext = createContext<PlayerApi | null>(null);

export function usePlayer(): PlayerApi {
  const ctx = useContext(PlayerContext);
  if (!ctx) throw new Error("usePlayer outside PlayerProvider");
  return ctx;
}

export function PlayerProvider({ children }: { children: ReactNode }) {
  const [current, setCurrent] = useState<PlayerEpisode | null>(null);
  const [playing, setPlaying] = useState(false);
  const [initializing, setInitializing] = useState(false);
  const [expanded, setExpanded] = useState(false);
  const [position, setPosition] = useState(0);
  const [duration, setDuration] = useState(0);
  const [speed, setSpeedState] = useState(1);
  const [autoplay, setAutoplayState] = useState(true);
  const [cast, setCast] = useState<CastInfo>({ available: false, connected: false, output: "local" });
  const [pendingAdSkip, setPendingAdSkip] = useState<AdSkipNotice | null>(null);

  const audioRef = useRef<AudioEngine | null>(null);
  const currentRef = useRef<PlayerEpisode | null>(null);
  const contextRef = useRef<PlayContext>("recent");
  const speedRef = useRef(1);
  const autoplayRef = useRef(true);
  const resumeAtRef = useRef(0);
  /** True while mark-played → next is in flight for one asynchronous completion. */
  const endInFlightRef = useRef(false);

  currentRef.current = current;

  const flushPosition = useCallback(() => {
    const a = audioRef.current;
    const cur = currentRef.current;
    if (a && cur && a.currentTime > 0) {
      void Api.setPosition(cur.id, a.currentTime).catch(() => {});
    }
  }, []);

  const close = useCallback(() => {
    const a = audioRef.current;
    if (a) {
      flushPosition();
      a.pause();
      a.removeAttribute("src");
      a.load();
    }
    setCurrent(null);
    setPlaying(false);
    setInitializing(false);
    setExpanded(false);
    setPosition(0);
    setDuration(0);
    setPendingAdSkip(null);
  }, [flushPosition]);

  const playEpisode = useCallback(
    (item: EpisodeItem, context: PlayContext) => {
      if (currentRef.current?.id === item.id) {
        contextRef.current = context;
        setExpanded(true);
        return;
      }
      flushPosition();
      const a = ensureAudio();
      contextRef.current = context;
      setCurrent(item);
      currentRef.current = item;
      setExpanded(true);
      setPosition(item.position_secs);
      setDuration(item.duration_secs ?? 0);
      setPendingAdSkip(null);
      setInitializing(true);
      const resumeAt = item.position_secs > 1 ? item.position_secs : 0;
      resumeAtRef.current = a.loadSource ? 0 : resumeAt;
      const metadata = audioMetadata(item);
      a.setMetadata?.(metadata);
      a.playbackRate = speedRef.current;
      if (a.loadSource) {
        a.loadSource(item.audio_url, resumeAt, item.id);
      } else {
        a.src = item.audio_url;
      }
      void a.play().catch(() => {
        setPlaying(false);
        setInitializing(false);
      });
      updateMediaSessionMetadata(metadata);
      // Upgrade to the full detail (show notes) in the background.
      void Api.episode(item.id)
        .then((detail) => {
          if (currentRef.current?.id === item.id) {
            setCurrent((prev) => (prev && prev.id === item.id ? { ...prev, ...detail } : prev));
          }
        })
        .catch(() => {});
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [flushPosition],
  );

  const handleEnded = useCallback(async () => {
    // In-flight guard only: duplicate ended during one async completion transition.
    // Stale cross-episode ended is filtered by NativeAudioEngine episode identity.
    if (endInFlightRef.current) return;
    const cur = currentRef.current;
    if (!cur) return;
    endInFlightRef.current = true;
    const completedId = cur.id;
    try {
      try {
        await Api.markPlayed(completedId);
        emitEpisodesChanged();
      } catch {
        // offline mark failure shouldn't wedge the player
      }
      // User (or a prior completion) already moved on — do not chain from a stale end.
      if (currentRef.current?.id !== completedId) return;
      if (autoplayRef.current) {
        const next = await Api.next(completedId, contextRef.current).catch(() => null);
        if (currentRef.current?.id !== completedId) return;
        if (next) {
          playEpisode(next, contextRef.current);
          return;
        }
      }
      close();
    } finally {
      endInFlightRef.current = false;
    }
  }, [close, playEpisode]);

  const endedRef = useRef(handleEnded);
  endedRef.current = handleEnded;

  function ensureAudio(): AudioEngine {
    if (audioRef.current) return audioRef.current;
    const a = createAudioEngine();
    a.preload = "metadata";
    a.addEventListener("play", () => setPlaying(true));
    a.addEventListener("pause", () => {
      setPlaying(false);
      flushPosition();
    });
    const adoptDuration = () => {
      if (Number.isFinite(a.duration) && a.duration > 0) setDuration(a.duration);
    };
    a.addEventListener("timeupdate", () => {
      setInitializing(false);
      setPosition(a.currentTime);
      adoptDuration();
    });
    a.addEventListener("loadedmetadata", () => {
      setInitializing(false);
      adoptDuration();
      if (resumeAtRef.current > 0) {
        a.currentTime = resumeAtRef.current;
        resumeAtRef.current = 0;
      }
      a.playbackRate = speedRef.current;
    });
    a.addEventListener("ended", () => void endedRef.current());
    a.addEventListener("error", () => setInitializing(false));
    a.addEventListener("cast", ((e: Event) => {
      const detail = (e as CustomEvent<CastInfo>).detail;
      if (detail) setCast(detail);
    }) as EventListener);
    a.addEventListener("adSkip", ((e: Event) => {
      const detail = (e as CustomEvent<AdSkipNotice>).detail;
      if (detail) setPendingAdSkip(detail);
      setPosition(a.currentTime);
    }) as EventListener);
    a.addEventListener("adSkipUndone", () => {
      setPendingAdSkip(null);
      setPosition(a.currentTime);
    });
    a.requestCastStatus?.();
    audioRef.current = a;
    return a;
  }

  // Ensure cast discovery starts even before the first play.
  useEffect(() => {
    ensureAudio();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Periodic position sync while playing.
  useEffect(() => {
    if (!playing) return;
    const t = setInterval(() => {
      flushPosition();
      syncMediaSessionPosition(audioRef.current);
    }, POSITION_SYNC_INTERVAL_MS);
    return () => clearInterval(t);
  }, [playing, flushPosition]);

  // Load persisted settings once.
  useEffect(() => {
    void Api.settings()
      .then((s) => {
        setSpeedState(s.speed);
        speedRef.current = s.speed;
        setAutoplayState(s.autoplay);
        autoplayRef.current = s.autoplay;
        if (audioRef.current) audioRef.current.playbackRate = s.speed;
      })
      .catch(() => {});
  }, []);

  const setSpeed = useCallback((value: number, correlationId?: string) => {
    setSpeedState(value);
    speedRef.current = value;
    if (audioRef.current) {
      if (correlationId && audioRef.current.setPlaybackRate) {
        console.log(`speed_bridge_send correlation_id=${correlationId} requested_rate=${value}`);
        audioRef.current.setPlaybackRate(value, correlationId);
      } else {
        audioRef.current.playbackRate = value;
      }
    }
    void Api.saveSettings({ speed: value, autoplay: autoplayRef.current }).catch(() => {});
  }, []);

  const setAutoplay = useCallback((on: boolean) => {
    setAutoplayState(on);
    autoplayRef.current = on;
    void Api.saveSettings({ speed: speedRef.current, autoplay: on }).catch(() => {});
  }, []);

  const toggle = useCallback(() => {
    const a = audioRef.current;
    if (!a || !currentRef.current) return;
    if (a.paused) void a.play().catch(() => {});
    else a.pause();
  }, []);

  const seekTo = useCallback((secs: number) => {
    const a = audioRef.current;
    if (!a) return;
    a.currentTime = Math.max(0, secs);
    setPosition(a.currentTime);
  }, []);

  const skipForward = useCallback(() => {
    const a = audioRef.current;
    if (a) seekTo(a.currentTime + SKIP_FORWARD_SECS);
  }, [seekTo]);

  const skipBack = useCallback(() => {
    const a = audioRef.current;
    if (a) seekTo(a.currentTime - SKIP_BACK_SECS);
  }, [seekTo]);

  const markPlayedAndClose = useCallback(async () => {
    const cur = currentRef.current;
    if (!cur) return;
    try {
      await Api.markPlayed(cur.id);
      emitEpisodesChanged();
    } catch {
      // leave the player open if the call failed? No: close anyway, list reload will resync.
    }
    close();
  }, [close]);

  const setCastOutput = useCallback((target: "local" | "mac") => {
    const a = ensureAudio();
    if (target === "mac") {
      a.castConnect?.();
      setCast((prev) => ({ ...prev, output: "mac" }));
    } else {
      a.castDisconnect?.();
      setCast((prev) => ({ ...prev, output: "local", connected: false }));
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const undoAdSkip = useCallback(() => {
    audioRef.current?.undoAdSkip?.();
  }, []);

  // Lock-screen / hardware controls.
  useEffect(() => {
    const ms = navigator.mediaSession;
    if (!ms) return;
    try {
      ms.setActionHandler("play", () => toggle());
      ms.setActionHandler("pause", () => toggle());
      ms.setActionHandler("seekbackward", () => skipBack());
      ms.setActionHandler("seekforward", () => skipForward());
      ms.setActionHandler("seekto", (d) => {
        if (d.seekTime != null) seekTo(d.seekTime);
      });
    } catch {
      // older safari: unsupported action names throw
    }
  }, [toggle, skipBack, skipForward, seekTo]);

  const value = useMemo<PlayerApi>(
    () => ({
      current,
      playing,
      initializing,
      expanded,
      position,
      duration,
      speed,
      autoplay,
      cast,
      pendingAdSkip,
      playEpisode,
      toggle,
      seekTo,
      skipForward,
      skipBack,
      setSpeed,
      setAutoplay,
      setExpanded,
      setCastOutput,
      undoAdSkip,
      markPlayedAndClose,
      close,
    }),
    [
      current,
      playing,
      initializing,
      expanded,
      position,
      duration,
      speed,
      autoplay,
      cast,
      pendingAdSkip,
      playEpisode,
      toggle,
      seekTo,
      skipForward,
      skipBack,
      setSpeed,
      setAutoplay,
      setCastOutput,
      undoAdSkip,
      markPlayedAndClose,
      close,
    ],
  );

  return <PlayerContext.Provider value={value}>{children}</PlayerContext.Provider>;
}

function audioMetadata(item: EpisodeItem): AudioMetadata {
  const art = item.image_url || item.podcast_image;
  return {
    title: item.title,
    artist: item.podcast_title,
    artwork: art ? absoluteArtworkUrl(art) : undefined,
    duration: item.duration_secs ?? undefined,
  };
}

function absoluteArtworkUrl(src: string): string {
  try {
    return new URL(src, window.PODS_API_BASE ?? window.location.origin).href;
  } catch {
    return src;
  }
}

function updateMediaSessionMetadata(metadata: AudioMetadata): void {
  const ms = navigator.mediaSession;
  if (!ms || typeof MediaMetadata === "undefined") return;
  try {
    ms.metadata = new MediaMetadata({
      title: metadata.title,
      artist: metadata.artist,
      artwork: metadata.artwork ? [{ src: metadata.artwork }] : [],
    });
  } catch {
    // metadata is best-effort
  }
}

function syncMediaSessionPosition(a: AudioEngine | null): void {
  const ms = navigator.mediaSession;
  if (!a || !ms || typeof ms.setPositionState !== "function") return;
  if (!Number.isFinite(a.duration) || a.duration <= 0) return;
  try {
    ms.setPositionState({
      duration: a.duration,
      playbackRate: a.playbackRate,
      position: Math.min(a.currentTime, a.duration),
    });
  } catch {
    // best-effort
  }
}
