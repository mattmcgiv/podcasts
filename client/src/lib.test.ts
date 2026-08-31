import { describe, expect, it } from "vitest";
import { cloudClassifierCopy, fmtDate, fmtDuration, fmtRemaining, fmtTime, progressFraction } from "./lib";

describe("fmtTime", () => {
  it("formats minutes and hours", () => {
    expect(fmtTime(0)).toBe("0:00");
    expect(fmtTime(65)).toBe("1:05");
    expect(fmtTime(3725)).toBe("1:02:05");
    expect(fmtTime(-5)).toBe("0:00");
  });
});

describe("fmtDuration", () => {
  it("rounds to friendly units", () => {
    expect(fmtDuration(null)).toBe("");
    expect(fmtDuration(0)).toBe("");
    expect(fmtDuration(29)).toBe("<1m");
    expect(fmtDuration(1500)).toBe("25m");
    expect(fmtDuration(3725)).toBe("1h 2m");
  });
});

describe("fmtDate", () => {
  const now = new Date(2026, 5, 10, 12, 0, 0); // Jun 10 2026 local
  const unix = (d: Date) => Math.floor(d.getTime() / 1000);

  it("uses relative names for the last two days", () => {
    expect(fmtDate(unix(new Date(2026, 5, 10, 8)), now)).toBe("Today");
    expect(fmtDate(unix(new Date(2026, 5, 9, 23)), now)).toBe("Yesterday");
  });

  it("falls back to short dates", () => {
    expect(fmtDate(unix(new Date(2026, 0, 5)), now)).toMatch(/Jan 5/);
    expect(fmtDate(unix(new Date(2024, 0, 5)), now)).toMatch(/Jan 5, 2024/);
    expect(fmtDate(0, now)).toBe("");
  });
});

describe("fmtRemaining / progressFraction", () => {
  it("shows total duration when unstarted", () => {
    expect(fmtRemaining({ duration_secs: 1800, position_secs: 0 })).toBe("30m");
    expect(progressFraction({ duration_secs: 1800, position_secs: 0 })).toBe(0);
  });

  it("shows time left when in progress", () => {
    expect(fmtRemaining({ duration_secs: 1800, position_secs: 900 })).toBe("15m left");
    expect(progressFraction({ duration_secs: 1800, position_secs: 900 })).toBe(0.5);
    expect(progressFraction({ duration_secs: 1800, position_secs: 9999 })).toBe(1);
    expect(progressFraction({ duration_secs: null, position_secs: 10 })).toBe(0);
  });
});

describe("cloudClassifierCopy", () => {
  it("allows enable when DeepSeek is configured", () => {
    expect(cloudClassifierCopy({
      classifier_available: true,
      classifier_unavailable_reason: null,
    })).toEqual({
      status: "Cloud classifier: DeepSeek V4 Flash ready",
      recovery: null,
      canEnable: true,
      shouldPoll: false,
    });
  });

  it("asks for an API key without polling", () => {
    expect(cloudClassifierCopy({
      classifier_available: false,
      classifier_unavailable_reason: "api_key_required",
    })).toMatchObject({
      canEnable: false,
      shouldPoll: false,
      status: "DeepSeek API key required.",
      recovery: expect.stringContaining("Save a DeepSeek API key"),
    });
  });
});
