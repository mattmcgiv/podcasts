import { useEffect, useState } from "react";
import { Api } from "./api";
import { APP_NAME } from "./config";
import { assertPasskey, createPasskey, enrollTokenFromLocation } from "./passkey";
import { hasLocalLibrary, MAC_OFFLINE_MESSAGE, offlineEnabled } from "./offline/client";

type Gate = "loading" | "ready" | "login" | "enroll" | "unset";

export const AUTH_STATUS_TIMEOUT_MS = 5_000;

function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
  return new Promise((resolve, reject) => {
    const timer = window.setTimeout(() => reject(new Error(MAC_OFFLINE_MESSAGE)), ms);
    promise.then(
      value => { window.clearTimeout(timer); resolve(value); },
      error => { window.clearTimeout(timer); reject(error); },
    );
  });
}

export function AuthGate({ children }: { children: React.ReactNode }) {
  const [gate, setGate] = useState<Gate>("loading");
  const [enrollToken, setEnrollToken] = useState<string | null>(enrollTokenFromLocation());
  const [error, setError] = useState<string | null>(null);

  async function openCachedLibrary(): Promise<boolean> {
    return offlineEnabled() && !enrollTokenFromLocation() && await hasLocalLibrary();
  }

  async function refresh() {
    const token = enrollTokenFromLocation();
    setEnrollToken(token);
    if (await openCachedLibrary()) { setGate("ready"); return; }
    const status = await (offlineEnabled() ? withTimeout(Api.authStatus(), AUTH_STATUS_TIMEOUT_MS) : Api.authStatus());
    if (status.session) {
      window.dispatchEvent(new Event("pods-authenticated"));
      setGate("ready");
      return;
    }
    if (token) {
      setGate("enroll");
      return;
    }
    setGate(status.enrolled ? "login" : "unset");
  }

  useEffect(() => {
    void refresh().catch(() => {
      void openCachedLibrary()
        .then(cached => { setGate(cached ? "ready" : "unset"); })
        .catch(() => setGate("unset"));
    });
    function onAuthRequired() {
      if (offlineEnabled()) return; // Reauthentication lives in Settings; local playback remains usable.
      setGate((current) => (current === "ready" ? "login" : current));
    }
    function onHashChange() {
      void refresh().catch(() => undefined);
    }
    window.addEventListener("pods-auth-required", onAuthRequired);
    window.addEventListener("hashchange", onHashChange);
    return () => {
      window.removeEventListener("pods-auth-required", onAuthRequired);
      window.removeEventListener("hashchange", onHashChange);
    };
  }, []);

  async function enroll() {
    if (!enrollToken) return;
    setError(null);
    try {
      const options = await Api.registerOptions(enrollToken);
      const credential = await createPasskey(options.publicKey);
      await Api.register(options.state_id, credential);
      window.dispatchEvent(new Event("pods-authenticated"));
      window.location.hash = "/recent";
      setGate("ready");
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Passkey enroll failed");
    }
  }

  async function login() {
    setError(null);
    try {
      const options = await Api.loginOptions();
      const credential = await assertPasskey(options.publicKey);
      await Api.login(options.state_id, credential);
      window.dispatchEvent(new Event("pods-authenticated"));
      setGate("ready");
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Passkey sign-in failed");
    }
  }

  if (gate === "loading") {
    return (
      <div className="auth-gate" role="status">
        <p>Loading {APP_NAME}…</p>
      </div>
    );
  }
  if (gate === "ready") return <>{children}</>;
  if (gate === "unset") {
    return (
      <div className="auth-gate" role="status">
        <h1>{APP_NAME}</h1>
        <p>{offlineEnabled() ? "Connect this device and your Mac to Tailscale, then open the enrollment link from the Mac." : "Not set up. Enroll a passkey from the server."}</p>
        {offlineEnabled() && <button type="button" onClick={() => void refresh().catch(() => setGate("unset"))}>Reconnect</button>}
      </div>
    );
  }
  if (gate === "enroll") {
    return (
      <div className="auth-gate">
        <h1>{APP_NAME}</h1>
        <p>Create a passkey in 1Password. This is the only sign-in for this app.</p>
        {error && <p className="auth-error">{error}</p>}
        <button type="button" className="primary-btn" onClick={() => void enroll()}>
          Create passkey
        </button>
      </div>
    );
  }
  return (
    <div className="auth-gate">
      <h1>{APP_NAME}</h1>
      <p>Continue with your 1Password passkey.</p>
      {error && <p className="auth-error">{error}</p>}
      <button type="button" className="primary-btn" onClick={() => void login()}>
        Continue with passkey
      </button>
    </div>
  );
}
