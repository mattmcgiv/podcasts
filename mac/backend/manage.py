"""Mac service setup, immutable releases, DNS, certificates, and backup."""
import argparse
import contextlib
from contextlib import closing
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import urllib.error
import zipfile

ROOT = Path(__file__).resolve().parents[2]
STATE = Path(os.environ.get("PODS_STATE_DIR", str(Path.home() / ".local/share/pods")))
CONFIG = Path(os.environ.get("PODS_CONFIG_FILE", str(Path.home() / ".config/podcasts/mac.json")))
DOMAIN = "sync.pods.mcgiv.dev"
MODEL_REVISION = "49e6aa286ad60c14352c404340ded53710378a11"
PATH = "/opt/homebrew/bin:/usr/local/bin:" + str(Path.home() / ".local/bin") + ":" + str(Path.home() / ".cargo/bin") + ":/usr/bin:/bin:/usr/sbin:/sbin"
OMLX_LOOPBACK = ("127.0.0.1", 8000)
OMLX_DOWN_GRACE_SECS = 60
OMLX_START_INTERVAL_SECS = 15 * 60
OMLX_FAST_FAIL_SECS = 0.3
OMLX_APP_CLI = Path("/Applications/oMLX.app/Contents/MacOS/omlx-cli")
SHIP_INTERVAL_SECS = 300
SHIP_LOCK_TIMEOUT_SECS = 30 * 60
SHIP_MAX_ATTEMPTS = 5
SHIP_BACKOFF_BASE_SECS = 300
SHIP_BACKOFF_MAX_SECS = 3600
SHIP_GATE_TIMEOUT_SECS = 900
SHIP_BUILD_TIMEOUT_SECS = 600
SHIP_BROWSER_TIMEOUT_SECS = 600
FEEDBACK_BOT_NAME = "Pods Feedback"
FEEDBACK_BOT_EMAIL = "feedback@pods.local"
CF_ACCOUNT_DEFAULT = "46df77812ed7f1a7cd0c8039f8c60079"
PAGES_PROJECT_DEFAULT = "pods-mcgiv"
PRODUCTION_URL = "https://pods.mcgiv.dev"
SYNC_ORIGIN = "https://sync.pods.mcgiv.dev:8443"


def read_config():
    if not CONFIG.is_file():
        raise RuntimeError(f"Create private configuration at {CONFIG}; see docs/mac-backend.md")
    if CONFIG.stat().st_mode & 0o077:
        raise RuntimeError("Mac configuration must have mode 0600")
    return json.loads(CONFIG.read_text())


def dns_request(url, token, value=None, method=None):
    # The provider's IPv6 route can stall on some Wi-Fi networks. Bound the
    # entire request, and keep authorization out of process arguments/logs.
    if urllib.parse.urlsplit(url).hostname not in ("desec.io", "update.dedyn.io"):
        raise RuntimeError("Unexpected DNS API host")
    options = {"url": url, "header": f"Authorization: Token {token}",
               "request": method or ("POST" if value is not None else "GET")}
    config = "".join(f"{key} = {json.dumps(item)}\n" for key, item in options.items())
    if value is not None:
        config += 'header = "Content-Type: application/json"\n'
        config += "data = " + json.dumps(json.dumps(value)) + "\n"
    response = subprocess.run(["/usr/bin/curl", "-4", "--silent", "--show-error",
        "--connect-timeout", "10", "--max-time", "30", "--write-out", "\n%{http_code}",
        "--config", "-"], input=config, capture_output=True, text=True, timeout=35)
    if response.returncode:
        raise RuntimeError("DNS API transport failed")
    body, _, status = response.stdout.rpartition("\n")
    if not status.isdigit() or not 200 <= int(status) < 300:
        raise urllib.error.HTTPError(url, int(status) if status.isdigit() else 502,
                                     "DNS API request failed", None, None)
    return body


def json_request(url, token, value=None, method=None):
    body = dns_request(url, token, value, method)
    return json.loads(body) if body else None


def tailscale_address():
    """Fail closed: only bind a connected tailnet address, never Wi-Fi or all interfaces."""
    cli = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    try:
        result = subprocess.run([cli, "status", "--json"], capture_output=True, text=True, timeout=10,
                                env=dict(os.environ, TAILSCALE_BE_CLI="1"))
        if result.returncode:
            return None
        status = json.loads(result.stdout)
        if status.get("BackendState") != "Running" or not status.get("Self", {}).get("Online"):
            return None
        for raw in status.get("TailscaleIPs", []):
            address = ipaddress.ip_address(raw)
            if address.version == 4 and address in ipaddress.ip_network("100.64.0.0/10"):
                return str(address)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        pass
    return None


def update_dns(config, address):
    # Both values are explicit: never publish the API caller's public address.
    query = urllib.parse.urlencode({"hostname": DOMAIN, "myipv4": address or "", "myipv6": ""})
    result = dns_request(f"https://update.dedyn.io/?{query}", config["desec_token"]).strip()
    if not result.startswith(("good", "nochg")):
        raise RuntimeError("DNS update was not acknowledged")


