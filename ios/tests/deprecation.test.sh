#!/bin/sh
# DEPRECATED as of 1 October 2026. Do not review, extend, or append to this script.
# See ios/DEPRECATED.md.
set -eu
echo "warning: deprecated as of 1 October 2026; do not extend this iPhone app/signing/install tooling. See ios/DEPRECATED.md." >&2

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DATE="1 October 2026"
MARKER="DEPRECATED as of $DATE"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  file="$1"
  pattern="$2"
  [ -f "$file" ] || fail "missing $file"
  grep -Fq -- "$pattern" "$file" || fail "$file does not contain: $pattern"
}

assert_contains "$ROOT/ios/DEPRECATED.md" "$DATE"
assert_contains "$ROOT/ios/DEPRECATED.md" "Do not review"
assert_contains "$ROOT/AGENTS.md" "deprecated as of $DATE"
assert_contains "$ROOT/README.md" "Deprecated as of $DATE"
assert_contains "$ROOT/ios/README.md" "DEPRECATED as of $DATE"

for file in \
  "$ROOT/ios/Pods/PodsApp.swift" \
  "$ROOT/ios/Pods/PodsLocalServer.swift" \
  "$ROOT/ios/Pods/PodsRustBackend.swift" \
  "$ROOT/ios/Pods/PodsWebView.swift" \
  "$ROOT/backend/src/ffi.rs" \
  "$ROOT/backend/src/lib.rs" \
  "$ROOT/backend/include/pods_backend.h" \
  "$ROOT/backend/build-ios.sh" \
  "$ROOT/ios/refresh-device.sh" \
  "$ROOT/ios/install-refresh-agent.sh" \
  "$ROOT/ios/refresh-if-due.sh" \
  "$ROOT/ios/signing-alert.sh" \
  "$ROOT/ios/update-signing-reminders.sh" \
  "$ROOT/ios/check-xcode.sh" \
  "$ROOT/ios/write-podcastindex-credentials.sh" \
  "$ROOT/ios/Pods.xcodeproj/project.pbxproj" \
  "$ROOT/ios/Pods/Info.plist" \
  "$ROOT/ios/dev.mcgiv.pods.refresh.plist.template"
do
  assert_contains "$file" "$MARKER"
done

assert_contains "$ROOT/ios/Pods/PodsApp.swift" '@available(*, deprecated'
assert_contains "$ROOT/ios/Pods/PodsLocalServer.swift" '@available(*, deprecated'
assert_contains "$ROOT/ios/Pods/PodsRustBackend.swift" '@available(*, deprecated'
assert_contains "$ROOT/ios/Pods/PodsApp.swift" '#warning('
assert_contains "$ROOT/backend/src/lib.rs" '#[deprecated('
assert_contains "$ROOT/backend/src/ffi.rs" '#[deprecated('
assert_contains "$ROOT/backend/include/pods_backend.h" 'PODS_IPHONE_DEPRECATED'

tmp="$(mktemp -d)"
"$ROOT/ios/profile-metadata.sh" >"$tmp/out" 2>"$tmp/err" || true
grep -Fq "deprecated as of $DATE" "$tmp/err" \
  || fail "profile-metadata.sh did not warn on stderr"
[ ! -s "$tmp/out" ] || fail "profile-metadata.sh wrote deprecation text to stdout"

assert_contains "$ROOT/ios/check-xcode.sh" "warning: deprecated as of $DATE"
assert_contains "$ROOT/backend/build-ios.sh" "warning: deprecated as of $DATE"
assert_contains "$ROOT/ios/refresh-device.sh" "warning: deprecated as of $DATE"

echo "ios deprecation markers are in place for $DATE"
