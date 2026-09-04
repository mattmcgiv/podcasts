#!/bin/sh
# DEPRECATED as of 1 October 2026. Do not review, extend, or append to this script.
# See ios/DEPRECATED.md.
set -eu
echo "warning: deprecated as of 1 October 2026; do not extend this iPhone app/signing/install tooling. See ios/DEPRECATED.md." >&2

ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

make_case() {
  name="$1"
  case_root="$TMP/$name"
  mkdir -p "$case_root/repo/ios/Pods" "$case_root/repo/client/dist" "$case_root/bin" "$case_root/fixture"
  cp "$ROOT/ios/prepare-web-assets.sh" "$case_root/repo/ios/prepare-web-assets.sh"
  cp "$ROOT/ios/atomic-directory-swap.swift" "$case_root/repo/ios/atomic-directory-swap.swift"
  chmod +x "$case_root/repo/ios/prepare-web-assets.sh"

  cat > "$case_root/bin/container" <<'STUB'
#!/bin/sh
case "$1" in
  inspect)
    printf '{ "state" : "running", "mounts" : [{ "source" : "%s", "destination" : "/work/client" }] }\n' "$TEST_CLIENT_ROOT"
    ;;
  exec)
    rm -rf "$TEST_CLIENT_ROOT/dist"
    mkdir -p "$TEST_CLIENT_ROOT/dist"
    cp -R "$TEST_FIXTURE_ROOT/." "$TEST_CLIENT_ROOT/dist/"
    ;;
  *)
    echo "unexpected container command: $*" >&2
    exit 2
    ;;
esac
STUB
  chmod +x "$case_root/bin/container"
  printf '%s\n' "$case_root"
}

run_prepare() {
  case_root="$1"
  TEST_CLIENT_ROOT="$case_root/repo/client" \
  TEST_FIXTURE_ROOT="$case_root/fixture" \
  CONTAINER_BIN="$case_root/bin/container" \
  ATOMIC_SWAP_BIN="${TEST_SWAP_BIN:-}" \
  REAL_SWAP_HELPER="$ROOT/ios/atomic-directory-swap.swift" \
    "$case_root/repo/ios/prepare-web-assets.sh"
}

broken="$(make_case broken)"
mkdir -p "$broken/fixture/assets"
cat > "$broken/fixture/index.html" <<'HTML'
<!doctype html>
<link rel="stylesheet" href="./assets/app.css">
<script type="module" src="./assets/missing.js"></script>
HTML
printf 'body {}\n' > "$broken/fixture/assets/app.css"

set +e
run_prepare "$broken" >"$broken/output.log" 2>&1
broken_status=$?
set -e
[ "$broken_status" -ne 0 ] || fail "prepare-web-assets accepted an index that references a missing local asset"
grep -Fq "missing referenced asset" "$broken/output.log" || {
  sed -n '1,200p' "$broken/output.log" >&2
  fail "prepare-web-assets did not explain the invalid asset graph"
}

symlinked="$(make_case symlinked)"
mkdir -p "$symlinked/fixture/assets" "$symlinked/outside"
cat > "$symlinked/fixture/index.html" <<'HTML'
<!doctype html>
<script type="module" src="./assets/app.js"></script>
HTML
printf 'document.body.dataset.ready = "yes";\n' > "$symlinked/outside/app.js"
ln -s "$symlinked/outside/app.js" "$symlinked/fixture/assets/app.js"

set +e
run_prepare "$symlinked" >"$symlinked/output.log" 2>&1
symlinked_status=$?
set -e
[ "$symlinked_status" -ne 0 ] || fail "prepare-web-assets accepted a symlink in the staged bundle"
grep -Fq "symbolic link" "$symlinked/output.log" || {
  sed -n '1,200p' "$symlinked/output.log" >&2
  fail "prepare-web-assets did not explain the symlink rejection"
}

interrupted="$(make_case interrupted)"
mkdir -p "$interrupted/fixture/assets" "$interrupted/repo/ios/Pods/Web"
cat > "$interrupted/fixture/index.html" <<'HTML'
<!doctype html>
<script type="module" src="./assets/new.js"></script>
HTML
printf 'document.body.dataset.ready = "new";\n' > "$interrupted/fixture/assets/new.js"
printf 'known-good-index\n' > "$interrupted/repo/ios/Pods/Web/index.html"
cat > "$interrupted/bin/kill-after-swap" <<'STUB'
#!/bin/sh
set -e
xcrun swift "$REAL_SWAP_HELPER" "$@"
kill -KILL "$PPID"
STUB
chmod +x "$interrupted/bin/kill-after-swap"

