import { describe, expect, it } from "vitest";
import { fmtDate, fmtDuration, fmtRemaining, fmtTime, onDeviceClassifierCopy, progressFraction } from "./lib";

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

describe("onDeviceClassifierCopy", () => {
  it("allows enable only when Apple Intelligence is available", () => {
    expect(onDeviceClassifierCopy({
      classifier_available: true,
      classifier_unavailable_reason: null,
    })).toEqual({
      status: "On-device classifier: Apple Intelligence is ready",
      recovery: null,
      canEnable: true,
      shouldPoll: false,
    });
  });

  it("explains each Apple unavailable reason and the recovery path", () => {
    expect(onDeviceClassifierCopy({
      classifier_available: false,
      classifier_unavailable_reason: "device_not_eligible",
    })).toMatchObject({
      canEnable: false,
      shouldPoll: false,
      status: "Apple Intelligence is not available on this iPhone.",
    });
    expect(onDeviceClassifierCopy({
      classifier_available: false,
      classifier_unavailable_reason: "apple_intelligence_not_enabled",
    })).toMatchObject({
      canEnable: false,
      shouldPoll: true,
      recovery: expect.stringContaining("Apple Intelligence & Siri"),
    });
    expect(onDeviceClassifierCopy({
      classifier_available: false,
      classifier_unavailable_reason: "model_not_ready",
    })).toMatchObject({
      canEnable: false,
      shouldPoll: true,
      status: "Apple Intelligence is still downloading.",
    });
  });
});