def acme_hook(cleanup):
    config = read_config()
    if os.environ["CERTBOT_DOMAIN"] != DOMAIN:
        raise RuntimeError("Unexpected certificate domain")
    validation = os.environ["CERTBOT_VALIDATION"]
    endpoint = f"https://desec.io/api/v1/domains/{DOMAIN}/rrsets/_acme-challenge/TXT/"
    try:
        existing = json_request(endpoint, config["desec_token"])
        records = existing["records"]
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
        existing, records = None, []
    record = json.dumps(validation)
    records = [r for r in records if r != record] if cleanup else list(dict.fromkeys(records + [record]))
    if not records and existing:
        json_request(endpoint, config["desec_token"], method="DELETE")
    elif existing:
        json_request(endpoint, config["desec_token"], {"records": records, "ttl": 3600}, "PATCH")
    elif not cleanup:
        json_request(f"https://desec.io/api/v1/domains/{DOMAIN}/rrsets/", config["desec_token"],
                     {"subname": "_acme-challenge", "type": "TXT", "records": records, "ttl": 3600}, "POST")
    if not cleanup:
        wait_for_acme_dns(validation)


def wait_for_acme_dns(validation):
    # Authoritative servers publish asynchronously, and resolvers can retain
    # earlier NXDOMAIN responses. Do not ask the CA to validate prematurely.
    deadline = time.monotonic() + 900
    resolvers = ("ns1.desec.io", "ns2.desec.org", "1.1.1.1", "8.8.8.8")
    while time.monotonic() < deadline:
        ready = True
        for resolver in resolvers:
            answer = subprocess.run(["/usr/bin/dig", "+short", "+time=3", "+tries=1",
                "TXT", f"_acme-challenge.{DOMAIN}", f"@{resolver}"],
                capture_output=True, text=True, timeout=10)
            if answer.returncode or json.dumps(validation) not in answer.stdout.splitlines():
                ready = False
        if ready:
            return
        time.sleep(15)
    raise RuntimeError("Certificate DNS proof did not propagate within 15 minutes")


def certificate(renew=False):
    config = read_config()
    import shlex
    hook = shlex.join([sys.executable, str(Path(__file__).resolve())])
    args = ["uv", "tool", "run", "--from", "certbot==5.8.0", "certbot"]
    args += ["renew"] if renew else ["certonly", "--manual", "--preferred-challenges", "dns", "-d", DOMAIN,
        "--email", config["acme_email"], "--agree-tos", "--manual-auth-hook", hook + " acme-auth", "--manual-cleanup-hook", hook + " acme-cleanup"]
    args += ["--non-interactive", "--config-dir", str(STATE / "certificates"), "--work-dir", str(STATE / "acme-work"), "--logs-dir", str(STATE / "acme-logs")]
    subprocess.run(args, check=True)


def install():
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    release = STATE / "releases" / time.strftime("%Y%m%d-%H%M%S")
    subprocess.run(["cargo", "build", "--manifest-path", str(ROOT / "backend/Cargo.toml"), "--release", "--features", "passkey", "--bin", "pods-backend"], check=True)
    subprocess.run(["container", "exec", "-w", "/work/client", "pods-dev", "npm", "run", "build"], check=True)
    release.mkdir(parents=True)
    shutil.copy2(ROOT / "backend/target/release/pods-backend", release / "pods-backend")
    shutil.copytree(ROOT / "client/dist", release / "web")
    runtime = release / "runtime"
    runtime.mkdir()
    for filename in ("transcribe.py", "extract_article.py", "synthesize.py", "manage.py", "pyproject.toml", "uv.lock"):
        shutil.copy2(ROOT / "mac/backend" / filename, runtime / filename)
    subprocess.run(["uv", "sync", "--project", str(runtime), "--frozen"], check=True)
    (STATE / "data").mkdir(exist_ok=True)
    key = STATE / "reset.key"
    if not key.exists():
        key.write_text(secrets.token_urlsafe(32)); key.chmod(0o600)
    pending = STATE / "current.next"
    pending.unlink(missing_ok=True)
    pending.symlink_to(release)
    pending.replace(STATE / "current")
    print(f"Prepared immutable release: {release}")


def backup(source, destination):
    destination = destination.resolve()
    if destination.exists():
        raise RuntimeError("Backup destination already exists")
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with sqlite3.connect(f"file:{source.resolve()}?mode=ro", uri=True) as origin, sqlite3.connect(destination) as target:
        origin.backup(target)
        if target.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise RuntimeError("Backup integrity check failed")
    destination.chmod(0o600)
    return inventory(destination)


def inventory(path):
    with sqlite3.connect(f"file:{path.resolve()}?mode=ro", uri=True) as db:
        return {table: db.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
                for table in ("podcasts", "episodes", "episode_state")}


def import_library(source):
    destination = STATE / "data/pods.sqlite"
    print(json.dumps({"imported": backup(source, destination)}))


