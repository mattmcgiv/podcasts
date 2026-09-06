// Rename the app here (and in public/manifest.webmanifest).
export const APP_NAME = "Pods";

// Kept as a bounded rollout switch until appearance following is ready to return.
export const FOLLOW_APPEARANCES_ENABLED = false;

export const SKIP_FORWARD_SECS = 30;
export const SKIP_BACK_SECS = 15;
export const SPEEDS = [1, 1.5, 2, 2.5, 3] as const;
export const POSITION_SYNC_INTERVAL_MS = 5000;
