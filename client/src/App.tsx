import { useEffect, useRef, useState } from "react";
import { MiniPlayer } from "./components/MiniPlayer";
import { PlayerSheet } from "./components/PlayerSheet";
import { TabBar } from "./components/TabBar";
import { PlayerProvider } from "./player";
import { postPodsLifecycleEvent } from "./podsLifecycle";
import { navigate, useRoute } from "./router";
import { PlayedView } from "./views/PlayedView";
import { RecentView } from "./views/RecentView";
import { NotificationsView } from "./views/NotificationsView";
import { ShowDetailView } from "./views/ShowDetailView";
import { ShowsView } from "./views/ShowsView";
import { FollowsView } from "./views/FollowsView";
import { FOLLOW_APPEARANCES_ENABLED } from "./config";
import { applyThemePreference, currentThemePreference } from "./theme";
import { SettingsSheet } from "./views/SettingsSheet";
import { AuthGate } from "./AuthGate";

const SWIPE_TABS = ["recent", "played", "shows", ...(FOLLOW_APPEARANCES_ENABLED ? ["follows"] : []), "settings"] as const;
const SWIPE_DISTANCE_PX = 64;
const SWIPE_DIRECTION_RATIO = 1.4;

type SwipeDirection = "forward" | "back";

function isTextEntryTarget(target: EventTarget | null): boolean {
  return target instanceof Element && target.closest("input, textarea, select, [contenteditable=true]") != null;
}

export function App() {
  useEffect(() => {
    postPodsLifecycleEvent("ui-ready");
    applyThemePreference(currentThemePreference(), false);
  }, []);

  return (
    <AuthGate>
      <PlayerProvider>
        <Shell />
      </PlayerProvider>
    </AuthGate>
  );
}

function Shell() {
  const route = useRoute();
  const swipeStart = useRef<{ x: number; y: number } | null>(null);
  const [swipeDirection, setSwipeDirection] = useState<SwipeDirection | null>(null);

  useEffect(() => {
    if (swipeDirection == null) return;
    const timer = window.setTimeout(() => setSwipeDirection(null), 280);
    return () => window.clearTimeout(timer);
  }, [route.tab, swipeDirection]);

  function onTouchStart(event: React.TouchEvent<HTMLElement>) {
    if (event.touches.length !== 1 || isTextEntryTarget(event.target)) {
      swipeStart.current = null;
      return;
    }
    const touch = event.touches[0];
    swipeStart.current = { x: touch.clientX, y: touch.clientY };
  }

  function onTouchEnd(event: React.TouchEvent<HTMLElement>) {
    const start = swipeStart.current;
    swipeStart.current = null;
    if (!start || event.changedTouches.length !== 1 || route.showId != null || route.notifications) return;
    const touch = event.changedTouches[0];
    const xDistance = touch.clientX - start.x;
    const yDistance = touch.clientY - start.y;
    if (Math.abs(xDistance) < SWIPE_DISTANCE_PX || Math.abs(xDistance) < Math.abs(yDistance) * SWIPE_DIRECTION_RATIO) return;

    const currentIndex = SWIPE_TABS.indexOf(route.tab as (typeof SWIPE_TABS)[number]);
    if (currentIndex < 0) return;
    const destinationIndex = xDistance < 0 ? currentIndex + 1 : currentIndex - 1;
    const destination = SWIPE_TABS[destinationIndex];
    if (!destination) return;
    setSwipeDirection(xDistance < 0 ? "forward" : "back");
    navigate(`#/${destination}`);
  }

  return (
    <div className="shell">
      <main className="content" onTouchStart={onTouchStart} onTouchEnd={onTouchEnd}>
        <div className={`tab-swipe-screen${swipeDirection ? ` tab-swipe-${swipeDirection}` : ""}`} key={`${route.tab}-${route.showId ?? "root"}-${route.notifications ? "n" : "t"}`}>
          {route.tab === "recent" && (route.notifications ? <NotificationsView /> : <RecentView />)}
          {route.tab === "played" && <PlayedView />}
          {route.tab === "shows" &&
            (route.showId != null ? <ShowDetailView showId={route.showId} /> : <ShowsView />)}
          {route.tab === "settings" && <SettingsSheet onClose={() => navigate("#/shows")} />}
          {FOLLOW_APPEARANCES_ENABLED && route.tab === "follows" && <FollowsView />}
        </div>
      </main>
      <MiniPlayer />
      <TabBar active={route.tab} />
      <PlayerSheet />
    </div>
  );
}
