export type PodsLifecycleEvent = "ui-ready" | "ui-failed";

type PodsLifecycleWindow = Window & {
  __PODS_UI_READY?: boolean;
  webkit?: {
    messageHandlers?: {
      podsLifecycle?: {
        postMessage(message: { event: PodsLifecycleEvent }): void;
      };
    };
  };
};

export function postPodsLifecycleEvent(event: PodsLifecycleEvent): void {
  if (typeof window === "undefined") return;

  const lifecycleWindow = window as PodsLifecycleWindow;
  lifecycleWindow.__PODS_UI_READY = event === "ui-ready";
  const handler = lifecycleWindow.webkit?.messageHandlers?.podsLifecycle;
  try {
    handler?.postMessage({ event });
  } catch {
    // Lifecycle reporting must never turn a recoverable UI state into a blank screen.
  }
}