set +e
(
  TEST_SWAP_BIN="$interrupted/bin/kill-after-swap" \
    run_prepare "$interrupted"
) >"$interrupted/output.log" 2>&1
interrupted_status=$?
set -e
[ "$interrupted_status" -ne 0 ] || fail "fault injection did not interrupt prepare-web-assets"
[ -f "$interrupted/repo/ios/Pods/Web/index.html" ] \
  || fail "an uncatchable interruption left no canonical Web bundle"
grep -Fq './assets/new.js' "$interrupted/repo/ios/Pods/Web/index.html" \
  || fail "an uncatchable interruption did not leave the atomically activated bundle canonical"
[ -f "$interrupted/repo/ios/Pods/Web/assets/new.js" ] \
  || fail "an uncatchable interruption left a partial canonical Web bundle"

swap_failure="$(make_case swap-failure)"
mkdir -p "$swap_failure/fixture/assets" "$swap_failure/repo/ios/Pods/Web"
cat > "$swap_failure/fixture/index.html" <<'HTML'
<!doctype html>
<script type="module" src="./assets/new.js"></script>
HTML
printf 'document.body.dataset.ready = "new";\n' > "$swap_failure/fixture/assets/new.js"
printf 'known-good-index\n' > "$swap_failure/repo/ios/Pods/Web/index.html"
printf 'known-good-asset\n' > "$swap_failure/repo/ios/Pods/Web/old.js"
cat > "$swap_failure/bin/swap" <<'STUB'
#!/bin/sh
echo "injected atomic bundle-swap failure" >&2
exit 73
STUB
chmod +x "$swap_failure/bin/swap"

set +e
(TEST_SWAP_BIN="$swap_failure/bin/swap" run_prepare "$swap_failure") >"$swap_failure/output.log" 2>&1
swap_status=$?
set -e
[ "$swap_status" -ne 0 ] || fail "prepare-web-assets ignored an injected bundle-swap failure"
grep -Fq "known-good-index" "$swap_failure/repo/ios/Pods/Web/index.html" \
  || fail "a failed bundle swap did not restore the prior index"
grep -Fq "known-good-asset" "$swap_failure/repo/ios/Pods/Web/old.js" \
  || fail "a failed bundle swap did not restore the prior assets"
if find "$swap_failure/repo/ios/Pods" -maxdepth 1 \( -name '.Web.stage.*' -o -name '.Web.previous.*' \) | grep -q .; then
  fail "a failed bundle swap left staging or backup directories behind"
fi

valid="$(make_case valid)"
mkdir -p "$valid/fixture/assets" "$valid/repo/ios/Pods/Web"
cat > "$valid/fixture/index.html" <<'HTML'
<!doctype html>
<link rel="stylesheet" href="./assets/app.css?build=1">
<link rel="manifest" href="./manifest.webmanifest">
<script type="module" src="./assets/app.js#entry"></script>
HTML
printf 'body {}\n' > "$valid/fixture/assets/app.css"
printf 'document.body.dataset.ready = "yes";\n' > "$valid/fixture/assets/app.js"
printf '{}\n' > "$valid/fixture/manifest.webmanifest"
printf 'old-bundle\n' > "$valid/repo/ios/Pods/Web/index.html"

run_prepare "$valid" >/dev/null
[ -f "$valid/repo/ios/Pods/Web/assets/app.js" ] || fail "valid graph was not staged"
if grep -Fq "old-bundle" "$valid/repo/ios/Pods/Web/index.html"; then
  fail "the atomic swap did not activate the validated bundle"
fi
if find "$valid/repo/ios/Pods" -maxdepth 1 -name '.Web.stage.*' | grep -q .; then
  fail "a successful bundle swap left its prior bundle behind"
fi

absent="$(make_case absent)"
mkdir -p "$absent/fixture/assets"
cat > "$absent/fixture/index.html" <<'HTML'
<!doctype html>
<script type="module" src="./assets/app.js"></script>
HTML
printf 'document.body.dataset.ready = "yes";\n' > "$absent/fixture/assets/app.js"
run_prepare "$absent" >/dev/null
[ -f "$absent/repo/ios/Pods/Web/assets/app.js" ] \
  || fail "atomic activation did not create an initially absent Web bundle"

echo "prepare web asset tests passed"
