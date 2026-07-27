#!/bin/sh
# Keep two iCloud-synced safety reminders aligned with the verified profile.
set -eu

PROFILE_UUID="${1:-}"
PROFILE_EXPIRATION_EPOCH="${2:-}"
WARNING_SECONDS="${IOS_PROFILE_WARNING_SECONDS:-172800}"
CRITICAL_SECONDS="${IOS_PROFILE_CRITICAL_SECONDS:-43200}"
OSASCRIPT_BIN="${IOS_OSASCRIPT_BIN:-/usr/bin/osascript}"
REMINDERS_ENABLED="${IOS_SIGNING_REMINDERS_ENABLED:-1}"

case "$PROFILE_UUID" in
  *[!A-Za-z0-9._-]*|'')
    echo "error: invalid reminder profile UUID" >&2
    exit 2
    ;;
esac
case "$PROFILE_EXPIRATION_EPOCH:$WARNING_SECONDS:$CRITICAL_SECONDS" in
  *[!0-9:]*|:*|*:)
    echo "error: invalid reminder timing" >&2
    exit 2
    ;;
esac
if [ "$REMINDERS_ENABLED" != "1" ]; then
  exit 0
fi

WARNING_EPOCH=$((PROFILE_EXPIRATION_EPOCH - WARNING_SECONDS))
CRITICAL_EPOCH=$((PROFILE_EXPIRATION_EPOCH - CRITICAL_SECONDS))

"$OSASCRIPT_BIN" - "$WARNING_EPOCH" "$CRITICAL_EPOCH" "$PROFILE_EXPIRATION_EPOCH" "$PROFILE_UUID" <<'APPLESCRIPT'
on run argv
  set warningEpoch to (item 1 of argv) as integer
  set criticalEpoch to (item 2 of argv) as integer
  set expirationEpoch to (item 3 of argv) as integer
  set profileUUID to item 4 of argv
  set currentEpoch to (do shell script "/bin/date +%s") as integer
  set warningDate to (current date) + (warningEpoch - currentEpoch)
  set criticalDate to (current date) + (criticalEpoch - currentEpoch)
  set reminderBody to "The verified Pods provisioning profile " & profileUUID & " expires at epoch " & expirationEpoch & ". The Mac normally renews it automatically."

  tell application "Reminders"
    if not (exists list "Pods") then
      make new list with properties {name:"Pods"}
    end if
    set podsList to list "Pods"

    set warningMatches to every reminder of podsList whose name is "Pods signing expires in 48 hours"
    if (count of warningMatches) is 0 then
      set warningReminder to make new reminder at end of reminders of podsList with properties {name:"Pods signing expires in 48 hours"}
    else
      set warningReminder to item 1 of warningMatches
    end if
    set body of warningReminder to reminderBody
    set due date of warningReminder to warningDate
    set remind me date of warningReminder to warningDate
    set completed of warningReminder to false

    set criticalMatches to every reminder of podsList whose name is "Pods signing expires in 12 hours"
    if (count of criticalMatches) is 0 then
      set criticalReminder to make new reminder at end of reminders of podsList with properties {name:"Pods signing expires in 12 hours"}
    else
      set criticalReminder to item 1 of criticalMatches
    end if
    set body of criticalReminder to reminderBody
    set due date of criticalReminder to criticalDate
    set remind me date of criticalReminder to criticalDate
    set completed of criticalReminder to false
  end tell
end run
APPLESCRIPT
