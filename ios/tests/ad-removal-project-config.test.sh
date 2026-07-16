#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
project="$repo_root/ios/Pods.xcodeproj/project.pbxproj"

target_count=$(grep -c 'IPHONEOS_DEPLOYMENT_TARGET = ' "$project")
ios_26_count=$(grep -c 'IPHONEOS_DEPLOYMENT_TARGET = 26.0;' "$project" || true)

if [ "$target_count" -ne "$ios_26_count" ]; then
    echo "Expected every iOS target to use deployment target 26.0" >&2
    exit 1
fi

echo "ad-removal project configuration tests passed"
