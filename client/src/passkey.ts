function b64urlToBuf(value: string): ArrayBuffer {
  const pad = "=".repeat((4 - (value.length % 4)) % 4);
  const b64 = (value + pad).replace(/-/g, "+").replace(/_/g, "/");
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
}

function bufToB64url(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function cloneRecord(value: unknown): Record<string, unknown> {
  if (value == null || typeof value !== "object") return {};
  return JSON.parse(JSON.stringify(value)) as Record<string, unknown>;
}

/** webauthn-rs wraps options as `{ publicKey: { challenge, ... } }`. */
export function unwrapPublicKey(value: unknown): Record<string, unknown> {
  let current: unknown = value;
  for (let depth = 0; depth < 4; depth += 1) {
    if (current == null || typeof current !== "object") return {};
    const record = current as Record<string, unknown>;
    if (record.challenge != null) return cloneRecord(record);
    if (record.publicKey != null) {
      current = record.publicKey;
      continue;
    }
    return cloneRecord(record);
  }
  return {};
}

export function toBuffer(value: unknown): ArrayBuffer {
  if (value instanceof ArrayBuffer) return value;
  if (ArrayBuffer.isView(value)) {
    const view = value;
    return Uint8Array.from(new Uint8Array(view.buffer, view.byteOffset, view.byteLength)).buffer;
  }
  if (typeof value === "string") return b64urlToBuf(value);
  if (Array.isArray(value) && value.every((item) => typeof item === "number")) {
    return Uint8Array.from(value).buffer;
  }
  throw new Error("passkey challenge is missing");
}

function decodeIdList(list: unknown): Array<Record<string, unknown>> | undefined {
  if (!Array.isArray(list)) return undefined;
  return list.map((item) => {
    const record = cloneRecord(item);
    if (record.id != null) record.id = toBuffer(record.id);
    return record;
  });
}

export function enrollTokenFromLocation(hash = window.location.hash, search = window.location.search): string | null {
  const raw = hash.replace(/^#/, "");
  if (raw.startsWith("enroll=")) {
    return decodeURIComponent(raw.slice("enroll=".length).split("&")[0] ?? "") || null;
  }
  const query = new URLSearchParams(search).get("enroll");
  return query && query.length > 0 ? query : null;
}

export async function createPasskey(publicKey: unknown): Promise<unknown> {
  const options = unwrapPublicKey(publicKey);
  options.challenge = toBuffer(options.challenge);
  const user = options.user as Record<string, unknown> | undefined;
  if (user && user.id != null) user.id = toBuffer(user.id);
  const exclude = decodeIdList(options.excludeCredentials);
  if (exclude) options.excludeCredentials = exclude;
  const credential = (await navigator.credentials.create({
    publicKey: options as unknown as PublicKeyCredentialCreationOptions,
  })) as PublicKeyCredential | null;
  if (!credential) throw new Error("passkey was not created");
  const response = credential.response as AuthenticatorAttestationResponse;
  return {
    id: credential.id,
    rawId: bufToB64url(credential.rawId),
    type: credential.type,
    response: {
      clientDataJSON: bufToB64url(response.clientDataJSON),
      attestationObject: bufToB64url(response.attestationObject),
    },
  };
}

export async function assertPasskey(publicKey: unknown): Promise<unknown> {
  const options = unwrapPublicKey(publicKey);
  options.challenge = toBuffer(options.challenge);
  const allow = decodeIdList(options.allowCredentials);
  if (allow) options.allowCredentials = allow;
  const credential = (await navigator.credentials.get({
    publicKey: options as unknown as PublicKeyCredentialRequestOptions,
  })) as PublicKeyCredential | null;
  if (!credential) throw new Error("passkey was not asserted");
  const response = credential.response as AuthenticatorAssertionResponse;
  return {
    id: credential.id,
    rawId: bufToB64url(credential.rawId),
    type: credential.type,
    response: {
      clientDataJSON: bufToB64url(response.clientDataJSON),
      authenticatorData: bufToB64url(response.authenticatorData),
      signature: bufToB64url(response.signature),
      userHandle: response.userHandle ? bufToB64url(response.userHandle) : null,
    },
  };
}
