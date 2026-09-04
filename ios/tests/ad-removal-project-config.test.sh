#!/bin/sh
# DEPRECATED as of 1 October 2026. Do not review, extend, or append to this script.
# See ios/DEPRECATED.md.
set -eu
echo "warning: deprecated as of 1 October 2026; do not extend this iPhone app/signing/install tooling. See ios/DEPRECATED.md." >&2

repo_root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
project="$repo_root/ios/Pods.xcodeproj/project.pbxproj"

target_count=$(grep -c 'IPHONEOS_DEPLOYMENT_TARGET = ' "$project")
ios_26_count=$(grep -c 'IPHONEOS_DEPLOYMENT_TARGET = 26.0;' "$project" || true)

if [ "$target_count" -ne "$ios_26_count" ]; then
    echo "Expected every iOS target to use deployment target 26.0" >&2
    exit 1
fi

grep -q 'repositoryURL = "https://github.com/ml-explore/mlx-swift-lm";' "$project"
grep -q 'kind = exactVersion;' "$project"
grep -q 'version = 2.31.3;' "$project"
grep -q 'productName = MLXLLM;' "$project"
grep -q 'productName = MLXLMCommon;' "$project"

resolved="$repo_root/ios/Pods.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
grep -q '"identity" : "mlx-swift-lm"' "$resolved"
grep -q '"revision" : "25b00d4e22e61ec9c41efda47990cd2084ec87ff"' "$resolved"
grep -q '"version" : "2.31.3"' "$resolved"
grep -q 'classifier: DeepSeekAdClassifier' "$repo_root/ios/Pods/PodsApp.swift"
grep -q 'static let modelID = "deepseek-v4-pro"' "$repo_root/ios/Pods/DeepSeekAdClassifier.swift"

echo "ad-removal project configuration tests passed"
