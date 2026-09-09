"""Mac service setup, immutable releases, DNS, certificates, and backup."""
import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import plistlib
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


def wifi_address():
    ports = subprocess.check_output(["networksetup", "-listallhardwareports"], text=True)
    lines = ports.splitlines()
    device = next((lines[i + 1].split(": ", 1)[1] for i, line in enumerate(lines[:-1]) if line in ("Hardware Port: Wi-Fi", "Hardware Port: AirPort")), None)
    if not device:
        return None
    result = subprocess.run(["ipconfig", "getifaddr", device], capture_output=True, text=True)
    if result.returncode:
        return None
    address = ipaddress.ip_address(result.stdout.strip())
    if address.version != 4 or not address.is_private or address.is_loopback or address.is_link_local:
        return None
    return str(address)


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
    for filename in ("transcribe.py", "manage.py", "pyproject.toml", "uv.lock"):
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
               PODS_MEMORY_GATE_NOTIFY="1",
               PODS_WHISPER_MODEL=config.get("whisper_model", str(Path.home() / "models/whisper-large-v3-mlx")))
    if config.get("omlx_key"):
        env["PODS_OMLX_KEY"] = config["omlx_key"]
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
        with sqlite3.connect(f"file:{path.resolve()}?mode=ro", uri=True) as db:
            row = db.execute(
                "SELECT 1 FROM browser_pending_jobs WHERE stage NOT IN ('blocked','review') "
                "AND (error IS NULL OR error!='memory_busy') "
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
            if separator and key.strip() in ("PODCASTINDEX_KEY", "PODCASTINDEX_SECRET"):
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
                backend = subprocess.Popen([str(release / "pods-backend"), str(STATE / "data/pods.sqlite")], env=env, start_new_session=True)
            address = wifi_address()
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
                    proxy = subprocess.Popen(["caddy", "run", "--config", str(caddyfile)], env=env, start_new_session=True)
                previous = address
            if address != dns_previous and time.time() >= next_dns:
                try:
                    update_dns(config, address)
                    dns_previous = address
                except Exception:
                    print("Local DNS update failed; retrying.", file=sys.stderr)
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


def install_agent():
    read_config()
    if not (STATE / "current/pods-backend").is_file():
        raise RuntimeError("Install a release first")
    directory = Path.home() / "Library/LaunchAgents"
    directory.mkdir(exist_ok=True)
    path = directory / "dev.mcgiv.pods-backend.plist"
    value = {"Label": "dev.mcgiv.pods-backend", "ProgramArguments": [sys.executable, str(STATE / "current/runtime/manage.py"), "run"],
             "RunAtLoad": True, "KeepAlive": True, "ThrottleInterval": 30,
             "EnvironmentVariables": {"PATH": PATH, "PODS_STATE_DIR": str(STATE), "PODS_CONFIG_FILE": str(CONFIG)},
             "StandardOutPath": str(STATE / "service.log"), "StandardErrorPath": str(STATE / "service-error.log")}
    path.write_bytes(plistlib.dumps(value))
    print(f"Prepared {path}. Start with launchctl bootstrap gui/{os.getuid()} {path}")


def main():
    os.environ["PATH"] = PATH
    os.umask(0o077)
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["install", "agent", "run", "certificate", "acme-auth", "acme-cleanup", "backup", "import", "inventory", "jobs", "retry", "enroll"])
    parser.add_argument("arguments", nargs="*")
    args = parser.parse_args()
    if args.command == "install": install()
    elif args.command == "agent": install_agent()
    elif args.command == "run": launch()
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
