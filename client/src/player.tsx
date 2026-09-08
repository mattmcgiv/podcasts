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
import { offlineEnabled } from "./offline/client";
import { protectPlayingArtifact } from "./offline/downloads";
import {
  createAudioEngine,
  hasNativeAudioBridge,
  type AudioEngine,
  type AudioMetadata,
  type AdSkipNotice,
  type CastInfo,
} from "./audioEngine";
import { POSITION_SYNC_INTERVAL_MS, SKIP_BACK_SECS, SKIP_FORWARD_SECS } from "./config";
import { emitEpisodesChanged } from "./events";
import type { EpisodeAdMarker, EpisodeItem, EpisodeShowNote, PlayContext } from "./types";

export type PlayerEpisode = EpisodeItem & {
  notes_html?: string;
  show_notes?: EpisodeShowNote[];
  ad_markers?: EpisodeAdMarker[];
};

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
  showNotesGenerating: boolean;
  showNotesError: string | null;
  playEpisode: (item: EpisodeItem, context: PlayContext) => void;
  toggle: () => void;
  seekTo: (secs: number) => void;
  skipForward: () => void;
  skipBack: () => void;
  setSpeed: (speed: number, correlationId?: string) => void;
  setAutoplay: (on: boolean) => void;
  setExpanded: (on: boolean) => void;
  setCastOutput: (target: "local" | "mac") => void;
  retryMacAvailability: () => void;
  undoAdSkip: () => void;
  retryShowNotes: () => void;
  markPlayedAndClose: () => Promise<void>;
  close: () => void;
}

const PlayerContext = createContext<PlayerApi | null>(null);
const SHOW_NOTES_STATUS_POLL_MS = 2_000;
const ACTIVE_AD_REMOVAL_STAGES = new Set([
  "queued",
  "downloading",
  "downloaded",
  "transcribing",
  "classifying",
]);

interface EpisodeVisit {
  episodeID: number;
  generation: number;
  nextOperation: number;
  acceptedOperation: number;
}

