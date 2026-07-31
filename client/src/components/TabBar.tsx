import { navigate, type Tab } from "../router";
import { FOLLOW_APPEARANCES_ENABLED } from "../config";

const TABS: { tab: Tab; label: string; hash: string }[] = [
  { tab: "recent", label: "Listen", hash: "#/recent" },
  { tab: "played", label: "Played", hash: "#/played" },
  { tab: "shows", label: "Shows", hash: "#/shows" },
  ...(FOLLOW_APPEARANCES_ENABLED ? [{ tab: "follows" as const, label: "Follows", hash: "#/follows" }] : []),
  { tab: "settings", label: "Settings", hash: "#/settings" },
];

export function TabBar({ active }: { active: Tab }) {
  return (
    <nav className="tabbar">
      {TABS.map(({ tab, label, hash }) => (
        <button
          key={tab}
          className={`tab${active === tab ? " active" : ""}`}
          aria-current={active === tab ? "page" : undefined}
          onClick={() => navigate(hash)}
        >
          <span>{label}</span>
        </button>
      ))}
    </nav>
  );
}
