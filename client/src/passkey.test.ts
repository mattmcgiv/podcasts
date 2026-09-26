import { describe, expect, it, vi } from "vitest";
import { assertPasskey, createPasskey, enrollTokenFromLocation, toBuffer, unwrapPublicKey } from "./passkey";

function bytes(...values: number[]): ArrayBuffer {
  return Uint8Array.from(values).buffer as ArrayBuffer;
}

function mockCredentials(create?: unknown, get?: unknown) {
  Object.defineProperty(navigator, "credentials", {
    configurable: true,
    value: { create: vi.fn().mockResolvedValue(create), get: vi.fn().mockResolvedValue(get) },
  });
}

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

  it("bails out on junk instead of throwing", () => {
    expect(unwrapPublicKey(null)).toEqual({});
    expect(unwrapPublicKey("nope")).toEqual({});
    expect(unwrapPublicKey({ rp: { id: "x" } })).toEqual({ rp: { id: "x" } });
    expect(unwrapPublicKey({ publicKey: { publicKey: { publicKey: { publicKey: { challenge: "deep" } } } } })).toEqual({});
  });
});

describe("toBuffer", () => {
  it("decodes a base64url challenge to an ArrayBuffer", () => {
    const buffer = toBuffer("YWI");
    expect(buffer).toBeInstanceOf(ArrayBuffer);
    expect(buffer.byteLength).toBe(2);
  });

  it("accepts buffers, views, and byte arrays as-is", () => {
    const backing = bytes(1, 2, 3, 4);
    expect(toBuffer(backing)).toBe(backing);
    const sliced = new Uint8Array(backing, 1, 2);
    expect([...new Uint8Array(toBuffer(sliced))]).toEqual([2, 3]);
    expect([...new Uint8Array(toBuffer([104, 105]))]).toEqual([104, 105]);
  });

  it("rejects values that cannot be a challenge", () => {
    expect(() => toBuffer({})).toThrow("passkey challenge is missing");
    expect(() => toBuffer(["x"])).toThrow("passkey challenge is missing");
  });
});

describe("createPasskey", () => {
  it("builds creation options and encodes the new credential", async () => {
    mockCredentials({
      id: "cred-1", rawId: bytes(251, 255), type: "public-key",
      response: { clientDataJSON: bytes(1), attestationObject: bytes(2, 3) },
    });
    const credential = await createPasskey({ publicKey: {
      challenge: "YWI", user: { id: "YWI", name: "matt" },
      excludeCredentials: [{ id: "YWI", type: "public-key" }, "junk"],
    } }) as { id: string; rawId: string; type: string; response: Record<string, string> };
    expect(navigator.credentials.create).toHaveBeenCalledWith({ publicKey: expect.objectContaining({
      challenge: expect.any(ArrayBuffer),
      user: expect.objectContaining({ id: expect.any(ArrayBuffer) }),
      excludeCredentials: [expect.objectContaining({ id: expect.any(ArrayBuffer) }), {}],
    }) });
    expect(credential).toEqual({
      id: "cred-1", rawId: "-_8", type: "public-key",
      response: { clientDataJSON: "AQ", attestationObject: "AgM" },
    });
  });

  it("throws when the browser backs out of creation", async () => {
    mockCredentials(null);
    await expect(createPasskey({ challenge: "YWI" })).rejects.toThrow("not created");
  });
});

describe("assertPasskey", () => {
  it("builds request options and encodes the assertion", async () => {
    mockCredentials(undefined, {
      id: "cred-1", rawId: bytes(251), type: "public-key",
      response: { clientDataJSON: bytes(1), authenticatorData: bytes(2), signature: bytes(3), userHandle: bytes(4) },
    });
    const credential = await assertPasskey({
      challenge: "YWI", allowCredentials: [{ id: "YWI", type: "public-key" }],
    }) as { response: Record<string, string | null> };
    expect(navigator.credentials.get).toHaveBeenCalledWith({ publicKey: expect.objectContaining({
      challenge: expect.any(ArrayBuffer),
      allowCredentials: [expect.objectContaining({ id: expect.any(ArrayBuffer) })],
    }) });
    expect(credential.response).toEqual({
      clientDataJSON: "AQ", authenticatorData: "Ag", signature: "Aw", userHandle: "BA",
    });
  });

  it("sends a null user handle and throws when the browser backs out", async () => {
    mockCredentials(undefined, {
      id: "cred-1", rawId: bytes(1), type: "public-key",
      response: { clientDataJSON: bytes(1), authenticatorData: bytes(2), signature: bytes(3), userHandle: null },
    });
    const credential = await assertPasskey({ challenge: "YWI" }) as { response: Record<string, string | null> };
    expect(credential.response.userHandle).toBeNull();
    mockCredentials(undefined, null);
    await expect(assertPasskey({ challenge: "YWI" })).rejects.toThrow("not asserted");
  });
});
