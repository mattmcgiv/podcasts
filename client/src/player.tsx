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
import { POSITION_SYNC_INTERVAL_MS, SKIP_BACK_SECS, SKIP_FORWARD_SECS } from "./config";
import { emitEpisodesChanged } from "./events";
import type { EpisodeItem, PlayContext } from "./types";

export type PlayerEpisode = EpisodeItem & { notes_html?: string };

export interface PlayerApi {
  current: PlayerEpisode | null;
  playing: boolean;
  expanded: boolean;
  position: number;
  duration: number;
  speed: number;
  autoplay: boolean;
  playEpisode: (item: EpisodeItem, context: PlayContext) => void;
  toggle: () => void;
  seekTo: (secs: number) => void;
  skipForward: () => void;
  skipBack: () => void;
  setSpeed: (speed: number) => void;
  setAutoplay: (on: boolean) => void;
  setExpanded: (on: boolean) => void;
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
  const [expanded, setExpanded] = useState(false);
  const [position, setPosition] = useState(0);
  const [duration, setDuration] = useState(0);
  const [speed, setSpeedState] = useState(1);
  const [autoplay, setAutoplayState] = useState(true);

  const audioRef = useRef<HTMLAudioElement | null>(null);
  const currentRef = useRef<PlayerEpisode | null>(null);
  const contextRef = useRef<PlayContext>("recent");
  const speedRef = useRef(1);
  const autoplayRef = useRef(true);
  const resumeAtRef = useRef(0);

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
    setExpanded(false);
    setPosition(0);
    setDuration(0);
  }, [flushPosition]);

  const playEpisode = useCallback(
    (item: EpisodeItem, context: PlayContext) => {
      flushPosition();
      const a = ensureAudio();
      contextRef.current = context;
      setCurrent(item);
      currentRef.current = item;
      setExpanded(true);
      setPosition(item.position_secs);
      setDuration(item.duration_secs ?? 0);
      resumeAtRef.current = item.position_secs > 1 ? item.position_secs : 0;
      a.src = item.audio_url;
      a.playbackRate = speedRef.current;
      void a.play().catch(() => setPlaying(false));
      updateMediaSessionMetadata(item);
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
    const cur = currentRef.current;
    if (!cur) return;
    try {
      await Api.markPlayed(cur.id);
      emitEpisodesChanged();
    } catch {
      // offline mark failure shouldn't wedge the player
    }
    if (autoplayRef.current) {
      const next = await Api.next(cur.id, contextRef.current).catch(() => null);
      if (next) {
        playEpisode(next, contextRef.current);
        return;
      }
    }
    close();
  }, [close, playEpisode]);

  const endedRef = useRef(handleEnded);
  endedRef.current = handleEnded;

  function ensureAudio(): HTMLAudioElement {
    if (audioRef.current) return audioRef.current;
    const a = new Audio();
    a.preload = "metadata";
    a.addEventListener("play", () => setPlaying(true));
    a.addEventListener("pause", () => {
      setPlaying(false);
      flushPosition();
    });
    a.addEventListener("timeupdate", () => setPosition(a.currentTime));
    a.addEventListener("loadedmetadata", () => {
      if (Number.isFinite(a.duration)) setDuration(a.duration);
      if (resumeAtRef.current > 0) {
        a.currentTime = resumeAtRef.current;
        resumeAtRef.current = 0;
      }
      a.playbackRate = speedRef.current;
    });
    a.addEventListener("ended", () => void endedRef.current());
    audioRef.current = a;
    return a;
  }

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

  const setSpeed = useCallback((value: number) => {
    setSpeedState(value);
    speedRef.current = value;
    if (audioRef.current) audioRef.current.playbackRate = value;
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
      expanded,
      position,
      duration,
      speed,
      autoplay,
      playEpisode,
      toggle,
      seekTo,
      skipForward,
      skipBack,
      setSpeed,
      setAutoplay,
      setExpanded,
      markPlayedAndClose,
      close,
    }),
    [
      current,
      playing,
      expanded,
      position,
      duration,
      speed,
      autoplay,
      playEpisode,
      toggle,
      seekTo,
      skipForward,
      skipBack,
      setSpeed,
      setAutoplay,
      markPlayedAndClose,
      close,
    ],
  );

  return <PlayerContext.Provider value={value}>{children}</PlayerContext.Provider>;
}

function updateMediaSessionMetadata(item: EpisodeItem): void {
  const ms = navigator.mediaSession;
  if (!ms || typeof MediaMetadata === "undefined") return;
  try {
    const art = item.image_url || item.podcast_image;
    ms.metadata = new MediaMetadata({
      title: item.title,
      artist: item.podcast_title,
      artwork: art ? [{ src: art }] : [],
    });
  } catch {
    // metadata is best-effort
  }
}

function syncMediaSessionPosition(a: HTMLAudioElement | null): void {
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
