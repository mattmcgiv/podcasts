import { useState, type FormEvent } from "react";
import { Api } from "../api";
import { APP_NAME } from "../config";

export function LoginView({ onLogin }: { onLogin: () => void }) {
  const [token, setTokenValue] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function submit(e: FormEvent) {
    e.preventDefault();
    if (!token.trim() || busy) return;
    setBusy(true);
    setError(null);
    try {
      await Api.login(token.trim());
      onLogin();
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="login">
      <h1>{APP_NAME}</h1>
      <p className="login-hint">Enter the access token configured on your server.</p>
      <form onSubmit={(e) => void submit(e)}>
        <input
          type="password"
          placeholder="Access token"
          value={token}
          onChange={(e) => setTokenValue(e.target.value)}
          autoFocus
        />
        <button type="submit" disabled={busy || !token.trim()}>
          {busy ? "Checking…" : "Unlock"}
        </button>
      </form>
      {error && <p className="error">{error}</p>}
    </div>
  );
}
