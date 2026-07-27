#!/bin/sh
# Decode the identity and lifetime of an Apple provisioning profile.
set -eu

PROFILE_PATH="${1:-}"
SECURITY_BIN="${IOS_SECURITY_BIN:-/usr/bin/security}"
PLUTIL_BIN="${IOS_PLUTIL_BIN:-/usr/bin/plutil}"
DATE_BIN="${IOS_DATE_BIN:-/bin/date}"

if [ -z "$PROFILE_PATH" ] || [ ! -f "$PROFILE_PATH" ]; then
  echo "error: provisioning profile path is required" >&2
  exit 2
fi

DECODED_PROFILE="$(mktemp "${TMPDIR:-/tmp}/pods-decoded-profile.XXXXXX")"
cleanup() {
  rm -f "$DECODED_PROFILE"
}
trap cleanup EXIT

"$SECURITY_BIN" cms -D -i "$PROFILE_PATH" > "$DECODED_PROFILE"

PROFILE_UUID="$("$PLUTIL_BIN" -extract UUID raw -o - "$DECODED_PROFILE")"
PROFILE_CREATION_DATE="$("$PLUTIL_BIN" -extract CreationDate raw -o - "$DECODED_PROFILE")"
PROFILE_EXPIRATION_DATE="$("$PLUTIL_BIN" -extract ExpirationDate raw -o - "$DECODED_PROFILE")"
APPLICATION_IDENTIFIER="$("$PLUTIL_BIN" -extract Entitlements.application-identifier raw -o - "$DECODED_PROFILE")"

date_to_epoch() {
  profile_date="$1"
  case "$profile_date" in
    *T*Z)
      "$DATE_BIN" -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$profile_date" '+%s'
      ;;
    *)
      "$DATE_BIN" -j -f '%Y-%m-%d %H:%M:%S %z' "$profile_date" '+%s'
      ;;
  esac
}

PROFILE_CREATION_EPOCH="$(date_to_epoch "$PROFILE_CREATION_DATE")"
PROFILE_EXPIRATION_EPOCH="$(date_to_epoch "$PROFILE_EXPIRATION_DATE")"

case "$PROFILE_UUID" in
  *[!A-Za-z0-9._-]*|'')
    echo "error: provisioning profile UUID is invalid" >&2
    exit 1
    ;;
esac
case "$PROFILE_CREATION_EPOCH:$PROFILE_EXPIRATION_EPOCH" in
  *[!0-9:]*|:*|*:)
    echo "error: provisioning profile dates are invalid" >&2
    exit 1
    ;;
esac
case "$APPLICATION_IDENTIFIER" in
  *[!A-Za-z0-9._*-]*|'')
    echo "error: provisioning profile application identifier is invalid" >&2
    exit 1
    ;;
esac

printf 'profile_uuid=%s\n' "$PROFILE_UUID"
printf 'profile_creation_epoch=%s\n' "$PROFILE_CREATION_EPOCH"
printf 'profile_expiration_epoch=%s\n' "$PROFILE_EXPIRATION_EPOCH"
printf 'application_identifier=%s\n' "$APPLICATION_IDENTIFIER"
