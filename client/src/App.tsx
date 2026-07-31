import { useEffect } from "react";
import { MiniPlayer } from "./components/MiniPlayer";
import { PlayerSheet } from "./components/PlayerSheet";
import { TabBar } from "./components/TabBar";
import { PlayerProvider } from "./player";
import { postPodsLifecycleEvent } from "./podsLifecycle";
import { navigate, useRoute } from "./router";
import { PlayedView } from "./views/PlayedView";
import { RecentView } from "./views/RecentView";
import { ShowDetailView } from "./views/ShowDetailView";
import { ShowsView } from "./views/ShowsView";
import { FollowsView } from "./views/FollowsView";
import { FOLLOW_APPEARANCES_ENABLED } from "./config";
import { applyThemePreference, currentThemePreference } from "./theme";
import { SettingsSheet } from "./views/SettingsSheet";

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
        {route.tab === "shows" &&
          (route.showId != null ? <ShowDetailView showId={route.showId} /> : <ShowsView />)}
        {route.tab === "settings" && <SettingsSheet onClose={() => navigate("#/shows")} />}
        {FOLLOW_APPEARANCES_ENABLED && route.tab === "follows" && <FollowsView />}
      </main>
      <MiniPlayer />
      <TabBar active={route.tab} />
      <PlayerSheet />
    </div>
  );
}
