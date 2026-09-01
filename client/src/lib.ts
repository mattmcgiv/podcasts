/** 65 -> "1:05", 3725 -> "1:02:05" */
export function fmtTime(secs: number): string {
  const s = Math.max(0, Math.floor(secs));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  const mm = h > 0 ? String(m).padStart(2, "0") : String(m);
  return `${h > 0 ? `${h}:` : ""}${mm}:${String(sec).padStart(2, "0")}`;
}

/** 3725 -> "1h 2m", 1500 -> "25m" */
export function fmtDuration(secs: number | null): string {
  if (secs == null || secs <= 0) return "";
  const h = Math.floor(secs / 3600);
  const m = Math.round((secs % 3600) / 60);
  if (h > 0) return `${h}h ${m}m`;
  if (m === 0) return "<1m";
  return `${m}m`;
}

export function fmtDate(unixSecs: number, now: Date = new Date()): string {
  if (!unixSecs) return "";
  const d = new Date(unixSecs * 1000);
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const that = new Date(d.getFullYear(), d.getMonth(), d.getDate());
  const days = Math.round((today.getTime() - that.getTime()) / 86_400_000);
  if (days === 0) return "Today";
  if (days === 1) return "Yesterday";
  const opts: Intl.DateTimeFormatOptions =
    d.getFullYear() === now.getFullYear()
      ? { month: "short", day: "numeric" }
      : { month: "short", day: "numeric", year: "numeric" };
  return d.toLocaleDateString(undefined, opts);
}

/** Remaining-time label for a partially played episode. */
export function fmtRemaining(item: { duration_secs: number | null; position_secs: number }): string {
  if (!item.duration_secs || item.position_secs <= 0) return fmtDuration(item.duration_secs);
  const left = Math.max(0, item.duration_secs - item.position_secs);
  return `${fmtDuration(left)} left`;
}

export function progressFraction(item: {
  duration_secs: number | null;
  position_secs: number;
}): number {
  if (!item.duration_secs || item.duration_secs <= 0) return 0;
  return Math.min(1, Math.max(0, item.position_secs / item.duration_secs));
}

export function cloudClassifierCopy(settings: {
  classifier_available: boolean;
  classifier_unavailable_reason: string | null;
}): {
  status: string;
  recovery: string | null;
  canEnable: boolean;
  shouldPoll: boolean;
} {
  if (settings.classifier_available) {
    return {
      status: "Cloud classifier: DeepSeek V4 Pro ready",
      recovery: null,
      canEnable: true,
      shouldPoll: false,
    };
  }
  return {
    status: "DeepSeek API key required.",
    recovery: "Save a DeepSeek API key in Settings to resume ad finding.",
    canEnable: false,
    shouldPoll: false,
  };
}
