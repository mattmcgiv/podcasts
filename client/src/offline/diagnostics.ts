import * as store from "./store";

export interface DiagnosticEntry {
  at: number;
  kind: string;
  detail: string;
}

/** Page-side ring in localStorage. The service worker cannot use localStorage,
 * so worker-side media events use the IndexedDB ring below. */
const PAGE_KEY = "pods-diagnostics-v1";
export const PAGE_DIAGNOSTIC_CAP = 200;

const MEDIA_KEY = "diagnostics:media";
export const MEDIA_DIAGNOSTIC_CAP = 100;

function isEntry(value: unknown): value is DiagnosticEntry {
  if (value == null || typeof value !== "object") return false;
  const entry = value as Record<string, unknown>;
  return typeof entry.at === "number" && typeof entry.kind === "string" && typeof entry.detail === "string";
}

export function logDiagnostic(kind: string, detail: string): void {
  try {
    const entries = readDiagnostics();
    entries.push({ at: Date.now(), kind, detail });
    window.localStorage.setItem(PAGE_KEY, JSON.stringify(entries.slice(-PAGE_DIAGNOSTIC_CAP)));
  } catch {
    // Diagnostics must never break the app.
  }
}

export function readDiagnostics(): DiagnosticEntry[] {
  try {
    const raw = window.localStorage.getItem(PAGE_KEY);
    if (!raw) return [];
    const parsed: unknown = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed.filter(isEntry) : [];
  } catch {
    return [];
  }
}

export function clearDiagnostics(): void {
  try {
    window.localStorage.removeItem(PAGE_KEY);
  } catch {
    // Diagnostics must never break the app.
  }
}

export async function logMediaDiagnostic(entry: DiagnosticEntry): Promise<void> {
  try {
    const entries = await readMediaDiagnostics();
    entries.push(entry);
    await store.writeRecord("meta", MEDIA_KEY, entries.slice(-MEDIA_DIAGNOSTIC_CAP));
  } catch {
    // Diagnostics must never break media serving.
  }
}

export async function readMediaDiagnostics(): Promise<DiagnosticEntry[]> {
  try {
    const entries = await store.readRecord<unknown>("meta", MEDIA_KEY);
    return Array.isArray(entries) ? entries.filter(isEntry) : [];
  } catch {
    return [];
  }
}

export async function clearMediaDiagnostics(): Promise<void> {
  try {
    await store.writeRecord("meta", MEDIA_KEY, []);
  } catch {
    // Diagnostics must never break the app.
  }
}

export function formatDiagnostics(page: DiagnosticEntry[], media: DiagnosticEntry[]): string {
  const lines = [`# Pods diagnostics ${new Date().toISOString()}`, `agent: ${navigator.userAgent}`];
  const section = (title: string, entries: DiagnosticEntry[]) => {
    lines.push(`## ${title} (${entries.length})`);
    if (entries.length === 0) lines.push("(none)");
    for (const entry of entries) lines.push(`${new Date(entry.at).toISOString()} [${entry.kind}] ${entry.detail}`);
  };
  section("page", page);
  section("media", media);
  return lines.join("\n");
}
