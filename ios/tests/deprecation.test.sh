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
assert_contains "$ROOT/README.md" "Active library/API"
assert_contains "$ROOT/ios/README.md" "DEPRECATED as of $DATE"
assert_contains "$ROOT/ios/README.md" "This directory is not the active backend"

if grep -Fq 'Backend behavior for the app lives in `ios/Pods/`' "$ROOT/README.md"; then
  fail "README.md still steers backend work at ios/Pods/"
fi
if grep -Fq 'The user-facing backend is the Swift backend inside the iOS app' "$ROOT/README.md"; then
  fail "README.md still describes the Swift iOS shell as the active backend"
fi
if grep -Fq 'The old Rust backend has been removed' "$ROOT/ios/README.md"; then
  fail "ios/README.md still claims the Rust backend was removed"
fi

ios_source_count=0
ios_source_missing=0
while IFS= read -r file; do
  ios_source_count=$((ios_source_count + 1))
  if ! grep -Fq -- "$MARKER" "$file"; then
    echo "FAIL: $file does not contain: $MARKER" >&2
    ios_source_missing=1
  fi
done <<EOF
$(find "$ROOT/ios" -type f \( -name '*.swift' -o -name '*.sh' \) | sort)
EOF
[ "$ios_source_count" -ge 38 ] || fail "expected at least 38 iOS Swift/shell files, found $ios_source_count"
[ "$ios_source_missing" -eq 0 ] || fail "one or more iOS Swift/shell files are missing the deprecation banner"

for file in \
  "$ROOT/backend/src/ffi.rs" \
  "$ROOT/backend/src/lib.rs" \
  "$ROOT/backend/include/pods_backend.h" \
  "$ROOT/backend/build-ios.sh" \
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
