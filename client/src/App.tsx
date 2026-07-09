import { useEffect } from "react";
import { startAutoRefresh } from "./autoRefresh";
import { MiniPlayer } from "./components/MiniPlayer";
import { PlayerSheet } from "./components/PlayerSheet";
import { TabBar } from "./components/TabBar";
import { emitEpisodesChanged } from "./events";
import { PlayerProvider } from "./player";
import { refreshFeeds } from "./refreshFeeds";
import { useRoute } from "./router";
import { PlayedView } from "./views/PlayedView";
import { RecentView } from "./views/RecentView";
import { SearchView } from "./views/SearchView";
import { ShowDetailView } from "./views/ShowDetailView";
import { ShowsView } from "./views/ShowsView";

export function App() {
  return (
    <PlayerProvider>
      <Shell />
    </PlayerProvider>
  );
}

function Shell() {
  const route = useRoute();

  // Always-on while open/visible (product requirement; no opt-out).
  // Shell mounts once for the app lifetime — empty deps are intentional.
  // Cleanup stops the timer and unsubscribes visibilitychange.
  useEffect(() => {
    return startAutoRefresh({
      refresh: async () => {
        const result = await refreshFeeds();
        // Reload lists when at least one feed was refreshed.
        if (result.refreshed > 0) emitEpisodesChanged();
      },
      isVisible: () => !document.hidden,
      onVisibilityChange: (cb) => {
        document.addEventListener("visibilitychange", cb);
        return () => document.removeEventListener("visibilitychange", cb);
      },
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps -- mount-once lifecycle
  }, []);

  return (
    <div className="shell">
      <main className="content">
        {route.tab === "recent" && <RecentView />}
        {route.tab === "played" && <PlayedView />}
        {route.tab === "search" && <SearchView />}
        {route.tab === "shows" &&
          (route.showId != null ? <ShowDetailView showId={route.showId} /> : <ShowsView />)}
      </main>
      <MiniPlayer />
      <TabBar active={route.tab} />
      <PlayerSheet />
    </div>
  );
}
