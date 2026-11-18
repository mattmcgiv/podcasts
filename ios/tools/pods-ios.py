#!/usr/bin/env python3
"""Install the Pods iPhone app and keep its free-account signature fresh.

Only Xcode's own tools sign and install. Settings live outside the repo in
~/.config/podcasts/ios.env:

    TEAM=<Apple Personal Team ID>
    DEVICE=<devicectl identifier or name of the iPhone>

Commands:
    install     build, sign, install, and pair the app with the Mac backend
    refresh     re-sign and reinstall when the signature has under 3 days left (--force: now)
    status      show the signature expiry, the app's status file, and its last report to the Mac
    schedule    run `refresh` from launchd every 3 hours
    unschedule  remove that launchd job
"""
import datetime, fcntl, json, os, pathlib, plistlib, shutil, subprocess, sys, tempfile, time

REPO = pathlib.Path(__file__).resolve().parents[2]
STATE = pathlib.Path.home() / ".local/share/pods/ios"
CONFIG = pathlib.Path.home() / ".config/podcasts/ios.env"
BUNDLE = "dev.mcgiv.pods"
LABEL = "dev.mcgiv.pods-ios-refresh"
AGENT = pathlib.Path.home() / f"Library/LaunchAgents/{LABEL}.plist"
APP = STATE / "DerivedData/Build/Products/Release-iphoneos/Pods.app"
CONTAINER = "Library/Application Support/Pods"
REPORTS = pathlib.Path.home() / ".local/share/pods/data/AdRemovalData/Diagnostics/devices"
REFRESH_BELOW = 3 * 86400   # start trying with three days left
WARN_BELOW = 2 * 86400      # tell Matt when attempts still fail with two days left
PROFILE_DIRS = [pathlib.Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles",
                pathlib.Path.home() / "Library/MobileDevice/Provisioning Profiles"]


class Failure(Exception):
    pass


def log(message):
    line = f"{datetime.datetime.now().isoformat(timespec='seconds')} {message}"
    print(line, flush=True)
    STATE.mkdir(parents=True, exist_ok=True)
    with open(STATE / "refresh.log", "a") as handle:
        handle.write(line + "\n")


def config():
    if not CONFIG.exists():
        raise Failure(f"{CONFIG} is missing. Create it with TEAM=<team id> and DEVICE=<iPhone identifier>.")
    values = dict(line.strip().split("=", 1) for line in CONFIG.read_text().splitlines() if "=" in line and not line.startswith("#"))
    for key in ("TEAM", "DEVICE"):
        if not values.get(key):
            raise Failure(f"{CONFIG} needs {key}=...")
    return values


def run(args, timeout, quiet=False):
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if result.returncode and not quiet:
        tail = "\n".join((result.stdout + result.stderr).strip().splitlines()[-25:])
        raise Failure(f"{' '.join(map(str, args[:4]))} failed ({result.returncode}):\n{tail}")
    return result


def read_state():
    try:
        return json.loads((STATE / "state.json").read_text())
    except (OSError, ValueError):
        return {}


def write_state(**changes):
    state = {**read_state(), **changes}
    STATE.mkdir(parents=True, exist_ok=True)
    (STATE / "state.json").write_text(json.dumps(state, indent=2) + "\n")


def profile(path):
    data = run(["/usr/bin/security", "cms", "-D", "-i", str(path)], 30).stdout.encode()
    return plistlib.loads(data)


def expiry(app):
    stamp = profile(app / "embedded.mobileprovision")["ExpirationDate"]
    return stamp.replace(tzinfo=datetime.timezone.utc).timestamp()


def drop_cached_profiles():
    """Xcode reuses a cached profile until it expires. Removing ours makes it ask Apple for a new seven-day one."""
    for directory in PROFILE_DIRS:
        for path in directory.glob("*.mobileprovision") if directory.is_dir() else []:
            try:
                identifier = profile(path).get("Entitlements", {}).get("application-identifier", "")
            except Exception:
                continue
            if identifier.endswith("." + BUNDLE):
                path.unlink()


