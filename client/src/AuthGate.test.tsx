import { fireEvent, render, screen } from "@testing-library/react";
import { IDBFactory } from "fake-indexeddb";
import { afterEach, describe, expect, it, vi } from "vitest";
import { AuthGate } from "./AuthGate";
import { updateState } from "./offline/store";
import { HttpError, installApi } from "./test/mockApi";

afterEach(() => {
  window.location.hash = "";
  delete window.PODS_LOCAL_CLIENT;
});

function mockCredentials(create?: unknown, get?: unknown) {
  Object.defineProperty(navigator, "credentials", {
    configurable: true,
    value: { create: vi.fn().mockResolvedValue(create), get: vi.fn().mockResolvedValue(get) },
  });
}

function attestedCredential() {
  return {
    id: "cred-1", rawId: Uint8Array.from([1]).buffer, type: "public-key",
    response: { clientDataJSON: Uint8Array.from([1]).buffer, attestationObject: Uint8Array.from([2]).buffer },
  };
}

function assertedCredential() {
  return {
    id: "cred-1", rawId: Uint8Array.from([1]).buffer, type: "public-key",
    response: {
      clientDataJSON: Uint8Array.from([1]).buffer, authenticatorData: Uint8Array.from([2]).buffer,
      signature: Uint8Array.from([3]).buffer, userHandle: null,
    },
  };
}

