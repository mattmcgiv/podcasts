import { describe, expect, it } from "vitest";
import { enrollTokenFromLocation, toBuffer, unwrapPublicKey } from "./passkey";

describe("enrollTokenFromLocation", () => {
  it("reads #enroll= tokens", () => {
    expect(enrollTokenFromLocation("#enroll=abc", "")).toBe("abc");
  });

  it("reads query tokens", () => {
    expect(enrollTokenFromLocation("", "?enroll=xyz")).toBe("xyz");
  });

  it("returns null when missing", () => {
    expect(enrollTokenFromLocation("#/recent", "")).toBeNull();
  });
});

describe("unwrapPublicKey", () => {
  it("unwraps the webauthn-rs publicKey wrapper", () => {
    const options = unwrapPublicKey({
      publicKey: { challenge: "abc", rp: { id: "pods.mcgiv.dev" } },
    });
    expect(options.challenge).toBe("abc");
    expect((options.rp as { id: string }).id).toBe("pods.mcgiv.dev");
  });

  it("unwraps a double-wrapped API body", () => {
    const options = unwrapPublicKey({
      publicKey: { publicKey: { challenge: "xyz" } },
    });
    expect(options.challenge).toBe("xyz");
  });
});

describe("toBuffer", () => {
  it("decodes a base64url challenge to an ArrayBuffer", () => {
    const buffer = toBuffer("YWI");
    expect(buffer).toBeInstanceOf(ArrayBuffer);
    expect(buffer.byteLength).toBe(2);
  });
});
