import { describe, expect, it } from "vitest";
import { checkSummary, FLOOR, isCodeFile } from "./check-coverage.mjs";

function metrics(lines, statements, functions, branches = 100) {
  return {
    lines: { total: 100, covered: lines, pct: lines },
    statements: { total: 100, covered: statements, pct: statements },
    functions: { total: 10, covered: Math.round(functions / 10), pct: functions },
    branches: { total: 10, covered: Math.round(branches / 10), pct: branches },
  };
}

describe("isCodeFile", () => {
  it("accepts js/ts sources and skips assets", () => {
    expect(isCodeFile("/work/client/src/a.ts")).toBe(true);
    expect(isCodeFile("/work/client/src/b.tsx")).toBe(true);
    expect(isCodeFile("/work/client/src/c.mjs")).toBe(true);
    expect(isCodeFile("/work/client/src/styles.css")).toBe(false);
    expect(isCodeFile("/work/client/src/icon.svg")).toBe(false);
  });
});

describe("checkSummary", () => {
  it("passes files at or above the floor", () => {
    const summary = {
      total: metrics(100, 100, 100),
      "/work/client/src/a.ts": metrics(90, 95, 100),
    };
    expect(checkSummary(summary)).toEqual({ checked: 1, failures: [] });
  });

  it("flags any gated metric below the floor, worst first", () => {
    const summary = {
      total: metrics(95, 95, 95),
      "/work/client/src/ok.ts": metrics(100, 100, 100),
      "/work/client/src/low-lines.ts": metrics(80, 100, 100),
      "/work/client/src/low-funcs.ts": metrics(100, 100, 85),
    };
    const { checked, failures } = checkSummary(summary);
    expect(checked).toBe(3);
    expect(failures.map((failure) => failure.file)).toEqual([
      "/work/client/src/low-lines.ts",
      "/work/client/src/low-funcs.ts",
    ]);
  });

  it("ignores the total row, non-code files, and branches", () => {
    const summary = {
      total: metrics(10, 10, 10),
      "/work/client/src/styles.css": metrics(0, 0, 0, 0),
      "/work/client/src/a.ts": metrics(100, 100, 100, 0),
    };
    expect(checkSummary(summary)).toEqual({ checked: 1, failures: [] });
  });

  it("treats empty metrics as passing", () => {
    const summary = {
      total: metrics(100, 100, 100),
      "/work/client/src/empty.ts": {
        lines: { total: 0, covered: 0, pct: 100 },
        statements: { total: 0, covered: 0, pct: 100 },
        functions: { total: 0, covered: 0, pct: 0 },
      },
    };
    expect(checkSummary(summary)).toEqual({ checked: 1, failures: [] });
  });

  it("defaults to the 90% floor", () => {
    expect(FLOOR).toBe(90);
  });
});
