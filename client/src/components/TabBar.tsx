import { navigate, type Tab } from "../router";

const TABS: { tab: Tab; label: string; hash: string; icon: string }[] = [
  { tab: "recent", label: "Listen", hash: "#/recent", icon: "M4 6h16M4 12h16M4 18h10" },
  { tab: "played", label: "Played", hash: "#/played", icon: "M5 12.5l4 4 10-11" },
  { tab: "search", label: "Search", hash: "#/search", icon: "M10.5 17a6.5 6.5 0 110-13 6.5 6.5 0 010 13zM15.5 15.5L21 21" },
  { tab: "shows", label: "Shows", hash: "#/shows", icon: "M5 4h14v16H5zM5 9h14" },
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
