// Per-file coverage floor for the client merge gate.
//
// Vitest's own thresholds are global-only, so a file like passkey.ts can sit
// at 40% while the total clears 90%. This checker reads the json-summary
// report that `vitest run --coverage` writes and fails when any code file
// falls below FLOOR on lines, statements, or functions (the same three
// metrics the global gate enforces). Branch coverage is shown for context
// but not gated, matching the global gate.
//
// Usage: node ./scripts/check-coverage.mjs [coverage-dir]
// Exit codes: 0 pass, 1 below floor, 2 usage/report error.
import { readFileSync } from "node:fs";
import { basename, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const FLOOR = 90;

const CODE_FILE = /\.[cm]?[jt]sx?$/;

export function isCodeFile(path) {
  return CODE_FILE.test(path);
}

function metricOk(metric, floor) {
  if (metric.total === 0) return true;
  return metric.pct >= floor;
}

/**
 * @param {Record<string, any>} summary parsed coverage-summary.json
 * @param {number} floor minimum pct per metric
 * @returns {{ checked: number, failures: Array<{ file: string, lines: number, statements: number, functions: number, branches: number | null }> }}
 */
export function checkSummary(summary, floor = FLOOR) {
  const failures = [];
  let checked = 0;
  for (const [file, metrics] of Object.entries(summary)) {
    if (file === "total") continue;
    if (!isCodeFile(file)) continue;
    checked += 1;
    const lines = metrics.lines ?? { total: 0, pct: 100 };
    const statements = metrics.statements ?? { total: 0, pct: 100 };
    const functions = metrics.functions ?? { total: 0, pct: 100 };
    if (metricOk(lines, floor) && metricOk(statements, floor) && metricOk(functions, floor)) {
      continue;
    }
    failures.push({
      file,
      lines: lines.pct,
      statements: statements.pct,
      functions: functions.pct,
      branches: metrics.branches ? metrics.branches.pct : null,
    });
  }
  failures.sort((a, b) => Math.min(a.lines, a.statements, a.functions) - Math.min(b.lines, b.statements, b.functions));
  return { checked, failures };
}

function shortPath(file, coverageDir) {
  const marker = "/client/";
  const index = file.lastIndexOf(marker);
  if (index !== -1) return file.slice(index + marker.length);
  if (file.startsWith(coverageDir)) return file.slice(coverageDir.length).replace(/^\/+/, "");
  return basename(file);
}

function main() {
  const coverageDir = resolve(process.argv[2] ?? "coverage");
  const summaryPath = resolve(coverageDir, "coverage-summary.json");
  let summary;
  try {
    summary = JSON.parse(readFileSync(summaryPath, "utf8"));
  } catch (error) {
    console.error(`check-coverage: cannot read ${summaryPath}: ${error.message}`);
    console.error("Run `vitest run --coverage` first (json-summary reporter).");
    process.exitCode = 2;
    return;
  }
  const { checked, failures } = checkSummary(summary);
  if (failures.length === 0) {
    console.log(`check-coverage: ${checked} files at or above the ${FLOOR}% floor.`);
    return;
  }
  console.error(`check-coverage: ${failures.length} of ${checked} files below the ${FLOOR}% floor (lines/statements/functions):`);
  for (const failure of failures) {
    const branches = failure.branches === null ? "n/a" : failure.branches.toFixed(2);
    console.error(
      `  ${shortPath(failure.file, coverageDir)} lines=${failure.lines.toFixed(2)} ` +
        `statements=${failure.statements.toFixed(2)} functions=${failure.functions.toFixed(2)} branches=${branches}`,
    );
  }
  process.exitCode = 1;
}

const invokedAsScript =
  process.argv[1] !== undefined && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedAsScript) {
  main();
}
