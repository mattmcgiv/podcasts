export type ThemePreference = "system" | "light" | "dark";

export const THEME_PREFERENCE_KEY = "pods-theme-preference";

export function currentThemePreference(): ThemePreference {
  const value = window.localStorage.getItem(THEME_PREFERENCE_KEY);
  return value === "light" || value === "dark" || value === "system" ? value : "system";
}

export function applyThemePreference(preference: ThemePreference, persist = true): void {
  document.documentElement.dataset.theme = preference;
  document.documentElement.style.colorScheme = preference === "system" ? "light dark" : preference;
  if (persist) window.localStorage.setItem(THEME_PREFERENCE_KEY, preference);
}
