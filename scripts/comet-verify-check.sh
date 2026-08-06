#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IOS_DESTINATION="${CODEX_IOS_DESTINATION:-platform=iOS Simulator,name=iPad-Test}"
DERIVED_DATA="${CODEX_DERIVED_DATA:-$ROOT_DIR/ios/DerivedData}"
OPEN_SPEC_CHANGE="${CODEX_OPENSPEC_CHANGE:-functionality-review-fixes}"

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

validate_openspec() {
    cd "$ROOT_DIR"
    openspec validate "$OPEN_SPEC_CHANGE" --strict
}

check_git_diff() {
    cd "$ROOT_DIR"
    git diff --check
}

run_stage "Test RelayProtocol" swift test --package-path "$ROOT_DIR/packages/RelayProtocol"
run_stage "Test relay-server" swift test --package-path "$ROOT_DIR/relay-server"
run_stage "Test relay-dialout" swift test --package-path "$ROOT_DIR/relay-dialout"
run_stage "Test mac-daemon" swift test --package-path "$ROOT_DIR/mac-daemon"
run_stage "Generate iOS project" generate_ios_project
run_stage "Test iOS app" xcodebuild test -quiet \
    -project "$ROOT_DIR/ios/CodexRemote.xcodeproj" \
    -scheme CodexRemote \
    -destination "$IOS_DESTINATION" \
    -derivedDataPath "$DERIVED_DATA"
run_stage "Analyze iOS app" xcodebuild analyze -quiet \
    -project "$ROOT_DIR/ios/CodexRemote.xcodeproj" \
    -scheme CodexRemote \
    -destination "$IOS_DESTINATION" \
    -derivedDataPath "$DERIVED_DATA"
run_stage "Validate OpenSpec" validate_openspec
run_stage "Check Git diff" check_git_diff
