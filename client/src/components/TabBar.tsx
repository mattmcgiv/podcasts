import { navigate, type Tab } from "../router";
import { FOLLOW_APPEARANCES_ENABLED } from "../config";

const TABS: { tab: Tab; label: string; hash: string; icon: string }[] = [
  { tab: "recent", label: "Listen", hash: "#/recent", icon: "M4 6h16M4 12h16M4 18h10" },
  { tab: "played", label: "Played", hash: "#/played", icon: "M5 12.5l4 4 10-11" },
  { tab: "shows", label: "Shows", hash: "#/shows", icon: "M5 4h14v16H5zM5 9h14" },
  ...(FOLLOW_APPEARANCES_ENABLED ? [{ tab: "follows" as const, label: "Follows", hash: "#/follows", icon: "M12 20V10M7 15l5 5 5-5M5 4h14" }] : []),
  { tab: "settings", label: "Settings", hash: "#/settings", icon: "M12 15.5a3.5 3.5 0 100-7 3.5 3.5 0 000 7zM19.4 15a1.7 1.7 0 00.3 1.9l.1.1-2 2-.1-.1a1.7 1.7 0 00-1.9-.3 1.7 1.7 0 00-1 1.5v.2H12v-.2a1.7 1.7 0 00-1-1.5 1.7 1.7 0 00-1.9.3l-.1.1-2-2 .1-.1a1.7 1.7 0 00.3-1.9 1.7 1.7 0 00-1.5-1H5.7v-2.8h.2a1.7 1.7 0 001.5-1 1.7 1.7 0 00-.3-1.9L7 8.2l2-2 .1.1a1.7 1.7 0 001.9.3 1.7 1.7 0 001-1.5v-.2h2.8v.2a1.7 1.7 0 001 1.5 1.7 1.7 0 001.9-.3l.1-.1 2 2-.1.1a1.7 1.7 0 00-.3 1.9 1.7 1.7 0 001.5 1h.2V14h-.2a1.7 1.7 0 00-1.5 1z" },
];

export function TabBar({ active }: { active: Tab }) {
  return (
    <nav className="tabbar">
      {TABS.map(({ tab, label, hash, icon }) => (
        <button
          key={tab}
          className={`tab${active === tab ? " active" : ""}`}
          aria-current={active === tab ? "page" : undefined}
          onClick={() => navigate(hash)}
        >
          <svg viewBox="0 0 24 24" width="22" height="22" aria-hidden>
            <path d={icon} fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
          <span>{label}</span>
        </button>
      ))}
    </nav>
  );
}
