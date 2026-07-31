import { useEffect } from "react";
import { MiniPlayer } from "./components/MiniPlayer";
import { PlayerSheet } from "./components/PlayerSheet";
import { TabBar } from "./components/TabBar";
import { PlayerProvider } from "./player";
import { postPodsLifecycleEvent } from "./podsLifecycle";
import { useRoute } from "./router";
import { PlayedView } from "./views/PlayedView";
import { RecentView } from "./views/RecentView";
import { SearchView } from "./views/SearchView";
import { ShowDetailView } from "./views/ShowDetailView";
import { ShowsView } from "./views/ShowsView";
import { FollowsView } from "./views/FollowsView";
import { FOLLOW_APPEARANCES_ENABLED } from "./config";
import { applyThemePreference, currentThemePreference } from "./theme";

export function App() {
  useEffect(() => {
    postPodsLifecycleEvent("ui-ready");
    applyThemePreference(currentThemePreference(), false);
  }, []);

  return (
    <PlayerProvider>
      <Shell />
    </PlayerProvider>
  );
}

function Shell() {
  const route = useRoute();

  return (
    <div className="shell">
      <main className="content">
        {route.tab === "recent" && <RecentView />}
        {route.tab === "played" && <PlayedView />}
        {route.tab === "search" && <SearchView />}
        {route.tab === "shows" &&
          (route.showId != null ? <ShowDetailView showId={route.showId} /> : <ShowsView />)}
        {FOLLOW_APPEARANCES_ENABLED && route.tab === "follows" && <FollowsView />}
      </main>
      <MiniPlayer />
      <TabBar active={route.tab} />
      <PlayerSheet />
    </div>
  );
}