def backend_env(config):
    # Merge extra keys into the existing mac.json object. Do not replace that file.
    release = STATE / "current"
    env = dict(os.environ, PATH=PATH, PODS_LOCAL="1", PODS_AUTH_MODE="passkey", PODS_BIND="127.0.0.1:18180",
               PODS_ORIGIN="https://pods.mcgiv.dev", PODS_RP_ID="pods.mcgiv.dev", PODS_BROWSER_ORIGIN="https://pods.mcgiv.dev",
               PODS_RESET_KEY_FILE=str(STATE / "reset.key"), PODS_PYTHON=str(release / "runtime/.venv/bin/python"),
               PODS_TRANSCRIBE_SCRIPT=str(release / "runtime/transcribe.py"),
               PODS_EXTRACT_SCRIPT=str(release / "runtime/extract_article.py"),
               PODS_SYNTHESIZE_SCRIPT=str(release / "runtime/synthesize.py"),
               PODS_STATE_DIR=str(STATE),
               PODS_MEMORY_GATE_NOTIFY="1",
               PODS_WHISPER_MODEL=config.get("whisper_model", str(Path.home() / "models/whisper-large-v3-mlx")))
    if config.get("omlx_key"):
        env["PODS_OMLX_KEY"] = config["omlx_key"]
    if config.get("typesafe_key"):
        env["PODS_TYPESAFE_KEY"] = config["typesafe_key"]
    if config.get("classifier"):
        env["PODS_CLASSIFIER"] = str(config["classifier"])
    if config.get("feedback_repo"):
        env["PODS_FEEDBACK_REPO"] = str(config["feedback_repo"])
    if config.get("feedback_timeout_secs"):
        env["PODS_FEEDBACK_TIMEOUT_SECS"] = str(int(config["feedback_timeout_secs"]))
    if config.get("feedback_model"):
        env["PODS_FEEDBACK_MODEL"] = str(config["feedback_model"])
    if "memory_gate" in config:
        env["PODS_MEMORY_GATE"] = "0" if config["memory_gate"] in (False, 0, "0") else "1"
    if "memory_whisper_defer_below_bytes" in config:
        env["PODS_MEMORY_WHISPER_DEFER_BELOW_BYTES"] = str(int(config["memory_whisper_defer_below_bytes"]))
    if "memory_whisper_resume_above_bytes" in config:
        env["PODS_MEMORY_WHISPER_RESUME_ABOVE_BYTES"] = str(int(config["memory_whisper_resume_above_bytes"]))
    if "memory_omlx_defer_below_bytes" in config:
        env["PODS_MEMORY_OMLX_DEFER_BELOW_BYTES"] = str(int(config["memory_omlx_defer_below_bytes"]))
    if "memory_omlx_resume_above_bytes" in config:
        env["PODS_MEMORY_OMLX_RESUME_ABOVE_BYTES"] = str(int(config["memory_omlx_resume_above_bytes"]))
    if "memory_tts_defer_below_bytes" in config:
        env["PODS_MEMORY_TTS_DEFER_BELOW_BYTES"] = str(int(config["memory_tts_defer_below_bytes"]))
    if "memory_tts_resume_above_bytes" in config:
        env["PODS_MEMORY_TTS_RESUME_ABOVE_BYTES"] = str(int(config["memory_tts_resume_above_bytes"]))
    if "article_max_words" in config:
        env["PODS_ARTICLE_MAX_WORDS"] = str(int(config["article_max_words"]))
    if config.get("tts_voice"):
        env["PODS_TTS_VOICE"] = str(config["tts_voice"])
    return env


def omlx_autostart_enabled(config):
    return config.get("omlx_autostart") not in (None, False, 0, "0")


def omlx_autostart_state():
    return {"down_since": None, "next_start_at": 0, "cli_missing_logged": False}


def omlx_tcp_up(timeout=0.5):
    try:
        with socket.create_connection(OMLX_LOOPBACK, timeout=timeout):
            return True
    except OSError:
        return False


def omlx_has_pending_inference(path):
    if not path.is_file():
        return False
    try:
        # A Connection context manager ends a transaction; it does not close the file.
        # This probe runs every five seconds while oMLX is unavailable.
        with closing(sqlite3.connect(f"file:{path.resolve()}?mode=ro", uri=True)) as db:
            row = db.execute(
                "SELECT 1 FROM browser_pending_jobs WHERE stage NOT IN ('blocked','review') "
                "AND (error IS NULL OR error NOT IN ('memory_busy','power_unplugged','power_status_unavailable')) "
                "AND (stage IN ('classifying','ad_boundaries','show_notes') OR error='omlx_busy') LIMIT 1"
            ).fetchone()
    except sqlite3.Error:
        return False
    return row is not None


def omlx_user_cli():
    return Path.home() / ".omlx/bin/omlx"


def omlx_cli_is_managed(path):
    resolved = str(Path(path).resolve())
    return "/oMLX.app/Contents/MacOS/" in resolved or resolved.endswith("/.omlx/bin/omlx")


def omlx_cli():
    for candidate in (OMLX_APP_CLI, omlx_user_cli()):
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    found = shutil.which("omlx", path=PATH)
    if found and omlx_cli_is_managed(found):
        return found
    return None


