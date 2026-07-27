import { useEffect, useState, type FormEvent } from "react";
import { Api } from "../api";
import { Artwork } from "../components/Artwork";
import { emitEpisodesChanged } from "../events";
import type { Follow, FollowCandidate } from "../types";

export function FollowsView() {
  const [follows, setFollows] = useState<Follow[] | null>(null);
  const [candidates, setCandidates] = useState<FollowCandidate[] | null>(null);
  const [name, setName] = useState("");
  const [aliases, setAliases] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = async () => {
    const [nextFollows, nextCandidates] = await Promise.all([Api.follows(), Api.followCandidates()]);
    setFollows(nextFollows);
    setCandidates(nextCandidates);
  };

  useEffect(() => {
    void load().catch((err) => setError(err instanceof Error ? err.message : String(err)));
  }, []);

  async function addFollow(event: FormEvent) {
    event.preventDefault();
    if (busy || !name.trim()) return;
    setBusy(true);
    setError(null);
    try {
      await Api.addFollow(name.trim(), aliases.split(",").map((alias) => alias.trim()).filter(Boolean));
      setName("");
      setAliases("");
      await load();
      emitEpisodesChanged();
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setBusy(false);
    }
  }

  async function act(action: () => Promise<void>) {
    setBusy(true);
    setError(null);
    try {
      await action();
      await load();
      emitEpisodesChanged();
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="view">
      <header className="view-header"><h1>Follows</h1></header>
      <p className="muted follow-intro">Track likely full-length podcast appearances for people you choose. The first check looks back 30 days; later checks look back 7. Low-confidence matches wait for review.</p>
      <form className="follow-form" onSubmit={(event) => void addFollow(event)}>
        <input aria-label="Person to follow" placeholder="Person, e.g. Balaji Srinivasan" value={name} onChange={(event) => setName(event.target.value)} />
        <input aria-label="Aliases" placeholder="Aliases, separated by commas (optional)" value={aliases} onChange={(event) => setAliases(event.target.value)} />
        <button type="submit" disabled={busy || !name.trim()}>{busy ? "…" : "Follow"}</button>
      </form>
      {error && <p className="error">{error}</p>}

      <h2 className="section-title">Following</h2>
      {follows == null && <p className="muted">Loading…</p>}
      {follows?.length === 0 && <p className="empty">No people followed yet.</p>}
      <ul className="follow-list">
        {follows?.map((follow) => (
          <li className="follow-row" key={follow.id}>
            <span className="row-text"><span className="row-title">{follow.name}</span><span className="row-sub">{follow.accepted_count} in Listen{follow.pending_count ? ` · ${follow.pending_count} to review` : ""}</span></span>
            <button className="text-btn" disabled={busy} onClick={() => void act(async () => { await Api.refreshFollow(follow.id); })}>Check</button>
            <button className="text-btn danger" disabled={busy} onClick={() => void act(async () => { await Api.deleteFollow(follow.id); })}>Remove</button>
          </li>
        ))}
      </ul>

      <h2 className="section-title">Review appearances</h2>
      {candidates?.length === 0 && <p className="muted">No ambiguous matches.</p>}
      <ul className="follow-list">
        {candidates?.map((candidate) => <CandidateRow key={candidate.id} candidate={candidate} busy={busy} onAccept={() => void act(() => Api.acceptFollowCandidate(candidate.id))} onReject={() => void act(() => Api.rejectFollowCandidate(candidate.id))} />)}
      </ul>
    </section>
  );
}

function CandidateRow({ candidate, busy, onAccept, onReject }: { candidate: FollowCandidate; busy: boolean; onAccept: () => void; onReject: () => void }) {
  const { appearance } = candidate;
  return <li className="candidate-row">
    <Artwork src={appearance.image_url || appearance.feed_image_url} size={48} />
    <span className="row-text"><span className="row-title">{appearance.title}</span><span className="row-sub">{appearance.feed_title || "Unknown podcast"} · {appearance.evidence}</span></span>
    <span className="candidate-actions"><button className="text-btn" disabled={busy} onClick={onAccept}>Add</button><button className="text-btn danger" disabled={busy} onClick={onReject}>Skip</button></span>
  </li>;
}
