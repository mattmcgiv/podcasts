import { render, screen } from "@testing-library/react";
import { IDBFactory } from "fake-indexeddb";
import { afterEach, describe, expect, it, vi } from "vitest";
import { AuthGate } from "./AuthGate";
import { updateState } from "./offline/store";
import { HttpError, installApi } from "./test/mockApi";

afterEach(() => {
  window.location.hash = "";
  delete window.PODS_LOCAL_CLIENT;
});

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
});