def post_notification(body):
    script = f"display notification {json.dumps(body)} with title {json.dumps('Pods')}"
    try:
        subprocess.Popen(["/usr/bin/osascript", "-e", script], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        return


def request_omlx_start(cli):
    # Poll for a fast argparse failure. Do not attach PIPE to a child this
    # manager will abandon. stdout is discarded. stderr goes to a temp file.
    stderr = tempfile.TemporaryFile()
    try:
        process = subprocess.Popen([cli, "start", "--no-wait"], stdin=subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL, stderr=stderr,
                                   start_new_session=True, env=dict(os.environ, PATH=PATH))
        deadline = time.monotonic() + OMLX_FAST_FAIL_SECS
        while process.poll() is None and time.monotonic() < deadline:
            time.sleep(0.05)
        if process.poll() is None:
            return
        stderr.seek(0)
        text = stderr.read().decode("utf-8", errors="replace").strip()
        if process.returncode:
            if text:
                print(text.splitlines()[0][:300], file=sys.stderr)
            raise OSError("oMLX start failed")
    finally:
        stderr.close()


def maybe_start_omlx(config, now, state):
    if not omlx_autostart_enabled(config):
        return
    if omlx_tcp_up():
        state["down_since"] = None
        return
    if state["down_since"] is None:
        state["down_since"] = now
        return
    if now - state["down_since"] < OMLX_DOWN_GRACE_SECS:
        return
    if now < state["next_start_at"]:
        return
    if not omlx_has_pending_inference(STATE / "data/pods.sqlite"):
        return
    cli = omlx_cli()
    if not cli:
        if not state["cli_missing_logged"]:
            print("oMLX CLI was not found; will look again later.", file=sys.stderr)
            state["cli_missing_logged"] = True
        return
    try:
        request_omlx_start(cli)
        requested = True
    except Exception:
        requested = False
        print("oMLX start failed.", file=sys.stderr)
    state["next_start_at"] = now + OMLX_START_INTERVAL_SECS
    try:
        if requested:
            print("oMLX not responding; requested start.", file=sys.stderr)
            post_notification("oMLX start requested")
        else:
            post_notification("oMLX start failed")
    except OSError:
        return


def launch():
    config = read_config()
    release = (STATE / "current").resolve(strict=True)
    env = backend_env(config)
    config_credentials = Path.home() / ".config/podcasts/credentials.env"
    if config_credentials.is_file():
        # Only directory credentials are accepted; never source a shell script.
        for line in config_credentials.read_text().splitlines():
            key, separator, value = line.partition("=")
            if separator and key.strip() in (
                "PODCASTINDEX_KEY",
                "PODCASTINDEX_SECRET",
                "TYPESAFE_API_KEY",
                "PODS_TYPESAFE_KEY",
            ):
                env[key.strip()] = value.strip().strip("\"'")
    backend, proxy = None, None
    previous = object()
    dns_previous = object()
    next_dns = 0
    next_certificate = time.time() + 12 * 3600
    omlx_state = omlx_autostart_state()
    stop = False
    def terminate(_signum, _frame):
        nonlocal stop
        stop = True
    signal.signal(signal.SIGTERM, terminate)
    signal.signal(signal.SIGINT, terminate)
    try:
        while not stop:
            if backend is None or backend.poll() is not None:
                backend = spawn_grouped(
                    [str(release / "pods-backend"), str(STATE / "data/pods.sqlite")],
                    env,
                    same_session=True,
                )
            address = tailscale_address()
            if address != previous or (address and proxy and proxy.poll() is not None):
                if proxy:
                    stop_process(proxy); proxy = None
                if address:
                    certificate_path = STATE / "certificates/live" / DOMAIN
                    caddyfile = STATE / "Caddyfile"
                    caddyfile.write_text(f'''{{
    admin off
    auto_https off
}}
https://{DOMAIN}:8443 {{
    bind {address}
    tls "{certificate_path / 'fullchain.pem'}" "{certificate_path / 'privkey.pem'}"
    @internal path /api/internal*
    respond @internal 404
    reverse_proxy 127.0.0.1:18180
}}
''')
                    proxy = spawn_grouped(["caddy", "run", "--config", str(caddyfile)], env)
                previous = address
            if address and address != dns_previous and time.time() >= next_dns:
                try:
                    update_dns(config, address)
                    dns_previous = address
                except Exception:
                    print("Tailscale DNS update failed; retrying.", file=sys.stderr)
                next_dns = time.time() + 60
            if time.time() >= next_certificate:
                try:
                    certificate(renew=True)
                    # Restart the proxy to pick up renewed certificate files.
                    previous = object()
                except Exception:
                    print("Certificate renewal failed.", file=sys.stderr)
                next_certificate = time.time() + 12 * 3600
            try:
                maybe_start_omlx(config, time.time(), omlx_state)
            except Exception:
                print("oMLX autostart failed.", file=sys.stderr)
            time.sleep(5)
    finally:
        for child in (proxy, backend):
            if child:
                stop_process(child)


def spawn_grouped(command, env, *, same_session=False):
    # A new process group lets stop_process signal ffmpeg descendants.
    # The backend must stay in this LaunchAgent GUI session so AVPlayer can
    # reach the default output device. setsid() breaks that path.
    if same_session:
        return subprocess.Popen(command, env=env, preexec_fn=os.setpgrp)
    return subprocess.Popen(command, env=env, start_new_session=True)


def stop_process(child):
    # Include ffmpeg/transcription descendants, even if the parent already exited.
    try:
        os.killpg(child.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        child.wait(timeout=15)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
        child.wait()


def enroll():
    token = secrets.token_urlsafe(32)
    with sqlite3.connect(STATE / "data/pods.sqlite") as db:
        db.execute("INSERT INTO auth_enroll_tokens(token_hash,expires_at,used) VALUES(?,?,0)",
                   (hashlib.sha256(token.encode()).hexdigest(), int(time.time()) + 900))
    # A short-lived secret, displayed only when the operator explicitly requests enrollment.
    print(f"https://pods.mcgiv.dev/#enroll={token}")


def list_jobs(db):
    # The pending view excludes untouched duplicates and played or unsubscribed work.
    return [dict(zip(("episode_id", "stage", "attempts", "error"), row))
            for row in db.execute("SELECT episode_id,stage,attempts,error FROM browser_pending_jobs ORDER BY priority DESC,episode_id LIMIT 100")]


def list_devices(db):
    # One row per syncing browser, newest first. Pulls refresh last_sync_at;
    # only action posts move last_actions_at.
    return [dict(zip(("client_id", "device", "last_sync_at", "sync_count", "last_actions_at"), row))
            for row in db.execute("SELECT client_id,device,last_sync_at,sync_count,last_actions_at FROM browser_sync_devices ORDER BY last_sync_at DESC")]


def retry_job(db, episode):
    episode = int(episode)
    if episode <= 0:
        raise ValueError("Episode ID must be positive")
    # Match worker catalog and listening-state rules. Ready jobs stay eligible.
    # Explicit retry of a blocked job starts a new automatic attempt cycle.
    changed = db.execute(
        "UPDATE browser_jobs SET attempts=CASE WHEN stage='blocked' THEN 0 ELSE attempts END,"
        "stage='queued',error=NULL,next_retry_at=0,priority=1 WHERE episode_id=? AND EXISTS("
        "SELECT 1 FROM browser_episode_catalog e JOIN podcasts p ON p.id=e.podcast_id "
        "LEFT JOIN episode_state s ON s.episode_id=e.id WHERE e.id=browser_jobs.episode_id "
        "AND (p.is_subscribed=1 OR EXISTS(SELECT 1 FROM listen_episodes WHERE episode_id=e.id)) "
        "AND s.played_at IS NULL AND s.archived_at IS NULL)",
        (episode,),
    ).rowcount
    if changed == 1:
        return
    if db.execute("SELECT 1 FROM browser_jobs WHERE episode_id=?", (episode,)).fetchone() is None:
        raise ValueError("Episode job not found")
    raise ValueError("Episode job is not eligible")


class ShipRetry(Exception):
    """Transient land/ship failure: keep the row, back off, try next tick."""


class ShipBlocked(Exception):
    """Land/ship needs a human: the row becomes needs-review, work intact."""


def ship_reason(error, limit=300):
    return f"{type(error).__name__}: {error}".replace("\n", " ").strip()[:limit]


def ship_run(args, timeout=120):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        raise ShipRetry(f"{args[0]} timed out after {timeout}s") from error
    except OSError as error:
        raise ShipRetry(f"{args[0]} not launchable: {error}") from error


def ship_git(repo, *args, timeout=120):
    completed = ship_run(["git", "-C", str(repo), *args], timeout=timeout)
    if completed.returncode != 0:
        tail = ((completed.stdout or "") + (completed.stderr or "")).replace("\n", " ").strip()[-200:]
        raise ShipBlocked(f"git {' '.join(args)} failed: {tail}")
    return completed.stdout.strip()


def ship_container_ready():
    return ship_run(["container", "exec", "pods-dev", "true"], timeout=30).returncode == 0


@contextlib.contextmanager
def ship_lock():
    path = STATE / "ship.lock"
    try:
        path.mkdir()
    except FileExistsError:
        try:
            age = time.time() - path.stat().st_mtime
        except FileNotFoundError:
            age = SHIP_LOCK_TIMEOUT_SECS + 1
        if age < SHIP_LOCK_TIMEOUT_SECS:
            yield False
            return
        shutil.rmtree(path, ignore_errors=True)
        try:
            path.mkdir()
        except FileExistsError:
            yield False
            return
    try:
        yield True
    finally:
        shutil.rmtree(path, ignore_errors=True)


def ship_db():
    return sqlite3.connect(STATE / "data/pods.sqlite", timeout=30)


def ship_select(db, status, throttle=True):
    query = "SELECT id,kind,body,ship_attempts FROM browser_feedback WHERE status=?"
    params = [status]
    if throttle:
        query += " AND next_at<=?"
        params.append(int(time.time()))
    query += " ORDER BY created_at LIMIT 1"
    return db.execute(query, params).fetchone()


def ship_mark(db, report_id, status, result, ship_attempts=None, next_at=0):
    if ship_attempts is None:
        db.execute("UPDATE browser_feedback SET status=?, result=?, next_at=?, started_at=0 WHERE id=?",
                   (status, result[:2000], next_at, report_id))
    else:
        db.execute("UPDATE browser_feedback SET status=?, result=?, next_at=?, started_at=0, ship_attempts=? WHERE id=?",
                   (status, result[:2000], next_at, ship_attempts, report_id))
    db.commit()


def ship_backoff_secs(attempts):
    return min(SHIP_BACKOFF_BASE_SECS * attempts, SHIP_BACKOFF_MAX_SECS)


def ship_valid_id(report_id):
    return bool(report_id) and len(report_id) <= 128 and "/" not in report_id \
        and ".." not in report_id and not report_id.startswith(".")


def ship_commit_message(report_id, kind, body):
    lines = (body or "").strip().splitlines()
    summary = lines[0][:120] if lines else kind
    label = "bug report" if kind == "bug" else "feature request"
    return f"Feedback {report_id[:8]} ({label}): {summary}"


def land_ready(db, repo):
    row = ship_select(db, "ready", throttle=False)
    if row is None:
        return None
    report_id, kind, body, _ = row
    branch = f"feedback/{report_id}"
    try:
        if not ship_valid_id(report_id):
            raise ShipBlocked(f"invalid report id {report_id!r}")
        worktree = STATE / "data/AdRemovalData/feedback-worktrees" / report_id
        if not (worktree / ".git").exists():
            raise ShipBlocked("worktree is missing")
        if not ship_git(repo, "branch", "--list", branch):
            raise ShipBlocked("branch is missing")
        if ship_git(repo, "branch", "--show-current") != "main":
            raise ShipRetry("main checkout is on another branch")
        if ship_git(repo, "status", "--porcelain") != "":
            raise ShipRetry("main checkout is dirty")
        if not ship_container_ready():
            raise ShipRetry("pods-dev is down")
        ahead = int(ship_git(repo, "rev-list", "--count", "origin/main..main"))
        if ahead > 0 and ship_run(["git", "-C", str(repo), "push", "origin", "main"], timeout=180).returncode != 0:
            raise ShipRetry("main is ahead and push failed")
        # Commit first: a fresh branch trivially matches main, so the delta
        # check below only means "already landed" after this commit step.
        if ship_git(worktree, "status", "--porcelain") != "":
            ship_git(worktree, "add", "-A")
            committed = ship_run(["git", "-C", str(worktree), "-c", f"user.name={FEEDBACK_BOT_NAME}",
                                  "-c", f"user.email={FEEDBACK_BOT_EMAIL}",
                                  "commit", "-m", ship_commit_message(report_id, kind, body)], timeout=120)
            if committed.returncode != 0:
                raise ShipBlocked(f"worktree commit failed: {(committed.stderr or '').strip()[:200]}")
        if int(ship_git(worktree, "rev-list", "--count", f"main..{branch}")) == 0:
            ship_mark(db, report_id, "landed", f"already on main ({branch})", ship_attempts=0)
            return report_id
        if ship_run(["git", "-C", str(worktree), "rebase", "main"], timeout=300).returncode != 0:
            ship_run(["git", "-C", str(worktree), "rebase", "--abort"], timeout=60)
            raise ShipBlocked("rebase conflict with main")
        pre = ship_git(repo, "rev-parse", "main")
        merged = ship_run(["git", "-C", str(repo), "merge", "--ff-only", branch], timeout=120)
        if merged.returncode != 0:
            raise ShipBlocked(f"merge failed after rebase: {(merged.stderr or '').strip()[:200]}")
        gate = ship_run([str(repo / "dev/check.sh")], timeout=SHIP_GATE_TIMEOUT_SECS)
        if gate.returncode != 0:
            ship_run(["git", "-C", str(repo), "reset", "--hard", pre], timeout=120)
            tail = ((gate.stdout or "") + (gate.stderr or "")).replace("\n", " ").strip()[-400:]
            raise ShipBlocked(f"merge gate failed: {tail}")
        if ship_run(["git", "-C", str(repo), "push", "origin", "main"], timeout=180).returncode != 0:
            ship_run(["git", "-C", str(repo), "fetch", "origin"], timeout=120)
            rebased = ship_run(["git", "-C", str(repo), "pull", "--rebase", "origin", "main"], timeout=300)
            if rebased.returncode == 0:
                ship_run(["git", "-C", str(repo), "push", "origin", "main"], timeout=180)
            if ship_git(repo, "rev-list", "--count", "origin/main..main") != "0":
                raise ShipBlocked("push rejected; merge kept on local main")
        ship_mark(db, report_id, "landed", f"merged {branch} to main and pushed", ship_attempts=0)
        return report_id
    except ShipBlocked as error:
        ship_mark(db, report_id, "needs-review", f"land blocked: {error}")
        print(f"ship: {report_id} needs review: {error}")
        return None


def ship_dist_hashes(dist):
    return set(re.findall(r"assets/main-[A-Za-z0-9_-]+\.(?:js|css)", (dist / "index.html").read_text()))


def ship_zip_dist(dist, path):
    names = []
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        for file in sorted(dist.rglob("*")):
            if file.is_file() and file.name != ".DS_Store":
                archive.write(file, file.relative_to(dist))
                names.append(file.relative_to(dist).as_posix())
    missing = {"index.html", "_headers", "sw.js"} - set(names)
    if missing:
        raise ShipBlocked(f"zip is missing site root files: {sorted(missing)}")
    if any(name.startswith("dist/") or "node_modules" in name for name in names):
        raise ShipBlocked("zip nests the site root")
    return names


SHIP_HARNESS = """
import time

new_tab("__DEPLOY_URL__")
wait_for_load()
deadline = time.time() + 60
while time.time() < deadline:
    nodes = cdp("Accessibility.getFullAXTree")["nodes"]
    picked = False
    for n in nodes:
        name = (n.get("name") or {}).get("value", "")
        role = (n.get("role") or {}).get("value", "")
        if role == "radio" and name.strip() == "Production":
            box = cdp("DOM.getBoxModel", backendNodeId=n.get("backendDOMNodeId"))["model"]["content"]
            click_at_xy(sum(box[0::2]) / 4, sum(box[1::2]) / 4)
            picked = True
            break
    if picked:
        break
    time.sleep(2)
else:
    raise RuntimeError("production environment radio not found")
upload_file("input[accept='.zip']", "__ZIP__")
deadline = time.time() + 180
while time.time() < deadline:
    nodes = cdp("Accessibility.getFullAXTree")["nodes"]
    if any("All files were successfully uploaded." in ((n.get("name") or {}).get("value", "") or "") for n in nodes):
        break
    time.sleep(2)
else:
    raise RuntimeError("zip upload timed out")
js("Array.from(document.querySelectorAll('button')).filter(function(b){return b.textContent.indexOf('Save and deploy')>=0}).forEach(function(b){b.click()})")
link = None
deadline = time.time() + 300
while time.time() < deadline:
    nodes = cdp("Accessibility.getFullAXTree")["nodes"]
    done = False
    for n in nodes:
        name = (n.get("name") or {}).get("value", "") or ""
        role = (n.get("role") or {}).get("value", "")
        if role == "heading" and name.strip() == "Success!":
            done = True
        if role == "link" and "pages.dev" in name:
            link = name.strip()
    if done:
        break
    time.sleep(4)
else:
    raise RuntimeError("deployment did not reach Success")
print("deployed " + str(link))
"""


def ship_upload(zip_path, account, project):
    script = SHIP_HARNESS.replace("__DEPLOY_URL__", f"https://dash.cloudflare.com/{account}/pages/view/{project}/deployments/new")
    script = script.replace("__ZIP__", str(zip_path))
    try:
        completed = subprocess.run(["browser-harness"], input=script, capture_output=True, text=True,
                                   timeout=SHIP_BROWSER_TIMEOUT_SECS)
    except (subprocess.TimeoutExpired, OSError) as error:
        raise ShipRetry(f"dashboard upload failed: {ship_reason(error)}") from error
    if completed.returncode != 0:
        lines = ((completed.stderr or "") + "\n" + (completed.stdout or "")).strip().splitlines()
        last = lines[-1].strip()[:200] if lines else "no output"
        raise ShipRetry(f"dashboard upload failed: {last}")
    return (completed.stdout or "").strip().splitlines()[-1][:200] if (completed.stdout or "").strip() else "uploaded"


def ship_confirm_live(hashes):
    try:
        with urllib.request.urlopen(PRODUCTION_URL + "/", timeout=30) as response:
            html = response.read().decode("utf-8", "replace")
            csp = response.headers.get("Content-Security-Policy", "")
        with urllib.request.urlopen(PRODUCTION_URL + "/sw.js", timeout=30) as response:
            sw_csp = response.headers.get("Content-Security-Policy", "")
    except Exception as error:
        raise ShipRetry(f"live site unreachable: {ship_reason(error, limit=120)}") from error
    if not hashes or not all(marker in html for marker in hashes):
        raise ShipRetry("live site does not serve this build yet")
    if SYNC_ORIGIN not in csp:
        raise ShipBlocked("live HTML lost the sync connect-src")
    if "connect-src 'self' https:" not in sw_csp:
        raise ShipBlocked("live sw.js lost the worker connect-src")


def ship_landed(db, repo, config):
    row = ship_select(db, "landed", throttle=True)
    if row is None:
        return None
    report_id, kind, body, attempts = row
    try:
        if not ship_container_ready():
            raise ShipRetry("pods-dev is down")
        built = ship_run([str(repo / "dev/sh.sh"), "sh", "-c", "cd /work/client && npm run build"],
                         timeout=SHIP_BUILD_TIMEOUT_SECS)
        if built.returncode != 0:
            raise ShipRetry(f"client build failed: {((built.stdout or '') + (built.stderr or '')).replace(chr(10), ' ').strip()[-200:]}")
        dist = repo / "client/dist"
        hashes = ship_dist_hashes(dist)
        with tempfile.TemporaryDirectory(prefix="pods-ship-") as tmp:
            zip_path = Path(tmp) / f"pods-ship-{report_id[:8]}.zip"
            ship_zip_dist(dist, zip_path)
            account = config.get("cloudflare_account", CF_ACCOUNT_DEFAULT)
            project = config.get("pages_project", PAGES_PROJECT_DEFAULT)
            deployed = ship_upload(zip_path, account, project)
        ship_confirm_live(hashes)
        ship_mark(db, report_id, "deployed", f"live on {PRODUCTION_URL} ({deployed})")
        return report_id
    except ShipRetry as error:
        attempts += 1
        if attempts >= SHIP_MAX_ATTEMPTS:
            ship_mark(db, report_id, "needs-review", f"ship failed {attempts}x: {error}")
        else:
            ship_mark(db, report_id, "landed", f"ship failed ({attempts}/{SHIP_MAX_ATTEMPTS}): {error}",
                      ship_attempts=attempts, next_at=int(time.time()) + ship_backoff_secs(attempts))
        print(f"ship: {report_id} deferred: {error}")
        return None
    except ShipBlocked as error:
        ship_mark(db, report_id, "needs-review", f"ship blocked: {error}")
        print(f"ship: {report_id} needs review: {error}")
        return None


def ship_once():
    config = read_config()
    if not config.get("feedback_repo"):
        print("ship: feedback_repo is not configured; idle")
        return
    repo = Path(config["feedback_repo"])
    if not (repo / ".git").exists():
        print(f"ship: {repo} is not a checkout; idle")
        return
    try:
        with sqlite3.connect(STATE / "data/pods.sqlite", timeout=30) as db:
            with ship_lock() as locked:
                if not locked:
                    print("ship: another run holds the lock")
                    return
                try:
                    landed = land_ready(db, repo)
                    if landed:
                        print(f"ship: landed {landed}")
                except ShipRetry as error:
                    print(f"ship: land deferred: {error}")
                try:
                    shipped = ship_landed(db, repo, config)
                    if shipped:
                        print(f"ship: shipped {shipped}")
                except ShipRetry as error:
                    print(f"ship: ship deferred: {error}")
    except Exception as error:
        print(f"ship: unexpected {ship_reason(error)}")


def install_agent():
    config = read_config()
    if not (STATE / "current/pods-backend").is_file():
        raise RuntimeError("Install a release first")
    directory = Path.home() / "Library/LaunchAgents"
    directory.mkdir(exist_ok=True)
    path = directory / "dev.mcgiv.pods-backend.plist"
    environment = {"PATH": PATH, "PODS_STATE_DIR": str(STATE), "PODS_CONFIG_FILE": str(CONFIG)}
    if config.get("classifier"):
        environment["PODS_CLASSIFIER"] = str(config["classifier"])
    value = {"Label": "dev.mcgiv.pods-backend", "ProgramArguments": [sys.executable, str(STATE / "current/runtime/manage.py"), "run"],
             "RunAtLoad": True, "KeepAlive": True, "ThrottleInterval": 30,
             "EnvironmentVariables": environment,
             "StandardOutPath": str(STATE / "service.log"), "StandardErrorPath": str(STATE / "service-error.log")}
    path.write_bytes(plistlib.dumps(value))
    print(f"Prepared {path}. Start with launchctl bootstrap gui/{os.getuid()} {path}")
    ship_path = directory / "dev.mcgiv.pods-ship.plist"
    ship_value = {"Label": "dev.mcgiv.pods-ship",
                  "ProgramArguments": [sys.executable, str(STATE / "current/runtime/manage.py"), "ship"],
                  "RunAtLoad": True, "StartInterval": SHIP_INTERVAL_SECS,
                  "EnvironmentVariables": environment,
                  "StandardOutPath": str(STATE / "ship.log"), "StandardErrorPath": str(STATE / "ship-error.log")}
    ship_path.write_bytes(plistlib.dumps(ship_value))
    print(f"Prepared {ship_path}. Start with launchctl bootstrap gui/{os.getuid()} {ship_path}")


def main():
    os.environ["PATH"] = PATH
    os.umask(0o077)
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["install", "agent", "run", "ship", "certificate", "acme-auth", "acme-cleanup", "backup", "import", "inventory", "jobs", "retry", "enroll", "devices"])
    parser.add_argument("arguments", nargs="*")
    args = parser.parse_args()
    if args.command == "install": install()
    elif args.command == "agent": install_agent()
    elif args.command == "run": launch()
    elif args.command == "ship": ship_once()
    elif args.command == "certificate": certificate()
    elif args.command == "enroll": enroll()
    elif args.command.startswith("acme-"): acme_hook(args.command == "acme-cleanup")
    elif args.command == "backup": print(json.dumps(backup(Path(args.arguments[0]), Path(args.arguments[1]))))
    elif args.command == "import": import_library(Path(args.arguments[0]))
    elif args.command == "inventory": print(json.dumps(inventory(Path(args.arguments[0]))))
    else:
        with sqlite3.connect(STATE / "data/pods.sqlite") as db:
            if args.command == "jobs":
                for row in list_jobs(db):
                    print(json.dumps(row))
            elif args.command == "devices":
                for row in list_devices(db):
                    print(json.dumps(row))
            else:
                if not args.arguments:
                    raise ValueError("Episode ID must be positive")
                retry_job(db, args.arguments[0])


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Provider responses can include secrets; report only a bounded category.
        print(f"Pods setup failed: {type(error).__name__}. See docs/mac-backend.md.", file=sys.stderr)
        sys.exit(1)