interface EpisodeVisitOperation {
  episodeID: number;
  visitGeneration: number;
  sequence: number;
}

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
  const [showNotesGenerating, setShowNotesGenerating] = useState(false);
  const [showNotesError, setShowNotesError] = useState<string | null>(null);

  const audioRef = useRef<AudioEngine | null>(null);
  const currentRef = useRef<PlayerEpisode | null>(null);
  const playingHashRef = useRef<string | undefined>(undefined);
  const contextRef = useRef<PlayContext>("recent");
  const speedRef = useRef(1);
  const autoplayRef = useRef(true);
  const resumeAtRef = useRef(0);
  /** True while mark-played → next is in flight for one asynchronous completion. */
  const endInFlightRef = useRef(false);
  const nextEpisodeVisitGenerationRef = useRef(0);
  const currentEpisodeVisitRef = useRef<EpisodeVisit | null>(null);
  const showNotesRequestsRef = useRef(new Map<number, Promise<EpisodeShowNote[]>>());

  currentRef.current = current;

  const flushPosition = useCallback(() => {
    const a = audioRef.current;
    const cur = currentRef.current;
    // new Audio() reports 0 until loadedmetadata applies a pending nonzero resume.
    if (a && cur && Number.isFinite(a.currentTime) && (a.currentTime > 0 || (offlineEnabled() && a.currentTime === 0 && resumeAtRef.current === 0))) {
      const saved = offlineEnabled() ? Api.setPosition(cur.id, a.currentTime, playingHashRef.current) : Api.setPosition(cur.id, a.currentTime);
      void saved.catch(() => {});
    }
  }, []);

  const beginVisitOperation = useCallback((episodeID: number): EpisodeVisitOperation | null => {
    const visit = currentEpisodeVisitRef.current;
    if (currentRef.current?.id !== episodeID || visit?.episodeID !== episodeID) return null;
    const sequence = ++visit.nextOperation;
    return { episodeID, visitGeneration: visit.generation, sequence };
  }, []);

  const acceptVisitOperation = useCallback((operation: EpisodeVisitOperation): boolean => {
    const visit = currentEpisodeVisitRef.current;
    if (
      currentRef.current?.id !== operation.episodeID
      || visit?.episodeID !== operation.episodeID
      || visit.generation !== operation.visitGeneration
      || operation.sequence < visit.acceptedOperation
    ) return false;
    visit.acceptedOperation = operation.sequence;
    return true;
  }, []);

  const close = useCallback(() => {
    const a = audioRef.current;
    if (a) {
      flushPosition();
      a.pause();
      a.removeAttribute("src");
      protectPlayingArtifact(null);
      a.load();
    }
    currentRef.current = null;
    currentEpisodeVisitRef.current = null;
    setCurrent(null);
    setPlaying(false);
    setInitializing(false);
    setExpanded(false);
    setPosition(0);
    setDuration(0);
    setPendingAdSkip(null);
    setShowNotesGenerating(false);
    setShowNotesError(null);
  }, [flushPosition]);

  useEffect(() => {
    const onClose = (event: Event) => {
      const id = (event as CustomEvent<{ id?: number }>).detail?.id;
      if (endInFlightRef.current) return;
      if (currentRef.current?.id === id) close();
    };
    window.addEventListener("pods-close-episode", onClose);
    return () => window.removeEventListener("pods-close-episode", onClose);
  }, [close]);

  const requestShowNotes = useCallback((episodeID: number) => {
    const operation = beginVisitOperation(episodeID);
    if (!operation || !acceptVisitOperation(operation)) return;

    setShowNotesGenerating(true);
    setShowNotesError(null);

    let request = showNotesRequestsRef.current.get(episodeID);
    if (!request) {
      request = Api.generateShowNotes(episodeID);
      showNotesRequestsRef.current.set(episodeID, request);
      void request.then(
        () => {
          if (showNotesRequestsRef.current.get(episodeID) === request) {
            showNotesRequestsRef.current.delete(episodeID);
          }
        },
        () => {
          if (showNotesRequestsRef.current.get(episodeID) === request) {
            showNotesRequestsRef.current.delete(episodeID);
          }
        },
      );
    }

    void request
      .then((notes) => {
        if (!acceptVisitOperation(operation)) return;
        setCurrent((prev) =>
          prev?.id === episodeID ? { ...prev, show_notes: notes } : prev,
        );
      })
      .catch(() => {
        if (!acceptVisitOperation(operation)) return;
        setShowNotesError("Show notes could not be generated. Please try again.");
      })
      .finally(() => {
        if (acceptVisitOperation(operation)) setShowNotesGenerating(false);
      });
  }, [acceptVisitOperation, beginVisitOperation]);

  const loadEpisodeDetail = useCallback(
    (episodeID: number) => {
      const operation = beginVisitOperation(episodeID);
      if (!operation) return;
      void Api.episode(episodeID)
        .then((detail) => {
          if (!acceptVisitOperation(operation)) return;
          if (offlineEnabled() && detail.manifest?.hash !== playingHashRef.current) return;
          setCurrent((prev) => (prev?.id === episodeID ? { ...prev, ...detail } : prev));
          if (detail.show_notes?.length) {
            setShowNotesError(null);
            setShowNotesGenerating(false);
          } else if (detail.ad_removal_stage === "ready") {
            requestShowNotes(episodeID);
          }
        })
        .catch(() => {});
    },
    [acceptVisitOperation, beginVisitOperation, requestShowNotes],
  );

  useEffect(() => {
    const episodeID = current?.id;
    const stage = current?.ad_removal_stage;
    const visitGeneration = currentEpisodeVisitRef.current?.generation;
    if (
      episodeID == null
      || current?.show_notes?.length
      || stage == null
      || !ACTIVE_AD_REMOVAL_STAGES.has(stage)
    ) return;

    let cancelled = false;
    let timer: number | undefined;
    const schedule = () => {
      timer = window.setTimeout(run, SHOW_NOTES_STATUS_POLL_MS);
    };
    const run = () => {
      void Api.adRemovalStatuses([episodeID])
        .then(({ items }) => {
          if (
            cancelled
            || currentRef.current?.id !== episodeID
            || currentEpisodeVisitRef.current?.generation !== visitGeneration
          ) return false;
          const status = items.find((item) => item.id === episodeID);
          if (!status) return true;
          setCurrent((previous) => previous?.id === episodeID ? {
            ...previous,
            ad_removal_state: status.ad_removal_state,
            ad_removal_action: status.ad_removal_action,
            ad_removal_stage: status.ad_removal_stage,
            ad_removal_blocking_reason: status.ad_removal_blocking_reason,
          } : previous);
          if (status.ad_removal_stage === "ready") {
            requestShowNotes(episodeID);
            return false;
          }
          return status.ad_removal_stage != null
            && ACTIVE_AD_REMOVAL_STAGES.has(status.ad_removal_stage);
        })
        .catch(() => true)
        .then((shouldContinue) => {
          if (!cancelled && shouldContinue) schedule();
        });
    };
    schedule();
    return () => {
      cancelled = true;
      if (timer != null) window.clearTimeout(timer);
    };
  }, [current?.id, current?.ad_removal_stage, current?.show_notes?.length, requestShowNotes]);

  const retryShowNotes = useCallback(() => {
    const episodeID = currentRef.current?.id;
    if (episodeID != null) requestShowNotes(episodeID);
  }, [requestShowNotes]);

  const playEpisode = useCallback(
    (item: EpisodeItem, context: PlayContext) => {
      if (currentRef.current?.id === item.id) {
        contextRef.current = context;
        setExpanded(true);
        loadEpisodeDetail(item.id);
        return;
      }
      flushPosition();
      const a = ensureAudio();
      contextRef.current = context;
      if (offlineEnabled() && (!item.downloaded || !item.manifest)) return;
      if (offlineEnabled()) protectPlayingArtifact(item.manifest?.hash ?? null);
      playingHashRef.current = item.manifest?.hash;
      setCurrent(item);
      currentRef.current = item;
      currentEpisodeVisitRef.current = {
        episodeID: item.id,
        generation: ++nextEpisodeVisitGenerationRef.current,
        nextOperation: 0,
        acceptedOperation: 0,
      };
      setExpanded(true);
      setPosition(item.position_secs);
      setDuration(item.duration_secs ?? 0);
      setPendingAdSkip(null);
      setShowNotesGenerating(false);
      setShowNotesError(null);
      setInitializing(true);
      const resumeAt = item.position_secs > 1 ? item.position_secs : 0;
      resumeAtRef.current = hasNativeAudioBridge() || engineOutput(a) === "mac" ? 0 : resumeAt;
      const metadata = audioMetadata(item);
      a.setMetadata?.(metadata);
      a.playbackRate = speedRef.current;
      if (a.loadSource) {
        a.loadSource(item.audio_url, resumeAt, item.id, item.manifest?.hash);
      } else {
        a.src = item.audio_url;
      }
      void a.play().catch(() => {
        setPlaying(false);
        setInitializing(false);
      });
      updateMediaSessionMetadata(metadata);
      // Upgrade to full detail, then generate chapters once for ready transcripts.
      loadEpisodeDetail(item.id);
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [flushPosition, loadEpisodeDetail],
  );

  const handleEnded = useCallback(async () => {
    // In-flight guard only: duplicate ended during one async completion transition.
    // Stale cross-episode ended is filtered by NativeAudioEngine episode identity.
    if (endInFlightRef.current) return;
    const cur = currentRef.current;
    if (!cur) return;
    endInFlightRef.current = true;
    const completedId = cur.id;
    console.log(
      `playback_ended_accepted episode_id=${completedId} autoplay=${autoplayRef.current} context=${contextRef.current}`,
    );
    try {
      try {
        await Api.markPlayed(completedId);
        console.log(`playback_mark_played_succeeded episode_id=${completedId}`);
        emitEpisodesChanged();
      } catch (error) {
        console.warn(
          `playback_mark_played_failed episode_id=${completedId} error=${error instanceof Error ? `${error.name}: ${error.message}` : String(error)}`,
        );
        // offline mark failure shouldn't wedge the player
      }
      // User (or a prior completion) already moved on — do not chain from a stale end.
      if (currentRef.current?.id !== completedId) return;
      if (autoplayRef.current) {
        let next: EpisodeItem | null = null;
        try {
          next = await Api.next(completedId, contextRef.current);
          console.log(
            `playback_next_resolved episode_id=${completedId} next_episode_id=${next?.id ?? "none"} context=${contextRef.current}`,
          );
        } catch (error) {
          console.warn(
            `playback_next_failed episode_id=${completedId} context=${contextRef.current} error=${error instanceof Error ? `${error.name}: ${error.message}` : String(error)}`,
          );
        }
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
    const a = ensureAudio();
    return () => {
      a.dispose?.();
      if (audioRef.current === a) audioRef.current = null;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Periodic position sync while playing.
  useEffect(() => {
    if (!offlineEnabled()) return;
    const hidden = () => { if (document.visibilityState === "hidden") flushPosition(); };
    document.addEventListener("visibilitychange", hidden);
    window.addEventListener("pagehide", flushPosition);
    return () => { document.removeEventListener("visibilitychange", hidden); window.removeEventListener("pagehide", flushPosition); };
  }, [flushPosition]);

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
    if (!a || !Number.isFinite(secs)) return;
    resumeAtRef.current = 0;
    a.currentTime = Math.max(0, secs);
    setPosition(a.currentTime);
    if (offlineEnabled()) flushPosition();
  }, [flushPosition]);

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
    const id = cur.id;
    close();
    try {
      await Api.markPlayed(id);
      emitEpisodesChanged();
    } catch {
      // Playback already stopped. List reload resyncs if the mark-played call failed.
    }
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

  const retryMacAvailability = useCallback(() => {
    ensureAudio().requestCastStatus?.();
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
      showNotesGenerating,
      showNotesError,
      playEpisode,
      toggle,
      seekTo,
      skipForward,
      skipBack,
      setSpeed,
      setAutoplay,
      setExpanded,
      setCastOutput,
      retryMacAvailability,
      undoAdSkip,
      retryShowNotes,
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
      showNotesGenerating,
      showNotesError,
      playEpisode,
      toggle,
      seekTo,
      skipForward,
      skipBack,
      setSpeed,
      setAutoplay,
      setCastOutput,
      retryMacAvailability,
      undoAdSkip,
      retryShowNotes,
      markPlayedAndClose,
      close,
    ],
  );

  return <PlayerContext.Provider value={value}>{children}</PlayerContext.Provider>;
}

function engineOutput(a: AudioEngine): "local" | "mac" {
  return (a as AudioEngine & { cast?: CastInfo }).cast?.output === "mac" ? "mac" : "local";
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