def build(team, fresh_profile):
    if fresh_profile:
        drop_cached_profiles()
        shutil.rmtree(APP, ignore_errors=True)   # compiled objects stay cached; only packaging and signing rerun
    run(["/usr/bin/xcrun", "xcodebuild", "-project", str(REPO / "ios/Pods.xcodeproj"), "-scheme", "Pods",
         "-configuration", "Release", "-destination", "generic/platform=iOS",
         "-derivedDataPath", str(STATE / "DerivedData"), "-allowProvisioningUpdates",
         f"DEVELOPMENT_TEAM={team}", "CODE_SIGN_STYLE=Automatic", "build"], 1800)
    if not (APP / "embedded.mobileprovision").exists():
        raise Failure("The build produced no signed app.")
    return expiry(APP)


def install(device):
    # "Installed" is the whole success test. The phone may be locked, so nothing is launched.
    run(["/usr/bin/xcrun", "devicectl", "device", "install", "app", "--device", device, str(APP)], 600)


def app_status(device):
    """The app writes a small status file on every sync; None when it cannot be read."""
    with tempfile.TemporaryDirectory() as folder:
        target = pathlib.Path(folder) / "device-status.json"
        result = run(["/usr/bin/xcrun", "devicectl", "device", "copy", "from", "--device", device,
                      "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE,
                      "--source", f"{CONTAINER}/device-status.json", "--destination", str(target)], 120, quiet=True)
        try:
            return json.loads(target.read_text()) if result.returncode == 0 else None
        except (OSError, ValueError):
            return None


def deliver_pair_code(device):
    """Hand the app a ten-minute, single-use sign-in code through its container. It is used on the next launch."""
    code = run([sys.executable, str(REPO / "mac/backend/manage.py"), "pair"], 30).stdout.strip()
    with tempfile.TemporaryDirectory() as folder:
        source = pathlib.Path(folder) / "pair-code"
        source.touch(mode=0o600)
        source.write_text(code)
        result = run(["/usr/bin/xcrun", "devicectl", "device", "copy", "to", "--device", device,
                      "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE,
                      "--source", str(source), "--destination", f"{CONTAINER}/pair-code"], 120, quiet=True)
    if result.returncode:
        log("Could not place the pairing code on the phone. Open Pods once, then run `pods-ios.py install` again, "
            "or run `python3 mac/backend/manage.py pair` and type the code into the app.")
        return False
    log("Pairing code delivered. Open Pods within ten minutes to sign in.")
    return True


def notify(message):
    script = f'display notification {json.dumps(message)} with title "Pods iPhone app"'
    subprocess.run(["/usr/bin/osascript", "-e", script], capture_output=True, timeout=30)


def days(seconds):
    return f"{seconds / 86400:.1f} days"


def command_install():
    settings = config()
    expires = build(settings["TEAM"], fresh_profile=True)
    install(settings["DEVICE"])
    write_state(expires=expires, installed_at=time.time(), last_error=None)
    log(f"Installed. Signature lasts {days(expires - time.time())}.")
    status = app_status(settings["DEVICE"])
    if not (status and status.get("paired")):
        deliver_pair_code(settings["DEVICE"])


def command_refresh(force):
    state = read_state()
    left = state.get("expires", 0) - time.time()
    if not force and left > REFRESH_BELOW:
        return
    settings = config()
    try:
        expires = build(settings["TEAM"], fresh_profile=True)
        if expires - time.time() < REFRESH_BELOW:
            raise Failure(f"Apple returned a profile with only {days(expires - time.time())} left.")
        install(settings["DEVICE"])
    except (Failure, subprocess.TimeoutExpired) as error:
        write_state(last_error=str(error), last_attempt=time.time())
        log(f"Refresh failed with {days(left)} left: {error}")
        # One notification per day at most, and only once it is urgent.
        if left < WARN_BELOW and time.time() - state.get("warned_at", 0) > 86400:
            notify(f"Could not re-sign Pods; it stops opening in {days(max(left, 0))}. Keep the iPhone unlocked near this Mac, "
                   "and check Xcode is signed in. See ~/.local/share/pods/ios/refresh.log")
            write_state(warned_at=time.time())
        raise SystemExit(1)
    write_state(expires=expires, installed_at=time.time(), last_error=None, last_attempt=time.time(), warned_at=0)
    log(f"Refreshed. Signature lasts {days(expires - time.time())}.")
    status = app_status(settings["DEVICE"])
    if status is not None and not status.get("paired"):
        deliver_pair_code(settings["DEVICE"])


