import { describe, expect, it } from "vitest";
import {
  LOCAL_OMLX_MODEL,
  adStageLabel,
  cloudClassifierCopy,
  fmtDate,
  fmtDuration,
  fmtRemaining,
  fmtTime,
  formatOptionalUSD,
  formatUSD,
  listenClassifierPause,
  localProcessingCopy,
  progressFraction,
} from "./lib";

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

describe("formatUSD", () => {
  it("uses cents for ordinary amounts and extra digits for fractions of a cent", () => {
    expect(formatUSD(0)).toBe("$0.00");
    expect(formatUSD(0.18)).toBe("$0.18");
    expect(formatUSD(0.002)).toBe("$0.0020");
    expect(formatUSD(0.000012)).toBe("$0.000012");
    expect(formatOptionalUSD(null)).toBe("—");
    expect(formatOptionalUSD(0.09)).toBe("$0.09");
  });
});

describe("cloudClassifierCopy", () => {
  it("allows enable when DeepSeek is configured", () => {
    expect(cloudClassifierCopy({
      classifier_available: true,
      classifier_unavailable_reason: null,
    })).toEqual({
      status: "Cloud classifier: DeepSeek V4 Pro ready",
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

describe("localProcessingCopy", () => {
  it("names the Mac oMLX model and says processing pauses without the Mac", () => {
    expect(localProcessingCopy()).toEqual({
      summary: `Ad classification and show notes run locally on the Mac through oMLX using ${LOCAL_OMLX_MODEL}.`,
      pause: "Processing pauses while the Mac is unavailable.",
    });
    expect(localProcessingCopy().summary).not.toMatch(/DeepSeek V4 Pro/);
    expect(localProcessingCopy().summary).not.toMatch(/sent to DeepSeek/);
  });
});

describe("listenClassifierPause", () => {
  const unavailable = {
    enabled: true,
    classifier_available: false,
    classifier_unavailable_reason: "api_key_required",
  };

  it("keeps the DeepSeek API key banner on the non-local path", () => {
    expect(listenClassifierPause(unavailable, false)).toMatchObject({
      status: "DeepSeek API key required.",
      recovery: expect.stringContaining("Save a DeepSeek API key"),
    });
  });

  it("does not ask for a DeepSeek API key on the local-browser path", () => {
    expect(listenClassifierPause(unavailable, true)).toBeNull();
  });

  it("hides the banner when ad removal is off or the classifier is available", () => {
    expect(listenClassifierPause(null, false)).toBeNull();
    expect(listenClassifierPause({ ...unavailable, enabled: false }, false)).toBeNull();
    expect(listenClassifierPause({ ...unavailable, classifier_available: true }, false)).toBeNull();
  });
});

describe("adStageLabel", () => {
  it("waits for a DeepSeek API key only on the non-local path", () => {
    expect(adStageLabel("preparing", "transcribing", "model_required", false)).toBe(
      "Waiting for DeepSeek API key",
    );
    expect(adStageLabel("preparing", "transcribing", "model_required", true)).toBe(
      "Paused · Mac unavailable",
    );
    expect(adStageLabel("preparing", "transcribing", "model_required", true)).not.toMatch(/API key/i);
  });
});
