import { render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";
import { AuthGate } from "./AuthGate";
import { HttpError, installApi } from "./test/mockApi";

afterEach(() => {
  window.location.hash = "";
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
});