def latest_report():
    """The newest status and log tail the iPhone sent the Mac (works without a cable).
    Reports from the Simulator are skipped."""
    reports = []
    for path in REPORTS.glob("*.json"):
        try:
            report = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        body = report.get("report")
        if not isinstance(body, dict) or body.get("simulator") is not False:
            continue  # the Simulator, or an app too old to say
        if str(body.get("app", "")).startswith("Pods-iOS/"):
            reports.append(report)
    return max(reports, key=lambda r: r.get("received_at", 0), default=None)


def command_status():
    state = read_state()
    if state.get("expires"):
        print(f"Signature expires {datetime.datetime.fromtimestamp(state['expires']):%a %d %b %H:%M} "
              f"({days(state['expires'] - time.time())} left)")
    else:
        print("Not installed by this tool yet.")
    if state.get("last_error"):
        print(f"Last refresh error: {state['last_error']}")
    print(f"Scheduled: {'yes' if AGENT.exists() else 'no'}")
    report = latest_report()
    if report:
        body = report["report"]
        age = time.time() - report.get("received_at", 0)
        print(f"Last report to the Mac: {age / 60:.0f} min ago ({body.get('reason', '?')}, {body.get('app', '?')}, "
              f"client {report.get('client_id', '?')})")
        print("  " + json.dumps(body.get("status", {}), sort_keys=True))
        tail = str(body.get("log", "")).strip().splitlines()[-8:]
        if tail:
            print("  Log tail:\n    " + "\n    ".join(tail))
    else:
        print("Last report to the Mac: none yet")
    try:
        status = app_status(config()["DEVICE"])
        print("App status file: " + (json.dumps(status, indent=2) if status else "unavailable (phone unreachable or app never opened)"))
    except Failure as error:
        print(error)


def command_schedule():
    AGENT.parent.mkdir(parents=True, exist_ok=True)
    STATE.mkdir(parents=True, exist_ok=True)
    with open(AGENT, "wb") as handle:
        plistlib.dump({
            "Label": LABEL,
            "ProgramArguments": ["/usr/bin/python3", str(pathlib.Path(__file__).resolve()), "refresh"],
            "StartInterval": 3 * 3600,   # launchd runs a missed interval once after the Mac wakes
            "RunAtLoad": True,
            "ProcessType": "Background",
            "StandardOutPath": str(STATE / "launchd.log"),
            "StandardErrorPath": str(STATE / "launchd.log"),
        }, handle)
    domain = f"gui/{os.getuid()}"
    subprocess.run(["/bin/launchctl", "bootout", f"{domain}/{LABEL}"], capture_output=True)
    run(["/bin/launchctl", "bootstrap", domain, str(AGENT)], 30)
    print(f"Scheduled {LABEL}: checks every 3 hours and re-signs once under 3 days remain.")


def command_unschedule():
    subprocess.run(["/bin/launchctl", "bootout", f"gui/{os.getuid()}/{LABEL}"], capture_output=True)
    AGENT.unlink(missing_ok=True)
    print("Removed the refresh job.")


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command not in ("install", "refresh", "status", "schedule", "unschedule"):
        print(__doc__)
        raise SystemExit(2)
    STATE.mkdir(parents=True, exist_ok=True)
    lock = open(STATE / "lock", "w")
    if command in ("install", "refresh"):
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            raise SystemExit(0)   # another run is already working
    try:
        {"install": command_install, "refresh": lambda: command_refresh("--force" in sys.argv),
         "status": command_status, "schedule": command_schedule, "unschedule": command_unschedule}[command]()
    except Failure as error:
        log(str(error))
        raise SystemExit(1)


if __name__ == "__main__":
    main()
