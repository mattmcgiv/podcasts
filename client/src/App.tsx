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

export function App() {
  useEffect(() => {
    postPodsLifecycleEvent("ui-ready");
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
      </main>
      <MiniPlayer />
      <TabBar active={route.tab} />
      <PlayerSheet />
    </div>
  );
}