describe("AuthGate", () => {
  it("renders children when a session is already valid", async () => {
    installApi({ "GET /api/auth/status": { enrolled: true, session: true } });
    render(
      <AuthGate>
        <p>Library</p>
      </AuthGate>,
    );
    expect(await screen.findByText("Library")).toBeInTheDocument();
  });

  it("shows not set up when no passkey exists", async () => {
    installApi({ "GET /api/auth/status": { enrolled: false, session: false } });
    render(
      <AuthGate>
        <p>Library</p>
      </AuthGate>,
    );
    expect(await screen.findByText(/Not set up/)).toBeInTheDocument();
    expect(screen.queryByText("Library")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Create passkey" })).not.toBeInTheDocument();
  });

  it("offers passkey sign-in when enrolled", async () => {
    installApi({ "GET /api/auth/status": { enrolled: true, session: false } });
    render(
      <AuthGate>
        <p>Library</p>
      </AuthGate>,
    );
    expect(await screen.findByRole("button", { name: "Continue with passkey" })).toBeInTheDocument();
  });

  it("offers enroll when the hash has a token", async () => {
    window.location.hash = "enroll=token-1";
    installApi({ "GET /api/auth/status": { enrolled: false, session: false } });
    render(
      <AuthGate>
        <p>Library</p>
      </AuthGate>,
    );
    expect(await screen.findByRole("button", { name: "Create passkey" })).toBeInTheDocument();
  });

  it("treats a 401 on auth status as unset", async () => {
    installApi({ "GET /api/auth/status": new HttpError(401, { error: "sign in required" }) });
    render(
      <AuthGate>
        <p>Library</p>
      </AuthGate>,
    );
    expect(await screen.findByText(/Not set up/)).toBeInTheDocument();
  });

  it("opens the cached library without contacting the Mac", async () => {
    window.PODS_LOCAL_CLIENT = true;
    vi.stubGlobal("indexedDB", new IDBFactory());
    await updateState(s => {
      s.snapshot = { version: 1, cursor: 0, replace: true, episodes: [], shows: [], settings: {}, versions: {} };
    });
    render(
      <AuthGate>
        <p>Library</p>
      </AuthGate>,
    );
    expect(await screen.findByText("Library")).toBeInTheDocument();
    expect(vi.mocked(fetch)).not.toHaveBeenCalled();
  });

  it("stays on reconnect when the Mac is down and there is no cached library", async () => {
    window.PODS_LOCAL_CLIENT = true;
    vi.stubGlobal("indexedDB", new IDBFactory());
    vi.stubGlobal("fetch", vi.fn(() => Promise.reject(new TypeError("Failed to fetch"))));
    render(
      <AuthGate>
        <p>Library</p>
      </AuthGate>,
    );
    expect(await screen.findByText(/Tailscale/)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Reconnect" })).toBeInTheDocument();
    expect(screen.queryByText("Library")).not.toBeInTheDocument();
  });

  it("times out a hanging Mac instead of spinning forever", async () => {
    window.PODS_LOCAL_CLIENT = true;
    vi.stubGlobal("indexedDB", new IDBFactory());
    vi.stubGlobal("fetch", vi.fn(() => new Promise(() => {})));
    render(
      <AuthGate>
        <p>Library</p>
      </AuthGate>,
    );
    expect(await screen.findByText(/Tailscale/, {}, { timeout: 10000 })).toBeInTheDocument();
    expect(screen.queryByText("Library")).not.toBeInTheDocument();
  }, 15000);

  it("answers from the Mac when there is no cached library", async () => {
    window.PODS_LOCAL_CLIENT = true;
    vi.stubGlobal("indexedDB", new IDBFactory());
    installApi({ "GET /api/auth/status": { enrolled: true, session: true } });
    const authenticated: string[] = [];
    window.addEventListener("pods-authenticated", () => authenticated.push("yes"));
    render(
      <AuthGate>
        <p>Library</p>
      </AuthGate>,
    );
    expect(await screen.findByText("Library")).toBeInTheDocument();
    expect(authenticated).toEqual(["yes"]);
  });

  it("falls back to unset when local storage itself is broken", async () => {
    window.PODS_LOCAL_CLIENT = true;
    vi.stubGlobal("indexedDB", undefined);
    installApi({});
    render(
      <AuthGate>
        <p>Library</p>
      </AuthGate>,
    );
    expect(await screen.findByText(/Tailscale/)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Reconnect" })).toBeInTheDocument();
    vi.stubGlobal("indexedDB", new IDBFactory());
  });

  it("retries the Mac from the reconnect button", async () => {
    window.PODS_LOCAL_CLIENT = true;
    vi.stubGlobal("indexedDB", new IDBFactory());
    vi.stubGlobal("fetch", vi.fn(() => Promise.reject(new TypeError("Failed to fetch"))));
    render(
      <AuthGate>
        <p>Library</p>
      </AuthGate>,
    );
    await screen.findByRole("button", { name: "Reconnect" });
    const calls = vi.mocked(fetch).mock.calls.length;
    fireEvent.click(screen.getByRole("button", { name: "Reconnect" }));
    await vi.waitFor(() => expect(vi.mocked(fetch).mock.calls.length).toBeGreaterThan(calls));
    expect(screen.queryByText("Library")).not.toBeInTheDocument();
  });

  it("sends the library back to passkey sign-in when the server session dies", async () => {
    installApi({ "GET /api/auth/status": { enrolled: true, session: true } });
    render(
      <AuthGate>
        <p>Library</p>
      </AuthGate>,
    );
    await screen.findByText("Library");
    window.dispatchEvent(new Event("pods-auth-required"));
    expect(await screen.findByRole("button", { name: "Continue with passkey" })).toBeInTheDocument();
    expect(screen.queryByText("Library")).not.toBeInTheDocument();
  });

  it("keeps local playback usable when reauthentication is required", async () => {
    window.PODS_LOCAL_CLIENT = true;
    vi.stubGlobal("indexedDB", new IDBFactory());
    installApi({ "GET /api/auth/status": { enrolled: true, session: true } });
    render(
      <AuthGate>
        <p>Library</p>
      </AuthGate>,
    );
    await screen.findByText("Library");
    window.dispatchEvent(new Event("pods-auth-required"));
    await new Promise(resolve => setTimeout(resolve, 50));
    expect(screen.getByText("Library")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Continue with passkey" })).not.toBeInTheDocument();
  });

  it("enrolls a passkey from an enrollment link", async () => {
    window.location.hash = "enroll=token-1";
    let statusCalls = 0;
    installApi({
      "GET /api/auth/status": () => (++statusCalls === 1 ? { enrolled: false, session: false } : { enrolled: true, session: true }),
      "POST /api/auth/register/options": { state_id: "reg-1", publicKey: { challenge: "YWI" } },
      "POST /api/auth/register": { enrolled: true, session: true },
    });
    mockCredentials(attestedCredential());
    render(
      <AuthGate>
        <p>Library</p>
      </AuthGate>,
    );
    fireEvent.click(await screen.findByRole("button", { name: "Create passkey" }));
    expect(await screen.findByText("Library")).toBeInTheDocument();
  });

  it("shows the enroll failure instead of swallowing it", async () => {
    window.location.hash = "enroll=token-1";
    installApi({
      "GET /api/auth/status": { enrolled: false, session: false },
      "POST /api/auth/register/options": { state_id: "reg-1", publicKey: { challenge: "YWI" } },
    });
    Object.defineProperty(navigator, "credentials", {
      configurable: true,
      value: { create: vi.fn().mockRejectedValue(new Error("1Password is locked")) },
    });
    render(
      <AuthGate>
        <p>Library</p>
      </AuthGate>,
    );
    fireEvent.click(await screen.findByRole("button", { name: "Create passkey" }));
    expect(await screen.findByText("1Password is locked")).toBeInTheDocument();
    expect(screen.queryByText("Library")).not.toBeInTheDocument();
  });

  it("signs in with an existing passkey", async () => {
    installApi({
      "GET /api/auth/status": { enrolled: true, session: false },
      "POST /api/auth/login/options": { state_id: "login-1", publicKey: { challenge: "YWI" } },
      "POST /api/auth/login": { enrolled: true, session: true },
    });
    mockCredentials(undefined, assertedCredential());
    render(
      <AuthGate>
        <p>Library</p>
      </AuthGate>,
    );
    fireEvent.click(await screen.findByRole("button", { name: "Continue with passkey" }));
    expect(await screen.findByText("Library")).toBeInTheDocument();
  });

  it("shows the sign-in failure instead of swallowing it", async () => {
    installApi({
      "GET /api/auth/status": { enrolled: true, session: false },
      "POST /api/auth/login/options": { state_id: "login-1", publicKey: { challenge: "YWI" } },
    });
    Object.defineProperty(navigator, "credentials", {
      configurable: true,
      value: { get: vi.fn().mockRejectedValue(new Error("No passkey for this site")) },
    });
    render(
      <AuthGate>
        <p>Library</p>
      </AuthGate>,
    );
    fireEvent.click(await screen.findByRole("button", { name: "Continue with passkey" }));
    expect(await screen.findByText("No passkey for this site")).toBeInTheDocument();
    expect(screen.queryByText("Library")).not.toBeInTheDocument();
  });

  it("refreshes the gate when the hash gains an enrollment link", async () => {
    installApi({ "GET /api/auth/status": { enrolled: false, session: false } });
    render(
      <AuthGate>
        <p>Library</p>
      </AuthGate>,
    );
    expect(await screen.findByText(/Not set up/)).toBeInTheDocument();
    window.location.hash = "enroll=token-9";
    window.dispatchEvent(new Event("hashchange"));
    expect(await screen.findByRole("button", { name: "Create passkey" })).toBeInTheDocument();
  });
});
