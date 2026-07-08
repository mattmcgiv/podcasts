#!/bin/sh
# Write Podcast Index credentials into the built app bundle without committing secrets.
set -eu

OUT="${1:?output plist path is required}"
CREDENTIALS_FILE="${PODCASTS_CREDENTIALS_ENV:-$HOME/.config/podcasts/credentials.env}"

/usr/bin/python3 - "$OUT" "$CREDENTIALS_FILE" <<'PY'
import os
import plistlib
import shlex
import sys

out_path = sys.argv[1]
credentials_path = sys.argv[2]
keys = {
    "PODCASTINDEX_KEY",
    "PODCASTINDEX_SECRET",
    "PODCASTINDEX_BASE_URL",
}
values = {}

if os.path.exists(credentials_path):
    with open(credentials_path, "r", encoding="utf-8") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                line = line[len("export "):].strip()
            if "=" not in line:
                continue
            name, value = line.split("=", 1)
            name = name.strip()
            if name not in keys:
                continue
            value = value.strip()
            try:
                parsed = shlex.split(value)
                if len(parsed) == 1:
                    value = parsed[0]
            except ValueError:
                pass
            values[name] = value

for name in keys:
    if os.environ.get(name):
        values[name] = os.environ[name]

values.setdefault("PODCASTINDEX_BASE_URL", "https://api.podcastindex.org/api/1.0")

os.makedirs(os.path.dirname(out_path), exist_ok=True)
with open(out_path, "wb") as handle:
    plistlib.dump(
        {
            "PODCASTINDEX_KEY": values.get("PODCASTINDEX_KEY", ""),
            "PODCASTINDEX_SECRET": values.get("PODCASTINDEX_SECRET", ""),
            "PODCASTINDEX_BASE_URL": values.get("PODCASTINDEX_BASE_URL", ""),
        },
        handle,
    )
PY
