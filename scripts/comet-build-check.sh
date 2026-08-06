#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IOS_DESTINATION="${CODEX_IOS_DESTINATION:-platform=iOS Simulator,name=iPad-Test}"
DERIVED_DATA="${CODEX_DERIVED_DATA:-$ROOT_DIR/ios/DerivedData}"

run_stage() {
    local label="$1"
    shift
    printf '\n==> %s\n' "$label"
    if "$@"; then
        printf 'PASS: %s\n' "$label"
    else
        local status=$?
        printf 'FAIL: %s (exit %s)\n' "$label" "$status" >&2
        return "$status"
    fi
}

generate_ios_project() {
    cd "$ROOT_DIR/ios"
    xcodegen generate
}

run_stage "Build RelayProtocol" swift build --package-path "$ROOT_DIR/packages/RelayProtocol"
run_stage "Build relay-server" swift build --package-path "$ROOT_DIR/relay-server"
run_stage "Build relay-dialout" swift build --package-path "$ROOT_DIR/relay-dialout"
run_stage "Build mac-daemon" swift build --package-path "$ROOT_DIR/mac-daemon"
run_stage "Generate iOS project" generate_ios_project
run_stage "Build iOS app" xcodebuild build -quiet \
    -project "$ROOT_DIR/ios/CodexRemote.xcodeproj" \
    -scheme CodexRemote \
    -destination "$IOS_DESTINATION" \
    -derivedDataPath "$DERIVED_DATA"
