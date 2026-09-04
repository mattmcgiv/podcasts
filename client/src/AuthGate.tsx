import { useEffect, useState } from "react";
import { Api } from "./api";
import { APP_NAME } from "./config";
import { assertPasskey, createPasskey, enrollTokenFromLocation } from "./passkey";

type Gate = "loading" | "ready" | "login" | "enroll" | "unset";

export function AuthGate({ children }: { children: React.ReactNode }) {
  const [gate, setGate] = useState<Gate>("loading");
  const [enrollToken, setEnrollToken] = useState<string | null>(enrollTokenFromLocation());
  const [error, setError] = useState<string | null>(null);

  async function refresh() {
    const token = enrollTokenFromLocation();
    setEnrollToken(token);
    const status = await Api.authStatus();
    if (status.session) {
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
    void refresh().catch(() => setGate("unset"));
    function onAuthRequired() {
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
        <p>Not set up. Enroll a passkey from the server.</p>
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
